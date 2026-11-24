-- ============================================================================
-- exchange_user_submissions.sql — Stage 7: secure user-facing withdrawal
-- requests and KYC submissions
-- ============================================================================
-- Proves the three client entry points added by migration
-- 20261005100200_exchange_user_submissions.sql behave exactly as documented:
--
--   U0  fixtures: two client identities, one operator, three paper withdrawal
--       networks, funded paper balances (PAPER_FAUCET, never out of thin air),
--       and the baseline app_settings snapshot (paper, every LIVE_* flag off)
--   U1  AUTHENTICATION: anon is refused by the ACL on all three wrappers, and an
--       authenticated role with no JWT claim (auth.uid() IS NULL) is refused with
--       the distinct "no authenticated user" error — the wrapper, not RLS, is the
--       gate
--   U2  REQUEST + HOLD: request_withdrawal writes a pending user_client row and
--       holds amount+fee (available -> locked) in ONE balanced ledger transaction
--       whose idempotency key is withdrawal_hold:<request id>
--   U3  IDEMPOTENCY: the same key returns the same request (existing = true) and
--       moves NO money — one row, one hold, unchanged ledger sums; a second key is
--       a second request; keys are per user
--   U4  VALIDATION: fractional / zero / negative / below-min / above-max / unknown
--       asset / unknown network / disabled network / memo-required network /
--       missing destination / unfunded request are all refused and record NOTHING
--   U5  OWNERSHIP + RLS: another user cannot cancel or read the caller's request;
--       the RLS matrix (anon / authenticated / service_role) on both new tables
--   U6  CANCEL RELEASES EXACTLY: available +held, locked -held, zero-sum, status
--       cancelled, and cancel is refused once the request left pending
--   U7  APPROVAL STAYS ADMIN-ONLY and confirms the pre-existing hold (no second
--       hold, no second ledger transaction); the operator path (record_withdrawal_
--       request -> approve_withdrawal) still holds exactly as before
--   U8  MODE GATES both ways: paper refused while the exchange is live (and NOT
--       because of the withdrawals flag), live/paper flips reverted; the paper
--       sandbox switch, maintenance mode and account restrictions each refuse the
--       request path while the release path stays open
--   U9  KYC: a submission enters pending (never approved, never a level), the
--       no-PII denylist refuses personal data, one open application per tier,
--       resubmission only after a final state, no path from submission to verified
--   U10 STATIC GRANT PROBE: the three wrappers are executable by authenticated and
--       nobody else (no anon, no service_role, no PUBLIC); no pre-existing money or
--       admin function gained an authenticated grant; service_role kept its own
--   U11 the suite ends where it started: app_settings identical to the snapshot, no
--       live money, every ledger transaction zero-sum, every balance equal to its
--       entries
--
-- Every refusal is caught in-process (NOTICE PASS/FAIL): this suite emits NO bare
-- psql ERROR line, so the runner expects exactly 0 for it.
--
-- It flips app_settings.mode to live and back, so it runs in the core database
-- BEFORE exchange_separation_audit.sql (which must be last) and is NOT idempotent:
-- use a freshly migrated database.
-- ============================================================================
\set ON_ERROR_STOP 0

do $k$
begin
  if to_regclass('public.withdrawal_requests') is null
     or to_regclass('public.kyc_submissions') is null then
    raise exception 'exchange_user_submissions.sql needs migrations 20261005100130/…140 (withdrawal + KYC tables).';
  end if;
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'request_withdrawal'
  ) then
    raise exception 'exchange_user_submissions.sql needs migration 20261005100200_exchange_user_submissions.sql (the wrappers are missing).';
  end if;
  if exists (select 1 from public.withdrawal_requests where source = 'user_client')
     or exists (select 1 from public.kyc_submissions where source = 'user_client') then
    raise exception 'exchange_user_submissions.sql expects a freshly migrated database (client submission rows already exist) and must not be run twice in the same database.';
  end if;
end $k$;

drop table if exists public.u_res;
drop table if exists public.u_ids;
drop table if exists public.u_settings_snapshot;
create table public.u_res (seq serial primary key, label text, ok boolean);
create table public.u_ids (label text primary key, val text);
create table public.u_settings_snapshot as
select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
       paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode,
       live_enabled_at is null as live_at_null
  from public.app_settings;

-- ===========================================================================
-- helpers (same assertion style as the other exchange suites)
-- ===========================================================================
create or replace function public.u_expect(p_label text, p_sql text, p_expected text,
                                           p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    if v_actual is not distinct from p_expected then
      raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
      insert into public.u_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.u_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.u_res(label, ok) values (p_label, false);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.u_expect_error(p_label text, p_sql text, p_fragment text,
                                                 p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.u_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.u_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.u_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.u_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
declare v_rows bigint;
begin
  execute p_sql;
  get diagnostics v_rows = row_count;
  raise notice 'PASS  (ran) % [% row(s)]', p_label, v_rows;
  insert into public.u_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.u_res(label, ok) values (p_label, false);
end;
$fn$;

-- balanced paper funding from the seeded PAPER_FAUCET account (never out of thin air)
create or replace function public.u_fund(p_user uuid, p_symbol text, p_amount numeric)
returns void language plpgsql as $fn$
declare
  v_asset uuid; v_faucet uuid; v_account uuid; v_tx uuid;
begin
  select id into v_asset from public.assets where symbol = p_symbol;
  v_faucet  := public.system_account_id('PAPER_FAUCET', v_asset, 'paper');
  v_account := public.ensure_user_account(p_user, v_asset, 'available', 'paper');
  insert into public.ledger_transactions (type, environment, reference_type, reference_id, description)
  values ('paper_funding', 'paper', 'user', p_user,
          format('stage7 user-submission probe funding %s %s', p_amount, p_symbol))
  returning id into v_tx;
  perform public.post_entry(v_tx, v_faucet,  -p_amount, 'stage7 user-submission probe funding');
  perform public.post_entry(v_tx, v_account,  p_amount, 'stage7 user-submission probe funding');
end;
$fn$;

create or replace function public.u_avail(p_user uuid, p_symbol text, p_env text default 'paper')
returns numeric language sql stable as $fn$
  select coalesce(sum(b.available_units), 0)
    from public.accounts a
    left join public.balances b on b.account_id = a.id
   where a.user_id = p_user and a.environment = p_env and a.kind = 'available'
     and a.asset_id = (select id from public.assets where symbol = p_symbol)
$fn$;

create or replace function public.u_locked(p_user uuid, p_symbol text, p_env text default 'paper')
returns numeric language sql stable as $fn$
  select coalesce(sum(b.locked_units), 0)
    from public.accounts a
    left join public.balances b on b.account_id = a.id
   where a.user_id = p_user and a.environment = p_env and a.kind = 'locked'
     and a.asset_id = (select id from public.assets where symbol = p_symbol)
$fn$;

-- does a function body contain a given needle? (the static probes)
create or replace function public.u_src(p_name text)
returns text language sql stable as $fn$
  select coalesce((select prosrc from pg_proc p
                     join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.proname = p_name
                    order by p.oid limit 1), '')
$fn$;

create or replace function public.u_id(p_label text)
returns uuid language sql stable as $fn$
  select val::uuid from public.u_ids where label = p_label
$fn$;

-- ===========================================================================
\echo '=== U0. fixtures: two clients, one operator, paper withdrawal networks, funded balances'
-- ===========================================================================
select public.u_run('U0 create two client identities and one superadmin operator',
  $q$insert into auth.users (id, email) values
       ('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001', 'stage7-client-a@example.test'),
       ('b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002', 'stage7-client-b@example.test'),
       ('c9c9c9c9-c9c9-c9c9-c9c9-c9c9c9c90003', 'stage7-operator@example.test');
     insert into public.admin_users (username, password_hash, operator_role, auth_user_id, display_name)
       values ('u7_super', 'fixture', 'superadmin', 'c9c9c9c9-c9c9-c9c9-c9c9-c9c9c9c90003',
               'stage7 fixture superadmin')$q$);

select public.u_expect('U0 the fixture identities exist exactly once each',
  $q$select (select count(*) from auth.users where id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001')::text
        || '/' || (select count(*) from auth.users where id = 'b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002')::text
        || '/' || (select count(*) from public.admin_users where username = 'u7_super')::text$q$, '1/1/1');

select public.u_expect('U0 baseline: paper mode, live flags off, live_enabled_at NULL, paper switches on, no maintenance',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/'
        || withdrawals_enabled::text || '/' || (live_enabled_at is null)::text || '/'
        || paper_withdrawals_enabled::text || '/' || (not maintenance_mode)::text
        from public.app_settings$q$,
  'paper/false/false/false/true/true/true');

-- three paper withdrawal networks of its own, so nothing the earlier suites
-- configured is changed by this one
select public.u_run('U0 register three paper withdrawal networks (enabled / disabled / memo-required)',
  $q$select public.register_withdrawal_network('BTC', 'bitcoin_s7',      1000, 10000000, 500, 10, false, null, true);
     select public.register_withdrawal_network('BTC', 'bitcoin_s7_off',  1000, 10000000, 500, 10, false, null, false);
     select public.register_withdrawal_network('BTC', 'bitcoin_s7_memo', 1000, 10000000, 500, 10, true,  null, true)$q$);

select public.u_expect('U0 the three networks are registered and enabled/disabled as intended',
  $q$select string_agg(network || '=' || withdrawal_enabled::text, ',' order by network)
        from public.withdrawal_networks
       where network like 'bitcoin!_s7%' escape '!' and environment = 'paper'$q$,
  'bitcoin_s7=true,bitcoin_s7_memo=true,bitcoin_s7_off=false');

select public.u_run('U0 fund client A with 10,000,000 and client B with 1,000,000 paper BTC units',
  $q$select public.u_fund('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001', 'BTC', 10000000);
     select public.u_fund('b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002', 'BTC',  1000000)$q$);

select public.u_expect('U0 both clients start with nothing locked',
  $q$select public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text || '/'
        || public.u_locked('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text || '/'
        || public.u_avail('b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002','BTC')::text || '/'
        || public.u_locked('b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002','BTC')::text$q$,
  '10000000/0/1000000/0');

-- ===========================================================================
\echo '=== U1. AUTHENTICATION: anon refused by ACL, authenticated without a JWT refused by the wrapper'
-- ===========================================================================
select public.u_expect_error('U1 anon cannot call request_withdrawal (no EXECUTE privilege)',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',100000::bigint,'anon-key','S7ADDRANON0001')$q$,
  'permission denied for function request_withdrawal', 'anon');
select public.u_expect_error('U1 anon cannot call cancel_my_withdrawal',
  $q$select request_status from public.cancel_my_withdrawal(gen_random_uuid())$q$,
  'permission denied for function cancel_my_withdrawal', 'anon');
select public.u_expect_error('U1 anon cannot call submit_my_kyc',
  $q$select submission_status from public.submit_my_kyc('identity', '{}'::jsonb)$q$,
  'permission denied for function submit_my_kyc', 'anon');

select public.u_expect_error('U1 authenticated with NO JWT claim: request_withdrawal refuses (auth.uid() IS NULL)',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',100000::bigint,'nojwt','S7ADDRNOJWT0001')$q$,
  'no authenticated user', 'authenticated');
select public.u_expect_error('U1 authenticated with NO JWT claim: cancel_my_withdrawal refuses',
  $q$select request_status from public.cancel_my_withdrawal(gen_random_uuid())$q$,
  'no authenticated user', 'authenticated');
select public.u_expect_error('U1 authenticated with NO JWT claim: submit_my_kyc refuses',
  $q$select submission_status from public.submit_my_kyc('identity')$q$,
  'no authenticated user', 'authenticated');
select public.u_expect('U1 ... and those three refusals created no row at all',
  $q$select (select count(*) from public.withdrawal_requests where source = 'user_client')::text
        || '/' || (select count(*) from public.kyc_submissions where source = 'user_client')::text$q$,
  '0/0');

-- ===========================================================================
\echo '=== U2. REQUEST + HOLD: one pending row, one balanced hold transaction'
-- ===========================================================================
insert into public.u_ids select 'u2_avail_before',
  public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text;
insert into public.u_ids select 'u2_locked_before',
  public.u_locked('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text;

select public.u_expect('U2 client A requests 100,000 units of BTC on bitcoin_s7',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',100000::bigint,'k1','S7ADDRCLIENTA0001')$q$,
  'pending', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
insert into public.u_ids select 'req_a1',
  (select id::text from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001');

select public.u_expect('U2 the row is user_client, paper, pending, owned by the caller, with the snapshotted fee',
  $q$select source || '/' || environment || '/' || status || '/'
        || (user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001')::text || '/'
        || amount_units::text || '/' || fee_units::text || '/'
        || (hold_ledger_transaction_id is not null)::text
        from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001'$q$,
  'user_client/paper/pending/true/100000/600/true');

select public.u_expect('U2 the hold moved exactly amount+fee (100,600) from available to locked',
  $q$select (public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')
               = (select val::numeric from public.u_ids where label = 'u2_avail_before') - 100600)::text
        || '/' ||
        (public.u_locked('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')
               = (select val::numeric from public.u_ids where label = 'u2_locked_before') + 100600)::text$q$,
  'true/true');

select public.u_expect('U2 the hold is ONE withdrawal_request transaction with the documented idempotency key, and it sums to zero',
  $q$select count(distinct t.id)::text || '/' || min(t.type) || '/'
        || bool_and(t.idempotency_key = 'withdrawal_hold:' || w.id::text)::text || '/'
        || bool_and(t.reference_type = 'withdrawal_request' and t.reference_id = w.id)::text || '/'
        || coalesce(sum(e.amount_units), 0)::text
        from public.withdrawal_requests w
        join public.ledger_transactions t on t.id = w.hold_ledger_transaction_id
        left join public.ledger_entries e on e.transaction_id = t.id
       where w.destination_address = 'S7ADDRCLIENTA0001'$q$,
  '1/withdrawal_request/true/true/0');

-- ===========================================================================
\echo '=== U3. IDEMPOTENCY: the same key returns the same request and holds nothing again'
-- ===========================================================================
select public.u_expect('U3 a retry with the same key returns existing = true and the same request',
  $q$select existing::text || '/' || request_id::text
        from public.request_withdrawal('BTC','bitcoin_s7',100000::bigint,'k1','S7ADDRCLIENTA0001')$q$,
  'true/' || (select id::text from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001'),
  'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

select public.u_expect('U3 one key = one row, and the balance is exactly where the first call left it',
  $q$select (select count(*) from public.withdrawal_requests
              where user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001' and idempotency_key = 'k1')::text
        || '/' || public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text
        || '/' || public.u_locked('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text$q$,
  '1/9899400/100600');

select public.u_expect('U3 the retry posted no second ledger transaction (still one hold for that request)',
  $q$select count(*)::text from public.ledger_transactions t
        where t.idempotency_key like 'withdrawal_hold:%'
          and t.reference_id = (select id from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001')$q$,
  '1');

select public.u_expect('U3 a different key is a different request (existing = false, and it holds its own amount)',
  $q$select existing::text || '/' || request_status from public.request_withdrawal('BTC','bitcoin_s7',20000::bigint,'k2','S7ADDRCLIENTA0002')$q$,
  'false/pending', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
insert into public.u_ids select 'req_a2',
  (select id::text from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0002');
select public.u_expect('U3 two requests, two holds, both pending',
  $q$select count(*)::text || '/' || count(distinct hold_ledger_transaction_id)::text
        from public.withdrawal_requests
       where user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001' and source = 'user_client'$q$,
  '2/2');

select public.u_expect('U3 the same key on ANOTHER user is a separate request (keys are per user)',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'k1','S7ADDRCLIENTB0001')$q$,
  'pending', 'authenticated', 'b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002');
select public.u_expect('U3 ... with its own fee snapshot (500 + floor(5000*10/10000) = 505)',
  $q$select fee_units::text || '/' || (hold_ledger_transaction_id is not null)::text
        from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTB0001'$q$,
  '505/true');
insert into public.u_ids select 'req_b1',
  (select id::text from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTB0001');

-- ===========================================================================
\echo '=== U4. VALIDATION: every bad request is refused and records nothing'
-- ===========================================================================
insert into public.u_ids select 'u4_rows_before',
  (select count(*) from public.withdrawal_requests where source = 'user_client')::text;

select public.u_expect_error('U4 a fractional amount cannot even bind to the bigint parameter',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',1000.5,'v-frac','S7ADDRFRAC0001')$q$,
  'does not exist', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 a zero amount is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',0::bigint,'v-zero','S7ADDRZERO0001')$q$,
  'positive whole number of base units', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 a negative amount is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',(-100)::bigint,'v-neg','S7ADDRNEG0001')$q$,
  'positive whole number of base units', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 a NULL amount is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',null::bigint,'v-null','S7ADDRNULL0001')$q$,
  'an amount in base units is required', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 an amount below the network minimum is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',999::bigint,'v-min','S7ADDRMIN0001')$q$,
  'below the minimum', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 an amount above the network maximum is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',10000001::bigint,'v-max','S7ADDRMAX0001')$q$,
  'above the maximum', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 an unknown asset is refused',
  $q$select request_status from public.request_withdrawal('DOGE','bitcoin_s7',5000::bigint,'v-asset','S7ADDRASSET0001')$q$,
  'unknown asset symbol', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 an unregistered network is refused',
  $q$select request_status from public.request_withdrawal('BTC','nosuchnet',5000::bigint,'v-net','S7ADDRNET0001')$q$,
  'is not a registered withdrawal network', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 a registered but DISABLED network is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7_off',5000::bigint,'v-off','S7ADDROFF0001')$q$,
  'withdrawals are not enabled', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 a memo-required network is refused (the client path carries no destination tag)',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7_memo',5000::bigint,'v-memo','S7ADDRMEMO0001')$q$,
  'requires a destination tag', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 a request without a destination address is refused (nothing is generated)',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'v-addr')$q$,
  'destination address is required', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 a request the caller cannot fund is refused (insufficient available balance)',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',10000000::bigint,'v-poor','S7ADDRPOOR0001')$q$,
  'insufficient available balance', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U4 an idempotency key longer than 200 characters is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint, repeat('k', 201), 'S7ADDRLONGKEY01')$q$,
  'at most 200 characters', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

select public.u_expect('U4 ... and NONE of those attempts recorded a request',
  $q$select (select count(*) from public.withdrawal_requests where source = 'user_client')::text$q$,
  (select val from public.u_ids where label = 'u4_rows_before'));

select public.u_expect('U4 the unfunded attempt left no stranded hold and no ledger transaction',
  $q$select count(*)::text from public.ledger_transactions t
        where t.idempotency_key like 'withdrawal_hold:%'
          and t.reference_id in (select id from public.withdrawal_requests where destination_address = 'S7ADDRPOOR0001')$q$,
  '0');

-- ===========================================================================
\echo '=== U5. OWNERSHIP and the RLS matrix'
-- ===========================================================================
select public.u_expect_error('U5 client B cannot cancel client A''s request',
  $q$select request_status from public.cancel_my_withdrawal(public.u_id('req_a1'))$q$,
  'does not belong to the caller', 'authenticated', 'b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002');
select public.u_expect('U5 ... and A''s request is untouched (still pending, hold intact)',
  $q$select status || '/' || (hold_ledger_transaction_id is not null)::text
        from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001'$q$,
  'pending/true');
select public.u_expect_error('U5 an unknown request id is refused distinctly',
  $q$select request_status from public.cancel_my_withdrawal('00000000-0000-0000-0000-000000000000'::uuid)$q$,
  'unknown withdrawal request', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

select public.u_expect('U5 RLS: client A sees only its own requests',
  $q$select count(*)::text || '/' || bool_and(user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001')::text
        from public.withdrawal_requests$q$, '2/true', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U5 RLS: client B sees only its own request',
  $q$select count(*)::text || '/' || bool_and(user_id = 'b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002')::text
        from public.withdrawal_requests$q$, '1/true', 'authenticated', 'b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002');
select public.u_expect_error('U5 RLS: anon has no SELECT privilege on withdrawal_requests at all',
  $q$select count(*)::text from public.withdrawal_requests$q$,
  'permission denied for table withdrawal_requests', 'anon');
select public.u_expect('U5 RLS: service_role reads every request (the operator surface)',
  $q$select (count(*) >= 3)::text from public.withdrawal_requests$q$, 'true', 'service_role');

select public.u_expect_error('U5 a client cannot write a withdrawal row directly (no INSERT privilege, and RLS has no write policy)',
  $q$insert into public.withdrawal_requests
       (user_id, asset_id, network, environment, source, destination_address, amount_units, fee_units)
     values ('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001', (select id from public.assets where symbol = 'BTC'),
             'bitcoin_s7', 'paper', 'user_client', 'S7ADDRDIRECT001', 5000, 505) returning 1$q$,
  'permission denied for table withdrawal_requests', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U5 a client cannot flip its own request status directly (no UPDATE privilege)',
  $q$update public.withdrawal_requests set status = 'approved' returning 1$q$,
  'permission denied for table withdrawal_requests', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

-- ===========================================================================
\echo '=== U6. CANCEL releases exactly the hold'
-- ===========================================================================
insert into public.u_ids select 'u6_avail_before',
  public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text;
insert into public.u_ids select 'u6_locked_before',
  public.u_locked('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text;

select public.u_expect('U6 client A cancels its own pending request (20,000 + 520 fee = 20,520 released)',
  $q$select request_status || '/' || released_units::text from public.cancel_my_withdrawal(public.u_id('req_a2'))$q$,
  'cancelled/20520', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

select public.u_expect('U6 the release is EXACT: available +20,520 and locked -20,520, zero-sum',
  $q$select (public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')
               = (select val::numeric from public.u_ids where label = 'u6_avail_before') + 20520)::text
        || '/' ||
        (public.u_locked('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')
               = (select val::numeric from public.u_ids where label = 'u6_locked_before') - 20520)::text$q$,
  'true/true');

select public.u_expect('U6 the request is terminal cancelled with the release recorded, closed_at set and no failure_reason loss',
  $q$select status || '/' || (released_ledger_transaction_id is not null)::text || '/'
        || (closed_at is not null)::text || '/' || failure_reason
        from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0002'$q$,
  'cancelled/true/true/cancelled by the user before operator review');

select public.u_expect('U6 the release is ONE withdrawal_refund transaction with the documented key, summing to zero',
  $q$select count(distinct t.id)::text || '/' || min(t.type) || '/'
        || bool_and(t.idempotency_key = 'withdrawal_release:' || w.id::text)::text || '/'
        || coalesce(sum(e.amount_units), 0)::text
        from public.withdrawal_requests w
        join public.ledger_transactions t on t.id = w.released_ledger_transaction_id
        left join public.ledger_entries e on e.transaction_id = t.id
       where w.destination_address = 'S7ADDRCLIENTA0002'$q$,
  '1/withdrawal_refund/true/0');

select public.u_expect_error('U6 a cancelled request cannot be cancelled again',
  $q$select request_status from public.cancel_my_withdrawal(public.u_id('req_a2'))$q$,
  'a user can only cancel a still-pending request', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

-- a request under operator review is no longer the client's to cancel
select public.u_expect('U6 create a third request for the operator-review probe',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',3000::bigint,'k3','S7ADDRCLIENTA0003')$q$,
  'pending', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
insert into public.u_ids select 'req_a3',
  (select id::text from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0003');
select public.u_run('U6 put that request under operator review',
  $q$select public.set_withdrawal_under_review(public.u_id('req_a3'), 'stage7 probe: suspicious destination')$q$);
select public.u_expect_error('U6 ... and the client cannot cancel it once it is under review',
  $q$select request_status from public.cancel_my_withdrawal(public.u_id('req_a3'))$q$,
  'a user can only cancel a still-pending request', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U6 ... it stays under review with its hold intact',
  $q$select status || '/' || (hold_ledger_transaction_id is not null)::text
        from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0003'$q$,
  'under review/true');

-- ===========================================================================
\echo '=== U7. APPROVAL stays admin-only and confirms the pre-existing hold'
-- ===========================================================================
select public.u_expect_error('U7 a signed-in user cannot approve a withdrawal',
  $q$select public.approve_withdrawal(public.u_id('req_a1'))$q$,
  'permission denied for function approve_withdrawal', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U7 anon cannot approve a withdrawal either',
  $q$select public.approve_withdrawal(public.u_id('req_a1'))$q$,
  'permission denied for function approve_withdrawal', 'anon');
select public.u_expect_error('U7 a signed-in user cannot reject a withdrawal',
  $q$select public.reject_withdrawal(public.u_id('req_a1'), 'no')$q$,
  'permission denied for function reject_withdrawal', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

insert into public.u_ids select 'u7_hold_before',
  (select hold_ledger_transaction_id::text from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001');
insert into public.u_ids select 'u7_avail_before',
  public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text;

select public.u_expect('U7 the operator approves the client request',
  $q$select public.approve_withdrawal(public.u_id('req_a1'))$q$,
  'approved');

select public.u_expect('U7 ... confirming the SAME hold (no second hold, no second ledger transaction)',
  $q$select (hold_ledger_transaction_id::text = (select val from public.u_ids where label = 'u7_hold_before'))::text
        || '/' || public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text
        || '/' || (select count(*) from public.ledger_transactions t
                    where t.idempotency_key like 'withdrawal_hold:%'
                      and t.reference_id = (select id from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001'))::text
        from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001'$q$,
  'true/' || (select val from public.u_ids where label = 'u7_avail_before') || '/1');

select public.u_expect('U7 ... and it is approved with approved_at set',
  $q$select status || '/' || (approved_at is not null)::text
        from public.withdrawal_requests where destination_address = 'S7ADDRCLIENTA0001'$q$,
  'approved/true');
select public.u_expect_error('U7 an approved request can no longer be cancelled by the user',
  $q$select request_status from public.cancel_my_withdrawal(public.u_id('req_a1'))$q$,
  'a user can only cancel a still-pending request', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

-- the operator path must still hold exactly as it did before this stage
insert into public.u_ids select 'u7_op_avail_before',
  public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text;
insert into public.u_ids select 'u7_op_locked_before',
  public.u_locked('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')::text;
select public.u_run('U7 the OPERATOR path creates a request with no hold (unchanged behaviour)',
  $q$select public.record_withdrawal_request('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001', 'BTC', 'bitcoin_s7',
                                             'S7ADDRLEGACY0001', 5000)$q$);
select public.u_expect('U7 ... it starts pending with NO hold (approval is what locks, as before)',
  $q$select status || '/' || source || '/' || (hold_ledger_transaction_id is null)::text
        from public.withdrawal_requests where destination_address = 'S7ADDRLEGACY0001'$q$,
  'pending/paper_operator/true');
select public.u_expect('U7 ... approving it holds exactly amount+fee (5,000 + 505 = 5,505)',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests where destination_address = 'S7ADDRLEGACY0001'))$q$,
  'approved');
select public.u_expect('U7 ... available -5,505, locked +5,505, one hold transaction',
  $q$select (public.u_avail('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')
               = (select val::numeric from public.u_ids where label = 'u7_op_avail_before') - 5505)::text
        || '/' ||
        (public.u_locked('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','BTC')
               = (select val::numeric from public.u_ids where label = 'u7_op_locked_before') + 5505)::text
        || '/' ||
        (select count(*) from public.ledger_transactions t
          where t.idempotency_key like 'withdrawal_hold:%'
            and t.reference_id = (select id from public.withdrawal_requests where destination_address = 'S7ADDRLEGACY0001'))::text$q$,
  'true/true/1');

-- ===========================================================================
\echo '=== U8. MODE GATES both ways (paper <-> live), paper switch, maintenance, restriction'
-- ===========================================================================
select public.u_run('U8 flip to live mode the only legal way (live_trading_enabled + live_enabled_at)',
  $q$update public.app_settings
        set live_trading_enabled = true, live_enabled_at = now(), mode = 'live'$q$);
select public.u_expect('U8 the exchange is live', $q$select public.app_mode()$q$, 'live');

select public.u_expect_error('U8 LIVE: a client withdrawal request is refused (paper-only path, not the flag)',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'live-key','S7ADDRLIVE0001')$q$,
  'user withdrawal requests are not open in live mode', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U8 LIVE: a client KYC submission is refused',
  $q$select submission_status from public.submit_my_kyc('address', '{}'::jsonb)$q$,
  'user KYC submissions are not open while the exchange is live', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

select public.u_run('U8 turn the live withdrawals flag ON — the client path must STILL be refused',
  $q$update public.app_settings set withdrawals_enabled = true$q$);
select public.u_expect_error('U8 LIVE + withdrawals_enabled: the refusal is the stage-7 scope gate, not the flag',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'live-key','S7ADDRLIVE0001')$q$,
  'user withdrawal requests are not open in live mode', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U8 LIVE: no client row was created in either environment',
  $q$select count(*)::text from public.withdrawal_requests
        where source = 'user_client' and destination_address like 'S7ADDRLIVE%'$q$, '0');

select public.u_run('U8 revert to paper mode and clear every live flag',
  $q$update public.app_settings
        set mode = 'paper', live_trading_enabled = false, live_enabled_at = null,
            withdrawals_enabled = false, deposits_enabled = false,
            paper_trading_enabled = true, paper_deposits_enabled = true,
            paper_withdrawals_enabled = true, maintenance_mode = false$q$);
select public.u_expect('U8 PAPER again: the client path works (the control is not inert)',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'live-key','S7ADDRLIVE0001')$q$,
  'pending', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

select public.u_run('U8 switch the paper sandbox off',
  $q$update public.app_settings set paper_withdrawals_enabled = false$q$);
select public.u_expect_error('U8 paper switch off: a client withdrawal request is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'ps-off','S7ADDRPSOFF0001')$q$,
  'paper withdrawals are disabled', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U8 paper switch off: cancelling a pending request still works (release stays open)',
  $q$select request_status from public.cancel_my_withdrawal(
       (select id from public.withdrawal_requests where destination_address = 'S7ADDRLIVE0001'))$q$,
  'cancelled', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_run('U8 switch the paper sandbox back on',
  $q$update public.app_settings set paper_withdrawals_enabled = true$q$);

select public.u_run('U8 put the exchange into maintenance mode',
  $q$update public.app_settings set maintenance_mode = true, maintenance_note = 'stage7 probe'$q$);
select public.u_expect_error('U8 maintenance on: a client withdrawal request is refused',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'maint','S7ADDRMAINT0001')$q$,
  'maintenance mode', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_run('U8 leave maintenance mode',
  $q$update public.app_settings set maintenance_mode = false, maintenance_note = null$q$);

select public.u_run('U8 restrict client B from withdrawals (operator-set)',
  $q$insert into public.u_ids select 'u8_restr',
       public.admin_set_restriction('b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002', 'withdrawals',
                                    'stage7 probe restriction',
                                    (select id from public.admin_users where username = 'u7_super'))::text$q$);
select public.u_expect_error('U8 restricted client B cannot request a withdrawal',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'restr','S7ADDRRESTR0001')$q$,
  'restricted from withdrawals', 'authenticated', 'b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002');
select public.u_expect('U8 ... while client A (not restricted) still can',
  $q$select request_status from public.request_withdrawal('BTC','bitcoin_s7',5000::bigint,'restr-a','S7ADDRRESTRA001')$q$,
  'pending', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_run('U8 clear the restriction',
  $q$select public.admin_clear_restriction(
       (select val::uuid from public.u_ids where label = 'u8_restr'),
       'stage7 probe: restriction cleared',
       (select id from public.admin_users where username = 'u7_super'))$q$);

-- ===========================================================================
\echo '=== U9. KYC: pending only, no PII, one open application per tier, never verified'
-- ===========================================================================
select public.u_expect('U9 client A applies for the identity tier with an opaque reference',
  $q$select submission_status from public.submit_my_kyc('identity', '{"document_id":"doc_ref_1","content_hash":"sha256:00"}'::jsonb)$q$,
  'pending', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
insert into public.u_ids select 'kyc_a1',
  (select id::text from public.kyc_submissions
    where source = 'user_client' and user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U9 the row is user_client / paper / pending, seeking level 1, and NOT decided',
  $q$select source || '/' || environment || '/' || status || '/' || level_sought::text || '/'
        || (decided_at is null)::text || '/' || (provider_reference is null)::text || '/'
        || (user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001')::text
        from public.kyc_submissions where source = 'user_client'$q$,
  'user_client/paper/pending/1/true/true/true');

select public.u_expect('U9 the applicant is STILL level 0 (unverified): submitting grants nothing',
  $q$select level::text from public.kyc_status where user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001'$q$,
  '0');

select public.u_expect('U9 the submission is audited with actor_role user and actor_id = the caller',
  $q$select actor_role || '/' || (actor_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001')::text || '/' || action
        from public.security_audit_log
       where entity_type = 'kyc_submission' and subject_user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001'
       order by at desc limit 1$q$,
  'user/true/kyc.submission.submitted');

select public.u_expect('U9 a retry returns the SAME open application (existing = true)',
  $q$select existing::text || '/' || submission_id::text
        from public.submit_my_kyc('identity', '{"document_id":"doc_ref_1"}'::jsonb)$q$,
  'true/' || (select id::text from public.kyc_submissions where source = 'user_client' and user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001'),
  'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U9 ... so exactly one row exists for that user and tier',
  $q$select count(*)::text from public.kyc_submissions
        where user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001' and level_sought = 1$q$, '1');

select public.u_expect_error('U9 the no-PII denylist refuses a name in the payload',
  $q$select submission_status from public.submit_my_kyc('address', '{"full_name":"Jane Doe"}'::jsonb)$q$,
  'carries personal data', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U9 ... and a nested personal-data key is refused too',
  $q$select submission_status from public.submit_my_kyc('address', '{"applicant":{"date_of_birth":"1990-01-01"}}'::jsonb)$q$,
  'carries personal data', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U9 the default unverified tier cannot be applied for',
  $q$select submission_status from public.submit_my_kyc('unverified', '{}'::jsonb)$q$,
  'cannot be applied for', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U9 an unknown tier is refused',
  $q$select submission_status from public.submit_my_kyc('platinum', '{}'::jsonb)$q$,
  'unknown KYC tier', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U9 a non-object document payload is refused',
  $q$select submission_status from public.submit_my_kyc('address', '"just a string"'::jsonb)$q$,
  'must be a JSON object', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U9 a blank tier code is refused',
  $q$select submission_status from public.submit_my_kyc('   ', '{}'::jsonb)$q$,
  'a tier code is required', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U9 none of those refusals recorded an application',
  $q$select count(*)::text from public.kyc_submissions
        where user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001'$q$, '1');

select public.u_expect_error('U9 a client cannot approve its own application',
  $q$select public.approve_kyc(public.u_id('kyc_a1'))$q$,
  'permission denied for function approve_kyc', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U9 ... nor grant itself a level',
  $q$select public._kyc_grant_level('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001', 2, null)$q$,
  'permission denied for function _kyc_grant_level', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect_error('U9 ... nor move its submission to approved directly (no UPDATE privilege)',
  $q$update public.kyc_submissions set status = 'approved' returning 1$q$,
  'permission denied for table kyc_submissions', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');

select public.u_expect('U9 STATIC: submit_my_kyc contains no approval path and no level write',
  $q$select (public.u_src('submit_my_kyc') not like '%approved%')::text || '/'
        || (public.u_src('submit_my_kyc') not like '%grant_level%')::text || '/'
        || (public.u_src('submit_my_kyc') not like '%update public.kyc_status%')::text$q$,
  'true/true/true');
select public.u_expect('U9 STATIC: only the operator path and the provider event write the level, and neither mentions user_client',
  $q$select (public.u_src('approve_kyc') like '%kyc_status%')::text || '/'
        || (public.u_src('record_provider_kyc_event') like '%grant_level%')::text || '/'
        || (public.u_src('approve_kyc') not like '%user_client%')::text || '/'
        || (public.u_src('record_provider_kyc_event') not like '%user_client%')::text$q$,
  'true/true/true/true');

-- a final decision (operator path) is what allows a resubmission
select public.u_expect('U9 the operator rejects the application (the only path out of pending)',
  $q$select public.reject_kyc((select id from public.kyc_submissions where source = 'user_client' and user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001'),
                              'stage7 probe: rejected to prove the resubmission rule')$q$,
  'rejected');
select public.u_expect('U9 the user is still level 0 after a rejection',
  $q$select level::text from public.kyc_status where user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001'$q$, '0');
select public.u_expect('U9 after a FINAL state a resubmission is a NEW application (existing = false)',
  $q$select existing::text from public.submit_my_kyc('identity', '{"document_id":"doc_ref_2"}'::jsonb)$q$,
  'false', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U9 ... so the user now has two submissions (one rejected, one pending) and level 0',
  $q$select count(*)::text || '/' || count(*) filter (where status = 'pending')::text || '/'
        || (select level::text from public.kyc_status where user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001')
        from public.kyc_submissions where user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001'$q$,
  '2/1/0');

select public.u_expect('U9 RLS: a client sees only its own applications',
  $q$select count(*)::text || '/' || bool_and(user_id = 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001')::text
        from public.kyc_submissions$q$, '2/true', 'authenticated', 'a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001');
select public.u_expect('U9 RLS: another client sees none of them',
  $q$select count(*)::text from public.kyc_submissions$q$, '0', 'authenticated', 'b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002');
select public.u_expect_error('U9 RLS: anon has no SELECT privilege on kyc_submissions',
  $q$select count(*)::text from public.kyc_submissions$q$,
  'permission denied for table kyc_submissions', 'anon');

-- ===========================================================================
\echo '=== U10. STATIC GRANT PROBE (pg_proc / aclexplode ground truth)'
-- ===========================================================================
select public.u_expect('U10 the three wrappers are executable by authenticated',
  $q$select has_function_privilege('authenticated','public.request_withdrawal(text,text,bigint,text,text)','EXECUTE')::text
        || '/' || has_function_privilege('authenticated','public.cancel_my_withdrawal(uuid)','EXECUTE')::text
        || '/' || has_function_privilege('authenticated','public.submit_my_kyc(text,jsonb)','EXECUTE')::text$q$,
  'true/true/true');
select public.u_expect('U10 ... and by NOBODY else: anon, service_role and PUBLIC are all revoked',
  $q$select has_function_privilege('anon','public.request_withdrawal(text,text,bigint,text,text)','EXECUTE')::text
        || '/' || has_function_privilege('service_role','public.request_withdrawal(text,text,bigint,text,text)','EXECUTE')::text
        || '/' || has_function_privilege('anon','public.cancel_my_withdrawal(uuid)','EXECUTE')::text
        || '/' || has_function_privilege('service_role','public.cancel_my_withdrawal(uuid)','EXECUTE')::text
        || '/' || has_function_privilege('anon','public.submit_my_kyc(text,jsonb)','EXECUTE')::text
        || '/' || has_function_privilege('service_role','public.submit_my_kyc(text,jsonb)','EXECUTE')::text$q$,
  'false/false/false/false/false/false');
select public.u_expect('U10 the ACL itself carries no PUBLIC grantee on the wrappers (not just "anon happens to lack it")',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('request_withdrawal','cancel_my_withdrawal','submit_my_kyc')
          and (p.proacl is null
               or exists (select 1 from aclexplode(p.proacl) a where a.grantee = 0))$q$, '0');
select public.u_expect('U10 the wrappers are exactly three functions (no accidental overload)',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('request_withdrawal','cancel_my_withdrawal','submit_my_kyc')$q$, '3');

select public.u_expect('U10 NO pre-existing privileged function is executable by authenticated (the grant matrix did not move)',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in (
            'record_withdrawal_request','record_provider_withdrawal','approve_withdrawal',
            'reject_withdrawal','fail_withdrawal','complete_withdrawal','start_withdrawal_processing',
            'set_withdrawal_under_review','register_withdrawal_network','_withdrawal_ingest',
            '_withdrawal_close','_withdrawal_fee_units',
            'submit_kyc','set_kyc_under_review','approve_kyc','reject_kyc','record_provider_kyc_event',
            '_kyc_grant_level','ensure_kyc_status','assert_kyc_path','_kyc_pii_key_path',
            'record_deposit','credit_deposit','set_deposit_confirmations',
            'record_provider_balance','run_reconciliation','_reconciliation_invariant_scan',
            'assert_operator','resolve_operator','log_operator_action','assert_not_in_maintenance',
            'assert_account_not_restricted'
          )
          and has_function_privilege('authenticated', p.oid, 'EXECUTE')$q$, '0');
select public.u_expect('U10 the ONLY client-executable money functions are the two documented ones from stage 1 (place_order, cancel_order)',
  $q$select coalesce(string_agg(p.proname, ',' order by p.proname), 'none')
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in (
            'place_order','cancel_order','record_withdrawal_request','record_provider_withdrawal',
            'approve_withdrawal','reject_withdrawal','fail_withdrawal','complete_withdrawal',
            'start_withdrawal_processing','set_withdrawal_under_review','register_withdrawal_network',
            '_withdrawal_ingest','_withdrawal_close','_withdrawal_fee_units','submit_kyc',
            'set_kyc_under_review','approve_kyc','reject_kyc','record_provider_kyc_event',
            '_kyc_grant_level','ensure_kyc_status','record_deposit','credit_deposit',
            'record_provider_balance','run_reconciliation'
          )
          and has_function_privilege('authenticated', p.oid, 'EXECUTE')$q$,
  'cancel_order,place_order');
select public.u_expect('U10 ... no admin_* function is executable by authenticated',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname like 'admin!_%' escape '!'
          and has_function_privilege('authenticated', p.oid, 'EXECUTE')$q$, '0');
select public.u_expect('U10 the three client wrappers are the ONLY new authenticated grants (exactly three, and nothing else moved)',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('request_withdrawal','cancel_my_withdrawal','submit_my_kyc')
          and has_function_privilege('authenticated', p.oid, 'EXECUTE')$q$, '3');
select public.u_expect('U10 service_role KEEPS every money/admin function it had (nothing was taken away)',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in (
            'record_withdrawal_request','record_provider_withdrawal','approve_withdrawal',
            'reject_withdrawal','fail_withdrawal','complete_withdrawal','start_withdrawal_processing',
            'set_withdrawal_under_review','register_withdrawal_network','_withdrawal_ingest',
            '_withdrawal_close','submit_kyc','set_kyc_under_review','approve_kyc','reject_kyc',
            'record_provider_kyc_event','_kyc_grant_level','ensure_kyc_status','assert_kyc_path',
            'place_order','cancel_order','record_deposit','credit_deposit',
            'record_provider_balance','run_reconciliation'
          )
          and not has_function_privilege('service_role', p.oid, 'EXECUTE')$q$, '0');
select public.u_expect('U10 the client read entry points stay read-only (my_kyc_status / quote_withdrawal_fee still work)',
  $q$select has_function_privilege('authenticated','public.my_kyc_status()','EXECUTE')::text || '/'
        || has_function_privilege('authenticated','public.quote_withdrawal_fee(text,text,numeric)','EXECUTE')::text$q$,
  'true/true');

-- ===========================================================================
\echo '=== U11. the suite ends where it started'
-- ===========================================================================
select public.u_expect('U11 app_settings is byte-identical to the U0 snapshot',
  $q$select count(*)::text from (
       select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
              paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode,
              live_enabled_at is null as live_at_null
         from public.app_settings
       except
       select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
              paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode,
              live_at_null
         from public.u_settings_snapshot
     ) d$q$, '0');

select public.u_expect('U11 the client paths created NO live row (earlier suites leave their own live probe rows behind, so this is scoped to what this suite could have written)',
  $q$select ((select count(*) from public.withdrawal_requests where environment = 'live' and source = 'user_client')
           + (select count(*) from public.kyc_submissions where environment = 'live' and source = 'user_client')
           + (select count(*) from public.accounts where environment = 'live'
                and user_id in ('a7a7a7a7-a7a7-a7a7-a7a7-a7a7a7a70001','b8b8b8b8-b8b8-b8b8-b8b8-b8b8b8b80002'))
           + (select count(*) from public.ledger_transactions where environment = 'live'
                and reference_id in (public.u_id('req_a1'), public.u_id('req_a2'),
                                     public.u_id('req_a3'), public.u_id('req_b1'),
                                     public.u_id('kyc_a1'))))::text$q$, '0');

select public.u_expect('U11 every ledger transaction still sums to zero',
  $q$select count(*)::text from (
       select t.id from public.ledger_transactions t
         join public.ledger_entries e on e.transaction_id = t.id
        group by t.id having sum(e.amount_units) <> 0) b$q$, '0');

select public.u_expect('U11 every cached balance still equals its ledger entries',
  $q$select count(*)::text from (
       select acc.id
         from public.accounts acc
         left join public.balances b on b.account_id = acc.id
         left join (select account_id, sum(amount_units) u from public.ledger_entries group by account_id) e
                on e.account_id = acc.id
        where coalesce(b.available_units, 0) + coalesce(b.locked_units, 0)
              is distinct from coalesce(e.u, 0)) d$q$, '0');

select public.u_expect('U11 no client request is stranded: every user_client row is in a documented state',
  $q$select count(*)::text from public.withdrawal_requests
        where source = 'user_client'
          and status not in ('pending', 'under review', 'approved', 'cancelled', 'rejected', 'failed', 'completed')$q$,
  '0');

select public.u_expect('U11 every locked unit belongs to a live (non-terminal) hold or is exactly released',
  $q$select count(*)::text from public.withdrawal_requests w
        where w.hold_ledger_transaction_id is not null
          and w.released_ledger_transaction_id is null
          and w.status in ('cancelled', 'failed', 'rejected')$q$, '0');

-- ===========================================================================
\echo '=== SUMMARY'
-- ===========================================================================
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) as summary
  from public.u_res;
select label from public.u_res where not ok order by label;
