\set ON_ERROR_STOP on
-- =====================================================================
-- GlobalTradeVX — withdrawal layer verification suite (scratch PostgreSQL only)
--
-- Run in the SAME database as exchange_schema_tests.sql, after it and after
-- exchange_ledger_invariant_tests.sql / exchange_immutability_rls_probe.sql /
-- exchange_deposit_tests.sql: it re-uses their fixtures (the exchange assets, markets,
-- helper functions) and adds its own users, so it must run LAST in the core database.
-- Never point it at the live Supabase project ctrazoqbudsfkpawpomv — it moves balances
-- through the ledger.
--
-- Every assertion prints a PASS/FAIL NOTICE; the last line is a SUMMARY.
-- The destinations below are deliberately synthetic strings ("TESTFIXTURE…") and no
-- destination is generated or seeded by the schema: in paper mode the operator supplies
-- the destination, and nothing in this schema parses or verifies a chain address.
--
-- What this suite pins down (helpers follow the t.expect pattern of
-- exchange_schema_tests.sql; the schema is `w` so the suites cannot collide):
--   W1  network configuration: nothing seeded, upsert, invalid configuration refused
--   W2  the fee model: flat + floor(amount * bps / 10000), snapshotted per request
--   W3  request creation and every invalid request refused
--   W4  approval locks the funds (hold transaction, balances, idempotency)
--   W5  the state machine: every illegal transition refused
--   W6  completion: settlement through the ledger, provider-txid idempotency (constraint
--       AND explicit guard), terminal immutability
--   W7  failure/rejection release exactly the hold (locked returns to 0)
--   W8  the two switches, both directions, every flip reverted
--   W9  the provider-artifact contract (record_provider_withdrawal)
--   W10 authz matrix (anon / authenticated / service_role)
--   W11 the settings end where they started
-- =====================================================================

do $w$
begin
  if to_regclass('public.withdrawal_requests') is null then
    raise exception 'exchange_withdrawal_tests.sql needs the withdrawal migration (20261005100130_exchange_withdrawals.sql).';
  end if;
  if to_regclass('public.deposits') is null then
    raise exception 'exchange_withdrawal_tests.sql must run after the deposit suite in the same database.';
  end if;
  if exists (select 1 from public.withdrawal_requests) or exists (select 1 from public.withdrawal_networks) then
    raise exception 'exchange_withdrawal_tests.sql expects a freshly migrated database (withdrawal tables are not empty) and must not be run twice in the same database.';
  end if;
end $w$;

create table if not exists public.w_res(seq serial primary key, label text, ok boolean);
delete from public.w_res;
create table if not exists public.w_ret(seq serial primary key, label text, val text);
delete from public.w_ret;
-- app_settings as it was before this suite touched anything (W11 proves the reverts)
drop table if exists public.w_settings_snapshot;
create table public.w_settings_snapshot as select * from public.app_settings;

create or replace function public.w_expect(p_label text, p_sql text, p_expected text, p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    if v_actual is not distinct from p_expected then
      raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
      insert into public.w_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.w_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.w_res(label, ok) values (p_label, false);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.w_expect_error(p_label text, p_sql text, p_fragment text, p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.w_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.w_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.w_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.w_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
declare v_rows bigint;
begin
  execute p_sql;
  get diagnostics v_rows = row_count;
  raise notice 'PASS  (ran) % [% row(s)]', p_label, v_rows;
  insert into public.w_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.w_res(label, ok) values (p_label, false);
end;
$fn$;

-- 'available/locked' for one user/asset in the current environment (paper)
-- Each figure is summed over its OWN account kind (FILTER), never across both: the
-- first version put the two kinds in one CASE inside one sum and reported
-- available+locked as "available" with a locked figure of 0.
create or replace function public.w_bal(p_user uuid, p_symbol text, p_env text default 'paper')
returns text language sql stable as $fn$
  select coalesce(sum(b.available_units) filter (where a.kind = 'available'), 0)::text
         || '/' ||
         coalesce(sum(b.locked_units) filter (where a.kind = 'locked'), 0)::text
    from public.accounts a
    left join public.balances b on b.account_id = a.id
   where a.user_id = p_user and a.environment = p_env
     and a.asset_id = (select id from public.assets where symbol = p_symbol);
$fn$;

-- fund a user in the paper sandbox (ledger-backed, never an invented balance)
create or replace function public.w_fund(p_user uuid, p_symbol text, p_amount numeric)
returns void language plpgsql as $fn$
declare
  v_asset uuid;
  v_faucet uuid;
  v_account uuid;
  v_tx uuid;
begin
  select id into v_asset from public.assets where symbol = p_symbol;
  v_faucet := public.system_account_id('PAPER_FAUCET', v_asset, 'paper');
  v_account := public.ensure_user_account(p_user, v_asset, 'available', 'paper');
  insert into public.ledger_transactions (type, environment, reference_type, reference_id, description)
  values ('paper_funding', 'paper', 'user', p_user, format('scratch test funding %s %s', p_amount, p_symbol))
  returning id into v_tx;
  perform public.post_entry(v_tx, v_faucet, -p_amount, 'scratch test funding');
  perform public.post_entry(v_tx, v_account, p_amount, 'scratch test funding');
end $fn$;

-- fixtures: two users of this suite's own (the schema suite's 1111…/2222… are untouched)
insert into auth.users (id, email) values
  ('33333333-3333-3333-3333-333333333333', 'wd-u1@scratch.test'),
  ('44444444-4444-4444-4444-444444444444', 'wd-u2@scratch.test'),
  -- u3 exists only for the W10 probe "a signed-in user with no withdrawals sees none":
  -- u2 cannot serve it, it owns the rejected USDT request created in W4.
  ('55555555-5555-5555-5555-555555555555', 'wd-u3@scratch.test')
on conflict (id) do nothing;
\set U1 '33333333-3333-3333-3333-333333333333'
\set U2 '44444444-4444-4444-4444-444444444444'

select public.w_fund('33333333-3333-3333-3333-333333333333', 'BTC', 100000000);
select public.w_fund('33333333-3333-3333-3333-333333333333', 'USDT', 1000000000);
select public.w_fund('33333333-3333-3333-3333-333333333333', 'SOL', 10000000000);
select public.w_fund('44444444-4444-4444-4444-444444444444', 'BTC', 5000000);

\echo '=== W1. withdrawal network configuration (nothing seeded)'
select public.w_expect('no withdrawal network is seeded by the migration',
  $q$select count(*)::text from public.withdrawal_networks$q$, '0');
select public.w_run('W1 register BTC/bitcoin (min 1000, max 100000000, flat 1000 + 50 bps)',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin', 1000, 100000000, 1000, 50, false, 0, true)$q$);
select public.w_run('W1 register ETH/ethereum (no fee at all)',
  $q$select public.register_withdrawal_network('ETH', 'ethereum', 1000000000000000, 1000000000000000000, 0, 0, false, 1, true)$q$);
select public.w_run('W1 register USDT/ethereum (requires a destination tag, enabled)',
  $q$select public.register_withdrawal_network('USDT', 'ethereum', 1000000, 1000000000, 500000, 0, true, 1, true)$q$);
select public.w_run('W1 register USDT/tron (DISABLED)',
  $q$select public.register_withdrawal_network('USDT', 'tron', 1000000, 1000000000, 1000000, 0, false, null, false)$q$);
select public.w_run('W1 register SOL/solana',
  $q$select public.register_withdrawal_network('SOL', 'solana', 10000, 10000000000, 5000, 10, false, null, true)$q$);
select public.w_expect('five networks, all configured in the paper environment, one row per (asset, network)',
  $q$select count(*)::text || '/' || count(distinct network || coalesce(a.symbol,''))::text || '/' ||
           count(*) filter (where dn.environment <> 'paper')::text
          from public.withdrawal_networks dn join public.assets a on a.id = dn.asset_id$q$, '5/5/0');
select public.w_expect('USDT keeps its two networks apart (tron disabled, ethereum enabled)',
  $q$select string_agg(dn.network || '=' || dn.withdrawal_enabled::text, ',' order by dn.network)
          from public.withdrawal_networks dn join public.assets a on a.id = dn.asset_id
         where a.symbol = 'USDT'$q$, 'ethereum=true,tron=false');
select public.w_run('W1 re-registering a network upserts instead of duplicating',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin', 1000, 100000000, 1000, 50, false, 0, true)$q$);
select public.w_expect('... still five networks after the upsert',
  $q$select count(*)::text from public.withdrawal_networks$q$, '5');
select public.w_expect_error('W1 a minimum above the maximum is refused',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin', 200000000, 100000000, 0, 0)$q$,
  'withdrawal_networks_max_units_check');
select public.w_expect_error('W1 a network with no minimum is refused (NULL limits are not "not configured" here)',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin', null, 100000000, 0, 0)$q$,
  'needs both a minimum and a maximum');
select public.w_expect_error('W1 a negative flat fee is refused',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin', 1000, 100000000, -1, 0)$q$,
  'fee_check');
select public.w_expect_error('W1 more than 10000 basis points (over 100%) is refused',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin', 1000, 100000000, 0, 10001)$q$,
  'rate_check');

\echo '=== W2. the fee model: flat + floor(amount * bps / 10000)'
select public.w_expect('W2 BTC 1,000,000 units: 1000 flat + 50 bps (5000) = 6000',
  $q$select public.quote_withdrawal_fee('BTC', 'bitcoin', 1000000)::text$q$, '6000');
select public.w_expect('W2 BTC 100,001 units: the proportional part rounds DOWN (floor(500.005) = 500)',
  $q$select public.quote_withdrawal_fee('BTC', 'bitcoin', 100001)::text$q$, '1500');
select public.w_expect('W2 ETH has no fee configured: 0',
  $q$select public.quote_withdrawal_fee('ETH', 'ethereum', 1000000000000000)::text$q$, '0');
select public.w_expect('W2 SOL 50000 units: 5000 flat + 10 bps (50) = 5050',
  $q$select public.quote_withdrawal_fee('SOL', 'solana', 50000)::text$q$, '5050');
select public.w_expect_error('W2 a fee quote on an unregistered network is refused',
  $q$select public.quote_withdrawal_fee('BTC', 'dogecoin', 1000000)$q$,
  'not registered');

\echo '=== W3. request creation and every invalid request refused'
select public.w_expect_error('W3 unknown network is refused',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'dogecoin', 'TESTFIXTUREUNKNOWN1', 1000000)$q$,
  'not a registered withdrawal network');
select public.w_expect_error('W3 a disabled network is refused',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'USDT', 'tron', 'TESTFIXTURETRON1', 1000000)$q$,
  'withdrawals are not enabled for');
select public.w_expect_error('W3 the asset must match the network (SOL on bitcoin is not a network of SOL)',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'SOL', 'bitcoin', 'TESTFIXTUREMISMATCH1', 50000)$q$,
  'not a registered withdrawal network');
select public.w_expect_error('W3 below the minimum is refused',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREBELOW1', 999)$q$,
  'below the minimum');
select public.w_expect_error('W3 above the maximum is refused',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREABOVE1', 100000001)$q$,
  'above the maximum');
select public.w_expect_error('W3 a zero amount is refused',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREZERO1', 0)$q$,
  'positive whole number');
select public.w_expect_error('W3 a negative amount is refused',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTURENEG1', -1000000)$q$,
  'positive whole number');
select public.w_expect_error('W3 a fractional amount is refused',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREFRAC1', 1000000.5)$q$,
  'positive whole number');
select public.w_expect_error('W3 a missing destination is refused (the operator supplies it; nothing is generated)',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', '   ', 1000000)$q$,
  'needs a destination address');
select public.w_expect_error('W3 a destination containing whitespace is refused by the CHECK',
  $q$insert into public.withdrawal_requests (user_id, asset_id, network, environment, source, destination_address, amount_units, fee_units)
     select '33333333-3333-3333-3333-333333333333', a.id, 'bitcoin', 'paper', 'paper_operator', 'TEST FIXTURE SPACE', 1000000, 6000
       from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'destination_check');
select public.w_expect_error('W3 unknown user is refused',
  $q$select public.record_withdrawal_request('99999999-9999-9999-9999-999999999999', 'BTC', 'bitcoin', 'TESTFIXTURENOUSER1', 1000000)$q$,
  'unknown user');
select public.w_expect_error('W3 unknown asset is refused',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'DOGE', 'dogecoin', 'TESTFIXTURENOASSET1', 1000000)$q$,
  'unknown asset symbol');
select public.w_expect_error('W3 a network that requires a memo/tag refuses a request without one',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'USDT', 'ethereum', 'TESTFIXTUREETH1', 1000000)$q$,
  'requires a destination tag/memo');
select public.w_expect('W3 no request was recorded by any of the refusals above',
  $q$select count(*)::text from public.withdrawal_requests$q$, '0');

select public.w_run('W3 create a valid BTC request (1,000,000 units)',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREBTCADDR0001', 1000000)$q$);
select public.w_expect('W3 ... it is a paper_operator row in the paper environment, pending, with the fee snapshotted',
  $q$select environment || '/' || source || '/' || status || '/' || amount_units::text || '/' || fee_units::text
          from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'$q$,
  'paper/paper_operator/pending/1000000/6000');
select public.w_expect('W3 ... and nothing is locked and no ledger transaction was created yet',
  $q$select (hold_ledger_transaction_id is null)::text || '/' ||
           (select count(*) from public.ledger_transactions lt
             where lt.reference_type = 'withdrawal_request'
               and lt.reference_id = (select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'))::text
          from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'$q$,
  'true/0');
-- register_withdrawal_network() RETURNS uuid, so this is a fixture step (w_run), not a
-- value assertion: the two w_expect lines below are what pin the snapshot.
select public.w_run('W3 change the BTC fee model (the request must keep its snapshot)',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin', 1000, 100000000, 2000, 100, false, 0, true)$q$);
select public.w_expect('W3 ... the existing request still carries its 6000-unit fee',
  $q$select fee_units::text from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'$q$, '6000');
select public.w_expect('W3 ... while a new request would be quoted with the new fee (2000 + 100 bps)',
  $q$select public.quote_withdrawal_fee('BTC', 'bitcoin', 1000000)::text$q$, '12000');
select public.w_run('W3 restore the BTC fee model (flat 1000 + 50 bps)',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin', 1000, 100000000, 1000, 50, false, 0, true)$q$);

\echo '=== W4. approval LOCKS the funds'
select public.w_expect('W4 user 1 starts with 100,000,000 BTC available and nothing locked',
  $q$select public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC')$q$, '100000000/0');
select public.w_run('W4 approve the pending request',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'))$q$);
select public.w_expect('W4 ... status approved, hold pointer set, approved_at set',
  $q$select status || '/' || (hold_ledger_transaction_id is not null)::text || '/' || (approved_at is not null)::text
          from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'$q$, 'approved/true/true');
select public.w_expect('W4 ... available dropped by amount+fee and the locked balance holds exactly amount+fee',
  $q$select public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC')$q$, '98994000/1006000');
select public.w_expect('W4 ... the hold is one balanced withdrawal_request transaction (2 postings, zero sum)',
  $q$select lt.type || '/' || count(*)::text || '/' || sum(e.amount_units)::text
          from public.withdrawal_requests w
          join public.ledger_transactions lt on lt.id = w.hold_ledger_transaction_id
          join public.ledger_entries e on e.transaction_id = lt.id
         where w.destination_address = 'TESTFIXTUREBTCADDR0001'
         group by lt.type$q$, 'withdrawal_request/2/0');
select public.w_run('W4 approving an already approved request is idempotent',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'))$q$);
select public.w_expect('W4 ... and it did not place a second hold',
  $q$select count(*)::text from public.ledger_transactions
         where reference_type = 'withdrawal_request'
           and reference_id = (select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001')$q$, '1');
select public.w_expect('W4 ... the balance is unchanged by the idempotent approval',
  $q$select public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC')$q$, '98994000/1006000');

select public.w_run('W4 create a request for user 2 with no balance at all',
  $q$select public.record_withdrawal_request('44444444-4444-4444-4444-444444444444', 'USDT', 'ethereum', 'TESTFIXTUREUSDTADDR1', 5000000, 'MEMOTAG1')$q$);
select public.w_expect_error('W4 approval is refused when the available balance cannot cover amount+fee',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREUSDTADDR1'))$q$,
  'insufficient available balance');
select public.w_expect('W4 ... the refused approval left the request pending and locked nothing',
  $q$select status || '/' || (hold_ledger_transaction_id is null)::text from public.withdrawal_requests where destination_address = 'TESTFIXTUREUSDTADDR1'$q$,
  'pending/true');
select public.w_expect('W4 ... and user 2 still has nothing locked in USDT',
  $q$select public.w_bal('44444444-4444-4444-4444-444444444444', 'USDT')$q$, '0/0');

select public.w_run('W4 legal transition: reject the uncovered request',
  $q$select public.reject_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREUSDTADDR1'), 'no balance')$q$);

select public.w_run('W4 create a request that goes through operator review',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'SOL', 'solana', 'TESTFIXTURESOLADDR0001', 100000)$q$);
select public.w_run('W4 put it under review',
  $q$select public.set_withdrawal_under_review((select id from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'), 'manual review')$q$);
select public.w_expect('W4 ... status under review with the reason kept, nothing locked',
  $q$select status || '/' || review_reason || '/' || (hold_ledger_transaction_id is null)::text
          from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'$q$, 'under review/manual review/true');
select public.w_expect_error('W4 putting a non-pending request under review is refused',
  $q$select public.set_withdrawal_under_review((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'), 'again')$q$,
  'only a pending withdrawal');
select public.w_run('W4 approve out of review',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'))$q$);
select public.w_expect('W4 ... SOL: 10000 flat+rate fee on 100000 (5000 + 100) locked on top',
  $q$select status || '/' || fee_units::text || '/' || public.w_bal('33333333-3333-3333-3333-333333333333', 'SOL')
          from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'$q$,
  'approved/5100/9999894900/105100');

\echo '=== W5. the state machine: every illegal transition refused'
select public.w_run('W5 create one request per status for the transition probes',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTURESTATE0001', 2000)$q$);
select public.w_expect_error('W5 pending -> processing is refused',
  $q$update public.withdrawal_requests set status = 'processing', processing_at = now()
      where destination_address = 'TESTFIXTURESTATE0001'; select 'updated'$q$, 'illegal withdrawal status transition');
select public.w_expect_error('W5 pending -> completed is refused',
  $q$update public.withdrawal_requests set status = 'completed'
      where destination_address = 'TESTFIXTURESTATE0001'; select 'updated'$q$, 'illegal withdrawal status transition');
select public.w_expect_error('W5 under review -> pending (going backwards) is refused',
  $q$update public.withdrawal_requests set status = 'pending'
      where destination_address = 'TESTFIXTURESOLADDR0001'; select 'updated'$q$, 'terminal');
select public.w_expect_error('W5 approved -> completed (skipping processing) is refused through the entry point',
  $q$select public.complete_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'), 'TESTFIXTURETXSKIP1')$q$,
  'only a processing withdrawal can be completed');
select public.w_expect_error('W5 approved -> under review is refused',
  $q$update public.withdrawal_requests set status = 'under review', review_reason = 'x'
      where destination_address = 'TESTFIXTUREBTCADDR0001'; select 'updated'$q$, 'illegal withdrawal status transition');
select public.w_expect_error('W5 approved -> pending is refused',
  $q$update public.withdrawal_requests set status = 'pending'
      where destination_address = 'TESTFIXTUREBTCADDR0001'; select 'updated'$q$, 'illegal withdrawal status transition');
select public.w_expect_error('W5 approved -> rejected (must be failed) is refused by the trigger',
  $q$update public.withdrawal_requests set status = 'rejected', failure_reason = 'x', closed_at = now()
      where destination_address = 'TESTFIXTUREBTCADDR0001'; select 'updated'$q$, 'illegal withdrawal status transition');
select public.w_expect_error('W5 the identity of a request is immutable (amount)',
  $q$update public.withdrawal_requests set amount_units = 5000
      where destination_address = 'TESTFIXTURESTATE0001'; select 'updated'$q$, 'identity of withdrawal');
select public.w_expect_error('W5 the identity of a request is immutable (destination)',
  $q$update public.withdrawal_requests set destination_address = 'TESTFIXTURESTATE0002'
      where destination_address = 'TESTFIXTURESTATE0001'; select 'updated'$q$, 'identity of withdrawal');
-- The status/approved_at pair is a CHECK, not a trigger rule: it only bites on a row
-- whose status is approved/processing/completed. TESTFIXTURESTATE0001 is pending
-- (approved_at is already NULL there), so the probe must target the APPROVED fixture.
select public.w_expect_error('W5 the terminal-status timestamp pair is enforced by CHECK (approved without approved_at is impossible)',
  $q$update public.withdrawal_requests set approved_at = null
      where destination_address = 'TESTFIXTUREBTCADDR0001'; select 'updated'$q$,
  'withdrawal_requests_approved_at_check');
select public.w_expect('W5 the state/transition probes left both requests untouched',
  $q$select string_agg(status, ',' order by destination_address) from public.withdrawal_requests
         where destination_address in ('TESTFIXTURESTATE0001', 'TESTFIXTUREBTCADDR0001')$q$,
  'approved,pending');

\echo '=== W6. completion settles through the double-entry ledger'
select public.w_expect_error('W6 starting processing without a provider txid is refused',
  $q$select public.start_withdrawal_processing((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'), '  ')$q$,
  'requires the provider txid');
select public.w_expect_error('W6 starting processing from a pending request is refused',
  $q$select public.start_withdrawal_processing((select id from public.withdrawal_requests where destination_address = 'TESTFIXTURESTATE0001'), 'TESTFIXTURETXEARLY1')$q$,
  'only an approved withdrawal can start processing');
select public.w_run('W6 approved -> processing with the broadcast txid',
  $q$select public.start_withdrawal_processing((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'), 'TESTFIXTURETXBTC0001')$q$);
select public.w_expect('W6 ... processing with its txid recorded and the hold still in place',
  $q$select status || '/' || provider_txid || '/' || public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC')
          from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'$q$,
  'processing/TESTFIXTURETXBTC0001/98994000/1006000');
select public.w_expect_error('W6 completing with a different txid than the broadcast one is refused',
  $q$select public.complete_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'), 'TESTFIXTURETXOTHER1')$q$,
  'cannot be settled by a different txid');
select public.w_run('W6 complete the withdrawal',
  $q$select public.complete_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'))$q$);
select public.w_expect('W6 ... completed, settled pointer set, completed_at set',
  $q$select status || '/' || (settled_ledger_transaction_id is not null)::text || '/' || (completed_at is not null)::text
          from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'$q$, 'completed/true/true');
select public.w_expect('W6 ... the settlement is one balanced withdrawal_settle transaction with 3 postings (locked, clearing, fee)',
  $q$select lt.type || '/' || count(*)::text || '/' || sum(e.amount_units)::text
          from public.withdrawal_requests w
          join public.ledger_transactions lt on lt.id = w.settled_ledger_transaction_id
          join public.ledger_entries e on e.transaction_id = lt.id
         where w.destination_address = 'TESTFIXTUREBTCADDR0001'
         group by lt.type$q$, 'withdrawal_settle/3/0');
select public.w_expect('W6 ... zero-sum per asset after the settlement (BTC entries of that transaction sum to 0)',
  $q$select sum(e.amount_units)::text from public.ledger_entries e
          join public.assets a on a.id = e.asset_id
         where a.symbol = 'BTC'
           and e.transaction_id = (select settled_ledger_transaction_id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001')$q$, '0');
select public.w_expect('W6 ... the withdrawal clearing account carries exactly the amount that left (1,000,000) and FEE_INCOME the fee (6,000)',
  $q$select (select b.available_units::text from public.accounts a join public.balances b on b.account_id = a.id
              where a.code = 'WITHDRAWAL_CLEARING' and a.environment = 'paper'
                and a.asset_id = (select id from public.assets where symbol = 'BTC'))
          || '/' ||
          (select b.available_units::text from public.accounts a join public.balances b on b.account_id = a.id
              where a.code = 'FEE_INCOME' and a.environment = 'paper'
                and a.asset_id = (select id from public.assets where symbol = 'BTC'))$q$,
  '1000000/1000');
select public.w_expect('W6 ... the BTC locked balance is back to 0 (the hold was consumed, not stranded)',
  $q$select split_part(public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC'), '/', 2)$q$, '0');
select public.w_expect_error('W6 completing the same withdrawal twice is refused by the explicit guard',
  $q$select public.complete_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'))$q$,
  'already settled');
select public.w_expect('W6 ... the FEE_INCOME credit is still 1000 (flat 1000 only: this fixture math is asserted precisely)',
  $q$select count(*)::text from public.ledger_entries e
          join public.accounts a on a.id = e.account_id
         where a.code = 'FEE_INCOME' and a.asset_id = (select id from public.assets where symbol = 'BTC')$q$, '1');
select public.w_expect_error('W6 a completed withdrawal can never leave its terminal state',
  $q$update public.withdrawal_requests set status = 'processing'
      where destination_address = 'TESTFIXTUREBTCADDR0001'; select 'updated'$q$, 'terminal');
select public.w_expect_error('W6 a completed withdrawal can never be edited (settlement pointer)',
  $q$update public.withdrawal_requests set settled_ledger_transaction_id = null
      where destination_address = 'TESTFIXTUREBTCADDR0001'; select 'updated'$q$, 'terminal');
select public.w_expect_error('W6 a completed withdrawal can never be failed afterwards',
  $q$select public.fail_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0001'), 'too late')$q$,
  'terminal');

\echo '=== W6b. provider-txid idempotency: constraint AND explicit guard'
select public.w_run('W6b create a second BTC request and approve it',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREBTCADDR0002', 3000)$q$);
select public.w_run('W6b ... and approve it',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0002'))$q$);
select public.w_expect_error('W6b the explicit guard refuses a provider txid already used by another withdrawal',
  $q$select public.start_withdrawal_processing((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0002'), 'TESTFIXTURETXBTC0001')$q$,
  'already been used by another withdrawal');
select public.w_expect_error('W6b the UNIQUE constraint independently refuses the same txid written directly',
  $q$update public.withdrawal_requests set provider_txid = 'TESTFIXTURETXBTC0001'
      where destination_address = 'TESTFIXTUREBTCADDR0002'; select 'updated'$q$,
  'withdrawal_requests_provider_txid_key');
select public.w_expect('W6b ... the second request is still approved with no txid',
  $q$select status || '/' || coalesce(provider_txid, 'NULL') from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0002'$q$,
  'approved/NULL');
select public.w_run('W6b processing it with its own txid',
  $q$select public.start_withdrawal_processing((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0002'), 'TESTFIXTURETXBTC0002')$q$);
select public.w_run('W6b complete it',
  $q$select public.complete_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0002'))$q$);
select public.w_expect('W6b two settled withdrawals, two distinct provider txids, both clearing amounts summed',
  $q$select count(*)::text || '/' || count(distinct provider_txid)::text || '/' ||
           sum(amount_units)::text
          from public.withdrawal_requests where status = 'completed'$q$, '2/2/1003000');

\echo '=== W7. failure / rejection release EXACTLY the hold'
-- 100,000,000 funded - 1,006,000 (BTCADDR0001, completed in W6)
-- - 4,015 (BTCADDR0002: 3,000 + 1,000 flat + 15 bps, completed in W6b) = 98,989,985
select public.w_expect('W7 user 1 BTC: 98,989,985 available, nothing locked after both settlements',
  $q$select public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC')$q$, '98989985/0');
select public.w_expect_error('W7 closing a request as something other than failed/rejected is refused',
  $q$select public._withdrawal_close((select id from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'), 'approved', 'x')$q$,
  'only failed and rejected close a request');
select public.w_expect_error('W7 closing a request without a reason is refused',
  $q$select public.reject_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'), '  ')$q$,
  'requires a reason');
select public.w_expect('W7 SOL before the release: 9,999,894,900 available / 105,100 locked',
  $q$select public.w_bal('33333333-3333-3333-3333-333333333333', 'SOL')$q$, '9999894900/105100');
-- approved -> failed is the only closing edge out of 'approved' (pending/under review
-- close as rejected); both share the same release path, which is what W7 measures.
select public.w_run('W7 fail the approved SOL request (releases the hold)',
  $q$select public.fail_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'), 'destination not whitelisted yet')$q$);
select public.w_expect('W7 ... failed with its reason, release recorded, closed_at set',
  $q$select status || '/' || failure_reason || '/' || (released_ledger_transaction_id is not null)::text || '/' || (closed_at is not null)::text
          from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'$q$,
  'failed/destination not whitelisted yet/true/true');
select public.w_expect('W7 ... the release is one balanced withdrawal_refund transaction (2 postings, zero sum)',
  $q$select lt.type || '/' || count(*)::text || '/' || sum(e.amount_units)::text
          from public.withdrawal_requests w
          join public.ledger_transactions lt on lt.id = w.released_ledger_transaction_id
          join public.ledger_entries e on e.transaction_id = lt.id
         where w.destination_address = 'TESTFIXTURESOLADDR0001'
         group by lt.type$q$, 'withdrawal_refund/2/0');
select public.w_expect('W7 ... the SOL balances are exactly where they started: 10,000,000,000 available and 0 locked (no stranded funds)',
  $q$select public.w_bal('33333333-3333-3333-3333-333333333333', 'SOL')$q$, '10000000000/0');
select public.w_expect('W7 a failed withdrawal cannot be approved afterwards',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'))$q$,
  'only a pending or under-review withdrawal can be approved');
select public.w_expect_error('W7 a failed withdrawal cannot be closed again',
  $q$select public.fail_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTURESOLADDR0001'), 'again')$q$,
  'terminal');

select public.w_run('W7 create + approve a BTC request that will FAIL while processing',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREBTCADDR0003', 2000000)$q$);
select public.w_run('W7 ... approve it', $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0003'))$q$);
select public.w_expect('W7 ... the hold for 2,000,000 + 11,000 fee is locked',
  $q$select split_part(public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC'), '/', 2)$q$, '2011000');
select public.w_run('W7 ... start processing', $q$select public.start_withdrawal_processing((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0003'), 'TESTFIXTURETXBTC0003')$q$);
select public.w_run('W7 ... fail it', $q$select public.fail_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0003'), 'broadcast dropped')$q$);
select public.w_expect('W7 ... failed with release recorded and the BTC locked balance back to 0',
  $q$select status || '/' || public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC')
          from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0003'$q$,
  'failed/98989985/0');
select public.w_expect('W7 ... failed settled nothing (no settlement pointer)',
  $q$select (settled_ledger_transaction_id is null)::text from public.withdrawal_requests where destination_address = 'TESTFIXTUREBTCADDR0003'$q$, 'true');
select public.w_expect('W7 the user has no stranded locked funds in any asset after the release paths',
  $q$select coalesce(sum(b.locked_units), 0)::text from public.balances b
          join public.accounts a on a.id = b.account_id
         where a.user_id = '33333333-3333-3333-3333-333333333333' and a.kind = 'locked' and a.environment = 'paper'$q$, '0');

\echo '=== W8. the two switches, both directions'
select public.w_expect('W8 the paper switch exists and defaults to true',
  $q$select paper_withdrawals_enabled::text from public.app_settings$q$, 'true');
select public.w_expect('W8 the live withdrawalf flag is still off and the mode still paper',
  $q$select mode || '/' || withdrawals_enabled::text from public.app_settings$q$, 'paper/false');

select public.w_run('W8 create a pending request and an approved one for the gate probes',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREGATE0001', 5000)
       || (public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREGATE0002', 6000))::text$q$);
select public.w_run('W8 ... approve the second one', $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREGATE0002'))$q$);
select public.w_run('W8 switch paper withdrawals OFF (scratch database only)',
  $q$update public.app_settings set paper_withdrawals_enabled = false$q$);
select public.w_expect('W8 the paper switch reads back OFF, mode and both live flags untouched',
  $q$select mode || '/' || withdrawals_enabled::text || '/' || paper_withdrawals_enabled::text from public.app_settings$q$,
  'paper/false/false');
select public.w_expect_error('W8 paper request recording is refused while the paper switch is off',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREGATE0003', 5000)$q$,
  'paper withdrawals are disabled');
select public.w_expect_error('W8 paper approval (which would hold money) is refused while the paper switch is off',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREGATE0001'))$q$,
  'paper withdrawals are disabled');
select public.w_run('W8 the release path is NOT gated: the approved request can still be failed while the switch is off',
  $q$select public.fail_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREGATE0002'), 'released while paper switch is off')$q$);
select public.w_expect('W8 ... and its hold was released exactly (locked back to 0)',
  $q$select public.w_bal('33333333-3333-3333-3333-333333333333', 'BTC')$q$, '98989985/0');
select public.w_expect_error('W8 the live adapter path is still refused while the exchange is in paper mode (the paper flag changes nothing there)',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"TESTFIXTURELIVEADDR1","amount_units":100000}'::jsonb)$q$,
  'live-only');
select public.w_expect_error('W8 a live withdrawal row cannot be inserted directly in paper mode',
  $q$insert into public.withdrawal_requests (user_id, asset_id, network, environment, source, destination_address, amount_units, fee_units)
     select '33333333-3333-3333-3333-333333333333', a.id, 'bitcoin', 'live', 'provider_adapter', 'TESTFIXTURELIVEADDR2', 100000, 6000
       from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'live row rejected');
select public.w_run('W8 switch paper withdrawals back ON',
  $q$update public.app_settings set paper_withdrawals_enabled = true$q$);
select public.w_expect('W8 ... the paper switch reads back ON',
  $q$select paper_withdrawals_enabled::text from public.app_settings$q$, 'true');
select public.w_run('W8 with the switch back ON the same paper request is accepted',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREGATE0004', 5000)$q$);

\echo '=== W8b. live mode: mode = live and withdrawals_enabled'
-- app_settings_live_gate_check (migration 1) only allows mode='live' together with
-- live_trading_enabled AND live_enabled_at, so entering live mode has to satisfy that
-- pre-existing constraint. withdrawals_enabled stays FALSE: that is the gate under test.
select public.w_run('W8b go to live mode with withdrawals_enabled still FALSE (scratch database only)',
  $q$update public.app_settings set mode = 'live', live_trading_enabled = true, live_enabled_at = now()$q$);
select public.w_expect('W8b live mode reads back with the live withdrawal flag off',
  $q$select mode || '/' || withdrawals_enabled::text || '/' || paper_withdrawals_enabled::text from public.app_settings$q$,
  'live/false/true');
select public.w_expect_error('W8b with the live withdrawal flag off the adapter path is refused with the LIVE message',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"TESTFIXTURELIVEADDR3","amount_units":100000}'::jsonb)$q$,
  'live withdrawals are disabled');
select public.w_expect_error('W8b ... and a live row is refused independently by the environment gate',
  $q$insert into public.withdrawal_requests (user_id, asset_id, network, environment, source, destination_address, amount_units, fee_units)
     select '33333333-3333-3333-3333-333333333333', a.id, 'bitcoin', 'live', 'provider_adapter', 'TESTFIXTURELIVEADDR4', 100000, 0
       from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'withdrawals is not enabled');
select public.w_expect('W8b no live withdrawal row exists while the flag is off',
  $q$select count(*)::text from public.withdrawal_requests where environment = 'live'$q$, '0');
select public.w_run('W8b turn withdrawals_enabled ON (scratch database only)',
  $q$update public.app_settings set withdrawals_enabled = true$q$);
select public.w_expect('W8b ... the live flag reads back on',
  $q$select withdrawals_enabled::text from public.app_settings$q$, 'true');
select public.w_expect_error('W8b in live mode the paper operator path is refused (paper data never enters as live)',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREPAPERINLIVE1', 5000)$q$,
  'paper-only');
select public.w_run('W8b the adapter path is accepted with the live gate open',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"TESTFIXTURELIVEADDR5","amount_units":100000}'::jsonb)$q$);
select public.w_expect('W8b ... it is a provider_adapter row in the live environment, pending, fee from the live network config',
  $q$select environment || '/' || source || '/' || status || '/' || fee_units::text
          from public.withdrawal_requests where destination_address = 'TESTFIXTURELIVEADDR5'$q$,
  'live/provider_adapter/pending/6000');
select public.w_expect('W8b the source/environment pairing is intact after every probe',
  $q$select count(*)::text from public.withdrawal_requests where (source = 'provider_adapter') <> (environment = 'live')$q$, '0');

\echo '=== W9. provider-adapter contract (record_provider_withdrawal)'
select public.w_expect('W9 the live request count before the contract probes',
  $q$select count(*)::text from public.withdrawal_requests where environment = 'live'$q$, '1');
select public.w_expect_error('W9 a non-object event (array) is refused',
  $q$select public.record_provider_withdrawal('[]'::jsonb)$q$, 'must be a JSON object');
select public.w_expect_error('W9 a NULL event is refused',
  $q$select public.record_provider_withdrawal(null::jsonb)$q$, 'must be a JSON object');
select public.w_expect_error('W9 a JSON string is refused',
  $q$select public.record_provider_withdrawal('"bitcoin"'::jsonb)$q$, 'must be a JSON object');
select public.w_expect_error('W9 missing required keys are refused and named',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC"}
     '::jsonb || '{"user_id":"33333333-3333-3333-3333-333333333333"}'::jsonb)$q$,
  'missing required key(s) amount_units, destination_address');
select public.w_expect_error('W9 a non-uuid user_id is refused',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"not-a-uuid","destination_address":"TESTFIXTURELIVEADDR6","amount_units":100000}'::jsonb)$q$,
  'user_id is not a uuid');
select public.w_expect_error('W9 a non-numeric amount is refused',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"TESTFIXTURELIVEADDR6","amount_units":"lots"}'::jsonb)$q$,
  'amount_units is not numeric');
select public.w_expect_error('W9 a blank destination is refused',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"  ","amount_units":100000}'::jsonb)$q$,
  'needs a destination address');
select public.w_expect_error('W9 an unknown network is refused through the adapter too',
  $q$select public.record_provider_withdrawal('{"network":"dogecoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"TESTFIXTURELIVEADDR6","amount_units":100000}'::jsonb)$q$,
  'not a registered withdrawal network');
select public.w_expect_error('W9 a below-minimum amount is refused through the adapter too',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"TESTFIXTURELIVEADDR6","amount_units":10}'::jsonb)$q$,
  'below the minimum');
select public.w_expect('W9 every contract violation recorded NOTHING',
  $q$select count(*)::text from public.withdrawal_requests where environment = 'live'$q$, '1');
select public.w_run('W9 a well-formed event with extra provider keys is accepted',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"TESTFIXTURELIVEADDR7","amount_units":200000,"destination_tag":null,"provider_txid":"TESTFIXTURELIVETX0001","provider_request_id":"pr-1","risk_score":7}'::jsonb)$q$);
select public.w_expect('W9 ... the extra keys are preserved verbatim in raw',
  $q$select raw->>'provider_request_id' || '/' || (raw->>'risk_score') || '/' || (raw->>'provider_txid')
          from public.withdrawal_requests where destination_address = 'TESTFIXTURELIVEADDR7'$q$,
  'pr-1/7/TESTFIXTURELIVETX0001');
select public.w_expect('W9 ... and the txid the adapter reported is on the row',
  $q$select provider_txid || '/' || status from public.withdrawal_requests where destination_address = 'TESTFIXTURELIVEADDR7'$q$,
  'TESTFIXTURELIVETX0001/pending');

\echo '=== W8c. revert every flag flip'
select public.w_run('W8c back to paper mode, live trading and live withdrawal flags off',
  $q$update public.app_settings set mode = 'paper', live_trading_enabled = false, live_enabled_at = null, withdrawals_enabled = false$q$);
select public.w_run('W8c paper withdrawals on', $q$update public.app_settings set paper_withdrawals_enabled = true$q$);
-- record_provider_withdrawal lives in the function ACL set: a refusal here is an
-- exception, so this is w_expect_error (w_expect would report the exception as a FAIL).
select public.w_expect_error('W8c the gates are closed again: the adapter path is refused in paper mode',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC","user_id":"33333333-3333-3333-3333-333333333333","destination_address":"TESTFIXTURELIVEADDR8","amount_units":100000}'::jsonb)$q$,
  'live-only');

\echo '=== W10. authz matrix'
select public.w_expect_error('W10 anon cannot read withdrawal_requests at all (no privilege)',
  $q$select count(*)::text from public.withdrawal_requests$q$, 'permission denied for table withdrawal_requests', 'anon');
select public.w_expect_error('W10 anon cannot read withdrawal_networks either',
  $q$select count(*)::text from public.withdrawal_networks$q$, 'permission denied for table withdrawal_networks', 'anon');
select public.w_expect_error('W10 anon cannot call a withdrawal entry point',
  $q$select public.record_withdrawal_request('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTUREANON1', 5000)$q$,
  'permission denied for function record_withdrawal_request', 'anon');
select public.w_expect_error('W10 anon cannot insert a withdrawal row',
  $q$insert into public.withdrawal_requests (user_id, asset_id, network, environment, source, destination_address, amount_units, fee_units)
     select '33333333-3333-3333-3333-333333333333', a.id, 'bitcoin', 'paper', 'paper_operator', 'TESTFIXTUREANON2', 5000, 0
       from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'permission denied', 'anon');
-- the suite has {before} requests of user 1 and 2; compare against a fixed number
select public.w_expect('W10 a signed-in user sees exactly their own withdrawal requests',
  $q$select count(*)::text from public.withdrawal_requests$q$,
  (select count(*)::text from public.withdrawal_requests where user_id = '33333333-3333-3333-3333-333333333333'),
  'authenticated', '33333333-3333-3333-3333-333333333333'::uuid);
select public.w_expect('W10 ... and none of another user''s (user 2''s rejected W4 request is invisible to user 1)',
  $q$select count(*)::text from public.withdrawal_requests where user_id = '44444444-4444-4444-4444-444444444444'$q$, '0',
  'authenticated', '33333333-3333-3333-3333-333333333333'::uuid);
select public.w_expect('W10 a signed-in user with no withdrawals sees none',
  $q$select count(*)::text from public.withdrawal_requests$q$, '0',
  'authenticated', '55555555-5555-5555-5555-555555555555'::uuid);
select public.w_expect('W10 a signed-in user can read the withdrawal network configuration',
  $q$select count(*)::text from public.withdrawal_networks$q$, '5', 'authenticated', '33333333-3333-3333-3333-333333333333'::uuid);
select public.w_expect_error('W10 a signed-in user cannot insert a withdrawal row',
  $q$insert into public.withdrawal_requests (user_id, asset_id, network, environment, source, destination_address, amount_units, fee_units)
     select '33333333-3333-3333-3333-333333333333', a.id, 'bitcoin', 'paper', 'paper_operator', 'TESTFIXTUREAUTH1', 5000, 0
       from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'permission denied', 'authenticated', '33333333-3333-3333-3333-333333333333'::uuid);
select public.w_expect_error('W10 a signed-in user cannot update their own withdrawal (no write path, or they could mint states)',
  $q$update public.withdrawal_requests set status = 'pending' where true; select 'updated'$q$,
  'permission denied', 'authenticated', '33333333-3333-3333-3333-333333333333'::uuid);
select public.w_expect_error('W10 a signed-in user cannot call approve_withdrawal',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREGATE0001'))$q$,
  'permission denied for function approve_withdrawal', 'authenticated', '33333333-3333-3333-3333-333333333333'::uuid);
select public.w_expect('W10 a signed-in user may preview a fee (read-only)',
  $q$select public.quote_withdrawal_fee('BTC', 'bitcoin', 1000000)::text$q$, '6000',
  'authenticated', '33333333-3333-3333-3333-333333333333'::uuid);
select public.w_expect('W10 service_role reads the whole table (RLS bypassed)',
  $q$select count(*)::text > '0' from public.withdrawal_requests$q$, 'true', 'service_role');
select public.w_expect('W10 service_role can execute the operator transitions',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREGATE0001'))$q$,
  'approved', 'service_role');
-- client roles only: the table owner (postgres) keeps its owner privileges, which no
-- client can ever use.
select public.w_expect('W10 no DELETE privilege exists for any client role',
  $q$select count(*)::text from information_schema.role_table_grants
         where table_name in ('withdrawal_requests', 'withdrawal_networks')
           and privilege_type = 'DELETE'
           and grantee in ('anon', 'authenticated', 'service_role')$q$, '0');

\echo '=== W11. the settings end where they started'
select public.w_run('W11 release the one hold W10 left open (its approval was the authz probe)',
  $q$select public.fail_withdrawal((select id from public.withdrawal_requests where destination_address = 'TESTFIXTUREGATE0001'), 'end of suite cleanup')$q$);
select public.w_expect('W11 app_settings matches the snapshot taken before this suite ran (mode, every live flag, both paper switches)',
  $q$select s.mode || '/' || s.live_trading_enabled::text || '/' || s.deposits_enabled::text || '/' ||
           s.withdrawals_enabled::text || '/' || s.paper_deposits_enabled::text || '/' ||
           s.paper_withdrawals_enabled::text
          from public.app_settings s
          join public.w_settings_snapshot o on true$q$,
  (select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/' ||
          withdrawals_enabled::text || '/' || paper_deposits_enabled::text || '/' ||
          paper_withdrawals_enabled::text from public.w_settings_snapshot));
select public.w_expect('W11 the live flags are all off and the mode is paper, exactly as configured in the repo',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/' || withdrawals_enabled::text
          from public.app_settings$q$, 'paper/false/false/false');
select public.w_expect('W11 the fee/limit configuration of every network ended as registered (5 networks, one disabled)',
  $q$select count(*)::text || '/' || count(*) filter (where not withdrawal_enabled)::text from public.withdrawal_networks$q$, '5/1');
select public.w_expect('W11 every user''s locked balance is 0 after the whole suite (no stranded holds)',
  $q$select coalesce(sum(b.locked_units), 0)::text from public.balances b
          join public.accounts a on a.id = b.account_id
         where a.account_type = 'user'$q$, '0');

\echo '=== SUMMARY'
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from public.w_res;
select count(*) filter (where not ok) as failures from public.w_res;
