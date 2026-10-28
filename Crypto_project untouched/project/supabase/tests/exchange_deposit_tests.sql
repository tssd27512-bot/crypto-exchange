\set ON_ERROR_STOP on
-- =====================================================================
-- GlobalTradeVX — deposit layer verification suite (scratch PostgreSQL only)
--
-- Run in the SAME database as exchange_schema_tests.sql, after it and after
-- exchange_ledger_invariant_tests.sql / exchange_immutability_rls_probe.sql:
-- it re-uses those fixtures (auth users 1111…/2222…). Never point it at the
-- live Supabase project ctrazoqbudsfkpawpomv — it creates deposits and credits
-- them through the ledger.
--
-- Every assertion prints a PASS/FAIL NOTICE; the last line is a SUMMARY.
-- The fixture addresses/txids below are deliberately synthetic strings
-- ("TESTFIXTURE…"): nothing here is, or could be mistaken for, a real chain
-- address, and no deposit address is generated or seeded by the schema.
--
-- Statuses under test are the owner's set (2026-10-11): pending, confirming,
-- confirmed, failed, under review — crediting is DATA on a confirmed row, not a
-- status. See the migration header for the mapping from the earlier draft names.
--
-- Gating choices this suite pins down (two switches, one per mode):
--   * LIVE: app_settings.deposits_enabled is the DB side of the plan's
--     LIVE_DEPOSITS_ENABLED and gates the live path (the provider adapter), which D6
--     asserts in both directions: flag off -> a live adapter event is refused; flag on
--     (scratch DB only) -> the same event is accepted.
--   * PAPER: app_settings.paper_deposits_enabled (default true) gates the paper
--     sandbox, which D7 asserts in both directions: switch off -> record_deposit() and
--     credit_deposit() of a paper deposit are refused with their own distinct message;
--     switch back on -> both succeed. D7 also pins that the live gate is unaffected by
--     the paper switch.
-- Every flag flip happens in this scratch database only and is reverted before the
-- suite ends.
-- =====================================================================

do $g$
begin
  if to_regclass('public.deposits') is null then
    raise exception 'exchange_deposit_tests.sql needs the deposit migration (20261005100120_exchange_deposits.sql).';
  end if;
  if not exists (select 1 from auth.users where id = '11111111-1111-1111-1111-111111111111') then
    raise exception 'exchange_deposit_tests.sql must run in the same database, after exchange_schema_tests.sql (fixture users are missing).';
  end if;
  if exists (select 1 from public.deposits) or exists (select 1 from public.deposit_addresses)
     or exists (select 1 from public.deposit_networks) then
    raise exception 'exchange_deposit_tests.sql expects a freshly migrated database (deposit tables are not empty) and must not be run twice in the same database.';
  end if;
  if to_regprocedure('public.app_mode()') is null then
    raise exception 'exchange helpers are missing: apply the migrations first.';
  end if;
  if to_regprocedure('public.record_provider_deposit(jsonb)') is null then
    raise exception 'the provider adapter entry point record_provider_deposit(jsonb) is missing.';
  end if;
end $g$;

-- counters live in a real table so that a statement that is later rolled back
-- (there is none: this suite never relies on a rollback) cannot lose a result
create table if not exists public.d_res(seq serial primary key, label text, ok boolean);
delete from public.d_res;
-- return values captured from a function call, so that "what it returned" can be
-- compared in a later statement (a subquery in the same statement would read the
-- pre-call row image, which is exactly the bug this table removes)
create table if not exists public.d_ret(seq serial primary key, label text, val text);
delete from public.d_ret;

create or replace function public.d_expect(p_label text, p_sql text, p_expected text, p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    if v_actual is not distinct from p_expected then
      raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
      insert into public.d_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.d_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.d_res(label, ok) values (p_label, false);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.d_expect_error(p_label text, p_sql text, p_fragment text, p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.d_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.d_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.d_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.d_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
declare v_rows bigint;
begin
  execute p_sql;
  get diagnostics v_rows = row_count;
  raise notice 'PASS  (ran) % [% row(s)]', p_label, v_rows;
  insert into public.d_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.d_res(label, ok) values (p_label, false);
end;
$fn$;

-- shorthand: a deposit row is found by its chain identity, never by a captured id
\echo '=== D1. network + address provisioning (operator path, nothing generated)'
select public.d_run('register BTC/bitcoin (3 confirmations, min 0.5 BTC, deposits disabled)',
  $q$select public.register_deposit_network('BTC', 'bitcoin', 3, 0, false, 50000000, false)$q$);
select public.d_run('register USDT/ethereum (disabled), USDT/tron (enabled, min 10 USDT), USDT/solana (enabled, but NO confirmation policy)',
  $q$select (public.register_deposit_network('USDT', 'ethereum', 12, 1, false, 10000000, false))::text ||
           (public.register_deposit_network('USDT', 'tron', 20, null, false, 10000000, true))::text ||
           (public.register_deposit_network('USDT', 'solana', 0, null, false, 10000000, true))::text$q$);
select public.d_run('register ETH/ethereum with NO minimum deposit (min NULL = not configured)',
  $q$select public.register_deposit_network('ETH', 'ethereum', 12, 1, false, null, true)$q$);
select public.d_run('register SOL/solana', $q$select public.register_deposit_network('SOL', 'solana', 1, null, false, 1000000, false)$q$);
select public.d_expect('six networks registered, none seeded by the migration',
  $q$select count(*)::text from public.deposit_networks$q$, '6');
select public.d_expect('USDT keeps its networks apart (one row per asset+network)',
  $q$select string_agg(network, ',' order by network) from public.deposit_networks dn join public.assets a on a.id = dn.asset_id where a.symbol = 'USDT'$q$,
  'ethereum,solana,tron');
select public.d_expect('register_deposit_network upserts instead of duplicating',
  $q$select count(*)::text from public.deposit_networks dn join public.assets a on a.id = dn.asset_id where a.symbol = 'USDT' and dn.network = 'tron'$q$, '1');
select public.d_expect_error('unknown asset symbol is refused',
  $q$select public.register_deposit_network('DOGE', 'dogecoin', 3, null, false, 1, true)$q$, 'unknown asset symbol');
select public.d_expect_error('a network name must be a lowercase chain identifier',
  $q$select public.register_deposit_network('BTC', 'Bitcoin Mainnet!', 3, null, false, 1, true)$q$, 'deposit_networks_network_check');

select public.d_run('provision a per-user BTC address (caller supplies the address string)',
  $q$select public.register_deposit_address('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREBTCADDRESS0001', null, 'u1 btc')$q$);
select public.d_expect('provisioning is per-user, per-asset, per-network',
  $q$select count(*)::text from public.deposit_addresses where address = 'TESTFIXTUREBTCADDRESS0001' and user_id = '11111111-1111-1111-1111-111111111111'$q$, '1');
select public.d_expect('re-registering the same address is idempotent (one row)',
  $q$select (public.register_deposit_address('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREBTCADDRESS0001') =
             (select id from public.deposit_addresses where address = 'TESTFIXTUREBTCADDRESS0001'))::text$q$, 'true');
select public.d_expect('... and still one row', $q$select count(*)::text from public.deposit_addresses$q$, '1');
select public.d_expect_error('a different address does not silently replace the active one',
  $q$select public.register_deposit_address('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREBTCADDRESS0002')$q$,
  'already has an active');
select public.d_expect_error('an address on an unregistered network is refused (ETH has no tron network)',
  $q$select public.register_deposit_address('11111111-1111-1111-1111-111111111111', 'ETH', 'tron', 'TESTFIXTUREETHADDRESS0001')$q$,
  'is not registered for');
select public.d_expect_error('an address with whitespace is refused',
  $q$select public.register_deposit_address('22222222-2222-2222-2222-222222222222', 'USDT', 'tron', 'TESTFIXTURE usdt tron')$q$,
  'deposit_addresses_address_check');
select public.d_expect_error('a shared (NULL user) address is not provisionable',
  $q$select public.register_deposit_address(null, 'BTC', 'bitcoin', 'TESTFIXTURESHARED0001')$q$, 'p_user_id is required');
select public.d_run('provision a USDT/tron address for the second user',
  $q$select public.register_deposit_address('22222222-2222-2222-2222-222222222222', 'USDT', 'tron', 'TESTFIXTUREUSDTTRON0001')$q$);
select public.d_expect('exactly the two addresses we registered exist (nothing was seeded)',
  $q$select count(*)::text from public.deposit_addresses$q$, '2');

\echo '=== D2. recording a deposit: identity, idempotency, confirmation policy'
select public.d_run('record an observed BTC deposit (0 confirmations)',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTURETXBT1', 100000000, -1, 'TESTFIXTUREBTCADDRESS0001')$q$);
select public.d_expect('a new deposit starts pending', $q$select status from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, 'pending');
select public.d_expect('the row records which path produced it (source/environment)',
  $q$select source || '/' || environment from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, 'paper_operator/paper');
select public.d_expect('required_confirmations is the network snapshot at record time',
  $q$select required_confirmations::text from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, '3');
select public.d_expect('amount is stored in integer base units', $q$select amount_units::text from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, '100000000');
select public.d_expect('replaying the same (network, txid, log_index) returns the same deposit',
  $q$select (public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTURETXBT1', 100000000, -1) =
             (select id from public.deposits where txid = 'TESTFIXTURETXBT1'))::text$q$, 'true');
select public.d_expect('... and did not create a second row', $q$select count(*)::text from public.deposits$q$, '1');
select public.d_expect_error('a direct duplicate insert violates deposits_chain_key (unique guard #1)',
  $q$insert into public.deposits (user_id, asset_id, network, environment, source, txid, log_index, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'paper', 'paper_operator', 'TESTFIXTURETXBT2', -1, 100000000, 3, 'pending' from public.assets a where a.symbol = 'BTC';
     insert into public.deposits (user_id, asset_id, network, environment, source, txid, log_index, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'paper', 'paper_operator', 'TESTFIXTURETXBT2', -1, 100000000, 3, 'pending' from public.assets a where a.symbol = 'BTC';
     select 'no-unique-guard'$q$, 'deposits_chain_key', 'service_role');
select public.d_expect('the rejected duplicate left no row', $q$select count(*)::text from public.deposits where txid = 'TESTFIXTURETXBT2'$q$, '0');
select public.d_expect_error('an unknown network cannot receive a deposit',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'tron', 'TESTFIXTURETXBAD1', 100000000)$q$,
  'is not registered for');
select public.d_expect_error('a non-integer amount is refused',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTURETXBAD2', 1.5)$q$,
  'positive whole number');
select public.d_expect_error('a zero amount is refused',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTURETXBAD3', 0)$q$,
  'positive whole number');
select public.d_expect_error('a blank txid is refused',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', '   ', 100000000)$q$,
  'txid');
select public.d_expect_error('an unknown user cannot receive a deposit',
  $q$select public.record_deposit('33333333-3333-3333-3333-333333333333', 'BTC', 'bitcoin', 'TESTFIXTURETXBAD4', 100000000)$q$,
  'unknown user');
select public.d_expect('record_deposit did not create anything for the rejected attempts',
  $q$select count(*)::text from public.deposits$q$, '1');

select public.d_expect_error('crediting a deposit on a network that is not enabled is refused',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'))$q$, 'deposits are not enabled');
select public.d_expect('set_deposit_confirmations moves pending -> confirming',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 1)$q$, 'confirming');
select public.d_expect('still below the policy after 2 of 3 confirmations',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 2)$q$, 'confirming');
select public.d_expect_error('confirmations cannot go backwards',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 1)$q$, 'cannot go backwards');
select public.d_run('enable the BTC/bitcoin network (operator configuration)',
  $q$select public.register_deposit_network('BTC', 'bitcoin', 3, 0, false, 50000000, true)$q$);
select public.d_expect_error('crediting below the confirmation policy is refused (and says so)',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'))$q$, 'required confirmations');
select public.d_expect('set_deposit_confirmations reaches the policy and confirms the deposit',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 3)$q$, 'confirmed');
select public.d_expect('a confirmed deposit carries no credit data yet (credit is data, not a status)',
  $q$select (credited_ledger_transaction_id is null and credited_at is null)::text from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, 'true');

select public.d_run('record a deposit on a network that has NO confirmation policy (USDT/solana, 0 confirmations)',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'USDT', 'solana', 'TESTFIXTURESOLPOLICY', 20000000, -1, null, null, 0)$q$);
select public.d_expect_error('a network with required_confirmations = 0 cannot be credited (configuration error)',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURESOLPOLICY'))$q$, 'confirmation policy');

\echo '=== D3. crediting posts through the immutable double-entry ledger'
select public.d_run('credit the confirmed BTC deposit (capture what credit_deposit returns)',
  $q$insert into public.d_ret(label, val)
     select 'credit_btc', public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'))::text$q$);
select public.d_expect('credit_deposit returns the ledger transaction it wrote',
  $q$select (r.val = d.credited_ledger_transaction_id::text)::text
          from public.d_ret r, public.deposits d
         where r.label = 'credit_btc' and d.txid = 'TESTFIXTURETXBT1'$q$, 'true');
select public.d_expect('... and the returned id is a real ledger_transactions row (type/environment)',
  $q$select t.type || '/' || t.environment
          from public.ledger_transactions t join public.d_ret r on t.id::text = r.val
         where r.label = 'credit_btc'$q$, 'deposit_credit/paper');
select public.d_expect('the deposit is still confirmed after crediting (no credited status exists)',
  $q$select status from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, 'confirmed');
select public.d_expect('credited_at is set', $q$select (credited_at is not null)::text from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, 'true');
select public.d_expect('the ledger transaction is a deposit_credit in paper, referencing the deposit',
  $q$select t.type || '/' || t.environment || '/' || t.reference_type || '/' || (t.reference_id = d.id)::text
          from public.ledger_transactions t join public.deposits d on d.credited_ledger_transaction_id = t.id
         where d.txid = 'TESTFIXTURETXBT1'$q$, 'deposit_credit/paper/deposit/true');
select public.d_expect('the ledger transaction carries the deposit chain identity as its idempotency key',
  $q$select t.idempotency_key from public.ledger_transactions t join public.deposits d on d.credited_ledger_transaction_id = t.id
         where d.txid = 'TESTFIXTURETXBT1'$q$, 'deposit_credit:paper:bitcoin:TESTFIXTURETXBT1:-1');
select public.d_expect('exactly two postings, on two different accounts',
  $q$select count(*)::text || '/' || count(distinct e.account_id)::text
          from public.ledger_entries e join public.deposits d on d.credited_ledger_transaction_id = e.transaction_id
         where d.txid = 'TESTFIXTURETXBT1'$q$, '2/2');
select public.d_expect('the credited transaction is zero-sum per asset (double-entry invariant)',
  $q$select coalesce(sum(e.amount_units), 0)::text
          from public.ledger_entries e join public.deposits d on d.credited_ledger_transaction_id = e.transaction_id
         where d.txid = 'TESTFIXTURETXBT1'$q$, '0');
select public.d_expect('the user account is credited for the deposit amount',
  $q$select e.amount_units::text
          from public.ledger_entries e join public.deposits d on d.credited_ledger_transaction_id = e.transaction_id
          join public.accounts a on a.id = e.account_id
         where d.txid = 'TESTFIXTURETXBT1' and a.account_type = 'user' and a.kind = 'available'$q$, '100000000');
select public.d_expect('the EXTERNAL_DEPOSIT system account is debited (the counterparty side)',
  $q$select e.amount_units::text || '/' || a.code
          from public.ledger_entries e join public.deposits d on d.credited_ledger_transaction_id = e.transaction_id
          join public.accounts a on a.id = e.account_id
         where d.txid = 'TESTFIXTURETXBT1' and a.account_type = 'system'$q$, '-100000000/EXTERNAL_DEPOSIT');
select public.d_expect('no account shows reconciliation drift after the credit',
  $q$select count(*)::text from public.v_account_reconciliation
         where account_id in (select account_id from public.ledger_entries e join public.deposits d on d.credited_ledger_transaction_id = e.transaction_id where d.txid = 'TESTFIXTURETXBT1')
           and drift_units <> 0$q$, '0');
select public.d_expect('no user account is negative after the credit',
  $q$select count(*)::text from public.balances b join public.accounts a on a.id = b.account_id
         where a.account_type = 'user' and (b.available_units < 0 or b.locked_units < 0)$q$, '0');
select public.d_expect_error('crediting the same deposit twice is refused (guard #2)',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'))$q$, 'already credited');
select public.d_expect('the double-credit attempt wrote no extra ledger transaction',
  $q$select count(*)::text from public.ledger_transactions where type = 'deposit_credit'$q$, '1');
select public.d_expect_error('the ledger idempotency key cannot be reused (guard #3)',
  $q$insert into public.ledger_transactions (type, environment, idempotency_key, reference_type, reference_id)
     select 'deposit_credit', 'paper', 'deposit_credit:paper:bitcoin:TESTFIXTURETXBT1:-1', 'deposit', d.id
       from public.deposits d where d.txid = 'TESTFIXTURETXBT1';
     select 'no-ledger-guard'$q$, 'ledger_transactions_idempotency_key');

\echo '=== D4. state machine: legal/illegal transitions, the review hold, immutable identity'
select public.d_expect_error('a credited deposit can never leave confirmed (credit state CHECK)',
  $q$update public.deposits set status = 'failed', failed_reason = 'nope' where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'deposits_credit_state_check');
select public.d_expect_error('fail_deposit refuses a confirmed (credited) deposit',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 'nope')$q$, 'cannot be failed here');
select public.d_expect_error('the chain identity of a deposit is immutable (txid)',
  $q$update public.deposits set txid = 'TESTFIXTUREOTHER' where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'immutable');
select public.d_expect_error('the chain identity of a deposit is immutable (amount)',
  $q$update public.deposits set amount_units = 1 where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'immutable');
select public.d_expect_error('the source of a deposit is immutable (it says which path produced it)',
  $q$update public.deposits set source = 'provider_adapter' where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'immutable');
select public.d_expect_error('confirmations cannot be lowered after the fact',
  $q$update public.deposits set confirmations = 0 where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'cannot go backwards');
select public.d_expect_error('the credit data of a credited deposit is immutable (ledger transaction)',
  $q$update public.deposits set credited_ledger_transaction_id = null where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'immutable');
select public.d_expect_error('the credit timestamp of a credited deposit is immutable',
  $q$update public.deposits set credited_at = now() where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'immutable');
select public.d_expect('more confirmations after crediting do not move a confirmed deposit',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 9)$q$, 'confirmed');

-- folding: failed carries the reason (cancelled / orphaned / reorged all land here)
select public.d_expect_error('failing a deposit requires a reason',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURESOLPOLICY'), null)$q$, 'requires a reason');
select public.d_expect_error('a failed row without a reason is refused by the table CHECK',
  $q$update public.deposits set status = 'failed' where txid = 'TESTFIXTURESOLPOLICY'; select 'moved'$q$, 'deposits_failed_reason_check');
select public.d_expect('failing a deposit without a confirmation policy records why',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURESOLPOLICY'), 'cancelled: the network has no confirmation policy configured')$q$, 'failed');
select public.d_expect('the failed deposit carries its reason',
  $q$select failed_reason from public.deposits where txid = 'TESTFIXTURESOLPOLICY'$q$, 'cancelled: the network has no confirmation policy configured');
select public.d_expect_error('a failed deposit cannot be failed again (terminal)',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURESOLPOLICY'), 'again')$q$, 'cannot be failed again');
select public.d_expect_error('confirmations of a failed deposit cannot be updated',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURESOLPOLICY'), 9)$q$, 'failed (terminal)');
select public.d_expect_error('credit_deposit refuses a failed deposit',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURESOLPOLICY'))$q$, 'failed');

-- a network whose minimum deposit is not configured cannot be credited
select public.d_run('record a deposit on a network whose minimum deposit is not configured (ETH/ethereum)',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'ETH', 'ethereum', 'TESTFIXTURENOMIN', 1000000000000000000, -1, null, null, 0)$q$);
select public.d_expect_error('a network with no configured minimum cannot credit (NULL = not configured)',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURENOMIN'))$q$, 'minimum deposit is configured');

-- the under-review hold (owner-required)
select public.d_run('record an observed SOL deposit that an operator will hold for review',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'SOL', 'solana', 'TESTFIXTUREREVIEW', 3000000000, -1, null, null, 0)$q$);
select public.d_run('enable the SOL/solana network (operator configuration, before the held deposit is judged)',
  $q$select public.register_deposit_network('SOL', 'solana', 1, null, false, 1000000, true)$q$);
select public.d_expect_error('putting a deposit under review requires a reason',
  $q$select public.set_deposit_under_review((select id from public.deposits where txid = 'TESTFIXTUREREVIEW'), '  ')$q$, 'requires a reason');
select public.d_expect('an operator can put a pending deposit under review',
  $q$select public.set_deposit_under_review((select id from public.deposits where txid = 'TESTFIXTUREREVIEW'), 'TESTFIXTURE: amount needs operator approval')$q$, 'under review');
select public.d_expect('the review reason is recorded',
  $q$select review_reason from public.deposits where txid = 'TESTFIXTUREREVIEW'$q$, 'TESTFIXTURE: amount needs operator approval');
select public.d_expect_error('crediting a deposit under review is refused (owner rule)',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTUREREVIEW'))$q$, 'under review');
select public.d_expect('confirmations arriving do not release an operator hold',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTUREREVIEW'), 2)$q$, 'under review');
select public.d_expect_error('a held deposit cannot be moved back to confirming',
  $q$update public.deposits set status = 'confirming' where txid = 'TESTFIXTUREREVIEW'; select 'moved'$q$, 'illegal deposit status transition');
select public.d_expect_error('a confirmed deposit cannot be put under review',
  $q$select public.set_deposit_under_review((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 'too late')$q$, 'only a pending or confirming deposit');
select public.d_expect('the operator releases the hold by confirming the deposit',
  $q$select public.confirm_deposit((select id from public.deposits where txid = 'TESTFIXTUREREVIEW'))$q$, 'confirmed');
select public.d_run('credit the released deposit',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTUREREVIEW'))$q$);
select public.d_expect('the released deposit is confirmed and carries its credit data',
  $q$select status || '/' || (credited_ledger_transaction_id is not null)::text from public.deposits where txid = 'TESTFIXTUREREVIEW'$q$, 'confirmed/true');
select public.d_expect('the review reason is kept as the audit trail',
  $q$select (review_reason is not null)::text from public.deposits where txid = 'TESTFIXTUREREVIEW'$q$, 'true');
select public.d_expect_error('a held deposit below its policy cannot be force-confirmed',
  $q$select public.confirm_deposit((select id from public.deposits where txid = 'TESTFIXTURENOMIN'))$q$, 'cannot be confirmed yet');

-- an operator can also reject a held deposit (the old 'cancelled'/'orphaned' outcomes)
select public.d_run('an operator holds the no-minimum deposit and then rejects it',
  $q$select public.set_deposit_under_review((select id from public.deposits where txid = 'TESTFIXTURENOMIN'), 'reviewing an unmatched address');
     select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURENOMIN'), 'rejected: unmatched deposit address')$q$);
select public.d_expect('the rejected deposit is failed, with the reason kept',
  $q$select status || '/' || failed_reason from public.deposits where txid = 'TESTFIXTURENOMIN'$q$, 'failed/rejected: unmatched deposit address');
select public.d_run('record an observed SOL deposit that will be orphaned',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'SOL', 'solana', 'TESTFIXTUREORPHAN', 2000000000, -1, null, null, 0)$q$);
select public.d_run('mark an uncredited SOL deposit orphaned (folds into failed + reason)',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTUREORPHAN'), 'orphaned: dropped from the mempool')$q$);

-- a second user, a deposit already at its policy, and an off-policy amount
select public.d_run('record a USDT/tron deposit for the second user, already at 20 confirmations',
  $q$select public.record_deposit('22222222-2222-2222-2222-222222222222', 'USDT', 'tron', 'TESTFIXTURETXUSDT1', 20000000, 0, 'TESTFIXTUREUSDTTRON0001', null, 20)$q$);
select public.d_expect('a deposit recorded at or above its policy is confirmed, not pending',
  $q$select status from public.deposits where txid = 'TESTFIXTURETXUSDT1'$q$, 'confirmed');
select public.d_run('credit it', $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXUSDT1'))$q$);
select public.d_expect('the second credit also balances to zero',
  $q$select coalesce(sum(e.amount_units), 0)::text
          from public.ledger_entries e join public.deposits d on d.credited_ledger_transaction_id = e.transaction_id
         where d.txid = 'TESTFIXTURETXUSDT1'$q$, '0');
select public.d_expect('a transfer with the same txid but a different log_index is a different deposit',
  $q$select (public.record_deposit('22222222-2222-2222-2222-222222222222', 'USDT', 'tron', 'TESTFIXTURETXUSDT1', 5000000, 3, null, null, 20) is distinct from
             (select id from public.deposits where txid = 'TESTFIXTURETXUSDT1' and log_index = 0))::text$q$, 'true');
select public.d_expect_error('... and it is still refused by the minimum deposit policy',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXUSDT1' and log_index = 3))$q$,
  'below the configured minimum');
select public.d_expect('the below-minimum deposit was not credited',
  $q$select status || '/' || (credited_ledger_transaction_id is null)::text from public.deposits where txid = 'TESTFIXTURETXUSDT1' and log_index = 3$q$, 'confirmed/true');
select public.d_expect('a below-minimum deposit is failed by an operator with a reason (the old cancelled)',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURETXUSDT1' and log_index = 3), 'cancelled: operator rejected the off-policy amount')$q$, 'failed');

select public.d_expect('every status in the table is one of the owner''s five',
  $q$select count(*)::text from public.deposits where status not in ('pending', 'confirming', 'confirmed', 'failed', 'under review')$q$, '0');
select public.d_expect('the old status names are gone from the data',
  $q$select count(*)::text from public.deposits where status in ('detected', 'credited', 'cancelled', 'orphaned', 'reorged')$q$, '0');

\echo '=== D5. RLS and function ACL matrix (anon / authenticated / service_role)'
select public.d_expect_error('anon cannot read deposits',
  $q$select count(*)::text from public.deposits$q$, 'permission denied', 'anon');
select public.d_expect_error('anon cannot read deposit addresses',
  $q$select count(*)::text from public.deposit_addresses$q$, 'permission denied', 'anon');
select public.d_expect_error('anon cannot read the deposit configuration',
  $q$select count(*)::text from public.deposit_networks$q$, 'permission denied', 'anon');
select public.d_expect_error('anon cannot call credit_deposit',
  $q$select public.credit_deposit((select id from public.deposits limit 1))$q$, 'permission denied', 'anon');
select public.d_expect_error('anon cannot call record_deposit',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREANON', 100000000)$q$,
  'permission denied', 'anon');
select public.d_expect_error('anon cannot call record_provider_deposit (the adapter path)',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC","user_id":"11111111-1111-1111-1111-111111111111","txid":"TESTFIXTUREANON3","amount_units":1}'::jsonb)$q$,
  'permission denied', 'anon');
select public.d_expect_error('anon cannot call register_deposit_address',
  $q$select public.register_deposit_address('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREANON2')$q$,
  'permission denied', 'anon');

select public.d_expect('u1 sees only their own deposits',
  $q$select count(*)::text from public.deposits$q$, '5', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect('u1 cannot see u2''s deposit',
  $q$select count(*)::text from public.deposits where user_id = '22222222-2222-2222-2222-222222222222'$q$, '0',
  'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect('u2 sees only their own deposits',
  $q$select count(*)::text from public.deposits$q$, '2', 'authenticated', '22222222-2222-2222-2222-222222222222');
select public.d_expect('u1 sees only their own deposit address',
  $q$select count(*)::text from public.deposit_addresses$q$, '1', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect('signed-in users can read the network configuration (reference data)',
  $q$select count(*)::text from public.deposit_networks$q$, '6', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect_error('a signed-in user has no write path to deposits',
  $q$insert into public.deposits (user_id, asset_id, network, environment, source, txid, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'paper', 'paper_operator', 'TESTFIXTURECLIENT', 100000000, 3, 'pending' from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect_error('a signed-in user cannot rewrite their own deposit',
  $q$update public.deposits set status = 'failed', failed_reason = 'mine now' where txid = 'TESTFIXTURETXBT1'; select 'updated'$q$,
  'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect_error('a signed-in user cannot move a financial status through the operator functions',
  $q$select public.set_deposit_under_review((select id from public.deposits limit 1), 'mine now')$q$,
  'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect_error('a signed-in user cannot credit their own deposit',
  $q$select public.credit_deposit((select id from public.deposits limit 1))$q$,
  'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect_error('a signed-in user cannot record a deposit',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREUSERREC', 100000000)$q$,
  'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect('service_role sees every deposit',
  $q$select count(*)::text from public.deposits$q$, '7', 'service_role');
select public.d_expect('service_role sees every address',
  $q$select count(*)::text from public.deposit_addresses$q$, '2', 'service_role');

select public.d_expect('no privileged deposit function is executable by anon, authenticated or PUBLIC',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('assert_deposits_enabled','assert_paper_deposits_enabled','register_deposit_network','register_deposit_address',
                             'record_deposit','record_provider_deposit','_deposit_ingest','set_deposit_confirmations',
                             'confirm_deposit','set_deposit_under_review','fail_deposit','credit_deposit')
           and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))$q$, '0');
select public.d_expect('all twelve service_role entry points exist and are executable by service_role',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('assert_deposits_enabled','assert_paper_deposits_enabled','register_deposit_network','register_deposit_address',
                             'record_deposit','record_provider_deposit','_deposit_ingest','set_deposit_confirmations',
                             'confirm_deposit','set_deposit_under_review','fail_deposit','credit_deposit')
           and has_function_privilege('service_role', p.oid, 'EXECUTE')$q$, '12');
-- 20261005100150 (admin operations) added exactly ONE view that reads the deposits
-- table: v_admin_deposits, the operator money-path monitor required by the stage-2
-- control plane. The original guarantee ("no view exposes deposit data") is kept in
-- the only form that still means something: no view exposes it to a NON-operator.
-- D5b below proves the view returns nothing to an ordinary caller and is not
-- readable by anon; the admin suite (A12) proves an operator without money.read
-- gets nothing either.
select public.d_expect('the only view over deposit data is the operator-only monitor',
  $q$select string_agg(viewname, ',' order by viewname) from pg_views
        where schemaname = 'public' and (definition ilike '%deposit%' or viewname ilike '%deposit%')$q$,
  'v_admin_deposits');
select public.d_expect('... and it returns ZERO rows to a caller who is not an operator',
  $q$select count(*)::text from public.v_admin_deposits$q$, '0');
select public.d_expect('the deposit tables are not in a publication (no realtime leak)',
  $q$select count(*)::text from pg_publication_tables where schemaname = 'public' and tablename in ('deposits','deposit_addresses','deposit_networks')$q$, '0');

\echo '=== D6. LIVE_DEPOSITS_ENABLED gate + paper/real path separation (flipped in THIS database only)'
select public.d_run('paper path: an operator records a paper deposit while deposits_enabled = false',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREPAPER1', 100000000, -1, null, null, 0)$q$);
select public.d_expect('... recorded as a paper deposit by the operator/test path',
  $q$select environment || '/' || status || '/' || source from public.deposits where txid = 'TESTFIXTUREPAPER1'$q$, 'paper/pending/paper_operator');
select public.d_expect_error('the provider adapter path is refused in paper mode (paper data can never enter through it)',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC","user_id":"11111111-1111-1111-1111-111111111111","txid":"TESTFIXTUREADAPTER0","amount_units":100000000,"provider_ref":"TESTFIXTUREPROVIDERREF"}'::jsonb)$q$,
  'live-only');
select public.d_expect_error('a live deposit row is refused while the exchange is in paper mode',
  $q$insert into public.deposits (user_id, asset_id, network, environment, source, txid, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'live', 'provider_adapter', 'TESTFIXTURELIVE1', 100000000, 3, 'pending' from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'live row rejected');
select public.d_run('open the live switch as an operator would (mode=live, live_trading_enabled=true, deposits_enabled=false)',
  $q$update public.app_settings set mode = 'live', live_trading_enabled = true, live_enabled_at = now(), deposits_enabled = false$q$);
select public.d_run('register the network in the live environment',
  $q$select public.register_deposit_network('BTC', 'bitcoin', 3, 0, false, 50000000, false)$q$);
select public.d_expect_error('with deposits_enabled = false a live deposit row is refused by the flag',
  $q$insert into public.deposits (user_id, asset_id, network, environment, source, txid, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'live', 'provider_adapter', 'TESTFIXTURELIVE2', 100000000, 3, 'pending' from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'deposits is not enabled');
select public.d_expect_error('with deposits_enabled = false the adapter itself is refused by LIVE_DEPOSITS_ENABLED',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC","user_id":"11111111-1111-1111-1111-111111111111","txid":"TESTFIXTUREADAPTER1","amount_units":100000000,"provider_ref":"TESTFIXTUREPROVIDERREF"}'::jsonb)$q$,
  'live deposits are disabled');
select public.d_expect_error('an adapter event that does not match the contract is refused',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC","txid":"TESTFIXTUREADAPTER2"}'::jsonb)$q$,
  'contract violation');
select public.d_expect_error('... including a non-numeric amount',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC","user_id":"11111111-1111-1111-1111-111111111111","txid":"TESTFIXTUREADAPTER3","amount_units":"lots"}'::jsonb)$q$,
  'contract violation');
select public.d_run('flip deposits_enabled on (scratch database only)',
  $q$update public.app_settings set deposits_enabled = true$q$);
select public.d_run('with the flag on, the provider adapter records the same live event',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC","user_id":"11111111-1111-1111-1111-111111111111","txid":"TESTFIXTUREADAPTER4","amount_units":100000000,"log_index":-1,"confirmations":0,"to_address":"TESTFIXTURELIVEADDRESS0001","provider_ref":"TESTFIXTUREPROVIDERREF"}'::jsonb)$q$);
select public.d_expect('with the flag on, the live adapter row is accepted (so the refusals above were the gate, not a syntax artefact)',
  $q$select count(*)::text from public.deposits where environment = 'live' and source = 'provider_adapter'$q$, '1');
select public.d_expect('the adapter row maps the event into the row as the contract says',
  $q$select status || '/' || log_index::text || '/' || address || '/' || (raw->>'provider_ref')
          from public.deposits where txid = 'TESTFIXTUREADAPTER4'$q$, 'pending/-1/TESTFIXTURELIVEADDRESS0001/TESTFIXTUREPROVIDERREF');
select public.d_expect('an adapter event is never credited automatically (no credit data)',
  $q$select (credited_ledger_transaction_id is null and credited_at is null)::text from public.deposits where txid = 'TESTFIXTUREADAPTER4'$q$, 'true');
select public.d_expect_error('while the exchange is live, the paper operator path is refused (no paper data among real deposits)',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREPAPERLIVE', 100000000)$q$,
  'paper-only');
select public.d_expect('the two paths stay distinguishable in the data (source pairs with environment)',
  $q$select count(*)::text from public.deposits where (source = 'provider_adapter') <> (environment = 'live')$q$, '0');
select public.d_run('close the live switch again and remove the live probe rows',
  $q$delete from public.deposits where environment = 'live';
     delete from public.deposit_networks where environment = 'live';
     update public.app_settings set mode = 'paper', live_trading_enabled = false, live_enabled_at = null, deposits_enabled = false$q$);
select public.d_expect('the switch is back where it started (paper, all live flags off)',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/' || (live_enabled_at is null)::text from public.app_settings$q$,
  'paper/false/false/true');
select public.d_expect('no live deposit row survived the probe',
  $q$select count(*)::text from public.deposits where environment = 'live'$q$, '0');
select public.d_expect('every surviving deposit is a paper_operator row',
  $q$select count(*)::text from public.deposits where not (source = 'paper_operator' and environment = 'paper')$q$, '0');
select public.d_expect('the paper operator path still works while deposits_enabled = false (the flag gates the live path)',
  $q$select (select count(*) from public.deposits where txid = 'TESTFIXTUREPAPER1')::text || '/' || environment from public.deposits where txid = 'TESTFIXTUREPAPER1'$q$,
  '1/paper');

\echo '=== D7. paper_deposits_enabled — the paper sandbox switch (flipped in THIS database only)'
select public.d_expect('the paper switch starts ON while the live switch is OFF (paper/false/true)',
  $q$select mode || '/' || deposits_enabled::text || '/' || paper_deposits_enabled::text from public.app_settings$q$,
  'paper/false/true');
select public.d_run('record a creditable paper deposit while the paper switch is ON (setup)',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREPAPERGATE1', 100000000, -1, null, null, 3)$q$);
select public.d_expect('... it is a confirmed, uncredited paper row (ready for the credit refusal)',
  $q$select environment || '/' || status || '/' || (credited_ledger_transaction_id is null)::text from public.deposits where txid = 'TESTFIXTUREPAPERGATE1'$q$,
  'paper/confirmed/true');
select public.d_run('switch paper deposits OFF (scratch database only)',
  $q$update public.app_settings set paper_deposits_enabled = false$q$);
select public.d_expect('the paper switch reads back OFF, with mode and the live switch untouched',
  $q$select mode || '/' || deposits_enabled::text || '/' || paper_deposits_enabled::text from public.app_settings$q$,
  'paper/false/false');
select public.d_expect_error('with the paper switch OFF, record_deposit is refused',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREPAPERGATE2', 100000000, -1, null, null, 3)$q$,
  'paper deposits are disabled');
select public.d_expect('... and no row was written for it',
  $q$select count(*)::text from public.deposits where txid = 'TESTFIXTUREPAPERGATE2'$q$, '0');
select public.d_expect_error('with the paper switch OFF, credit_deposit of a paper deposit is refused',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTUREPAPERGATE1'))$q$,
  'paper deposits are disabled');
select public.d_expect('... and the refused credit left no credit data behind',
  $q$select (credited_ledger_transaction_id is null and credited_at is null)::text from public.deposits where txid = 'TESTFIXTUREPAPERGATE1'$q$,
  'true');
do $g$
declare v_rec text; v_cred text;
begin
  begin
    perform public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREPAPERGATE3', 100000000, -1, null, null, 3);
  exception when others then v_rec := sqlerrm; end;
  begin
    perform public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTUREPAPERGATE1'));
  exception when others then v_cred := sqlerrm; end;
  insert into public.d_ret(label, val) values ('paper_record_msg', v_rec), ('paper_credit_msg', v_cred);
end $g$;
select public.d_expect('both paper refusals carry the paper message and not the live one (distinct errors)',
  $q$select count(*)::text from public.d_ret
         where label in ('paper_record_msg','paper_credit_msg')
           and val like 'paper deposits are disabled:%'
           and val not like '%live deposits are disabled%'$q$, '2');
select public.d_run('switch paper deposits back ON (scratch database only)',
  $q$update public.app_settings set paper_deposits_enabled = true$q$);
select public.d_expect('the paper switch reads back ON, live switch and mode still untouched (paper/false/true)',
  $q$select mode || '/' || deposits_enabled::text || '/' || paper_deposits_enabled::text from public.app_settings$q$,
  'paper/false/true');
select public.d_run('with the switch ON, record_deposit accepts the same paper deposit',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREPAPERGATE2', 100000000, -1, null, null, 3)$q$);
select public.d_expect('... and it is a confirmed paper row written by the operator/test path',
  $q$select environment || '/' || status || '/' || source from public.deposits where txid = 'TESTFIXTUREPAPERGATE2'$q$,
  'paper/confirmed/paper_operator');
select public.d_run('with the switch ON, credit_deposit credits the paper deposit',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTUREPAPERGATE1'))$q$);
select public.d_expect('... the credit is data on the row and points at a paper deposit_credit ledger transaction',
  $q$select d.status || '/' || (d.credited_ledger_transaction_id is not null)::text || '/' || lt.type || '/' || lt.environment
          from public.deposits d join public.ledger_transactions lt on lt.id = d.credited_ledger_transaction_id
         where d.txid = 'TESTFIXTUREPAPERGATE1'$q$,
  'confirmed/true/deposit_credit/paper');
select public.d_expect('... and that ledger transaction is balanced (two postings, zero sum)',
  $q$select count(*)::text || '/' || coalesce(sum(e.amount_units), 0)::text
          from public.ledger_entries e join public.deposits d on d.credited_ledger_transaction_id = e.transaction_id
         where d.txid = 'TESTFIXTUREPAPERGATE1'$q$,
  '2/0');
select public.d_expect_error('the live gate is unaffected by the paper switch: with the paper switch ON a live row is still refused in paper mode',
  $q$insert into public.deposits (user_id, asset_id, network, environment, source, txid, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'live', 'provider_adapter', 'TESTFIXTURELIVEPAPERGATE1', 100000000, 3, 'pending' from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'live row rejected');
select public.d_expect_error('... and the live adapter path is still refused while the exchange is in paper mode',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC","user_id":"11111111-1111-1111-1111-111111111111","txid":"TESTFIXTURELIVEPAPERGATE2","amount_units":100000000}'::jsonb)$q$,
  'live-only');
select public.d_expect('no live deposit row exists after the paper-switch probe',
  $q$select count(*)::text from public.deposits where environment = 'live'$q$, '0');
select public.d_expect('the source/environment pairing CHECK is intact after the paper-switch probe',
  $q$select count(*)::text from public.deposits where (source = 'provider_adapter') <> (environment = 'live')$q$, '0');
select public.d_expect('the switches end where they started (paper, live flags off, paper deposits on)',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/' || paper_deposits_enabled::text || '/' || (live_enabled_at is null)::text from public.app_settings$q$,
  'paper/false/false/true/true');

\echo '=== SUMMARY'
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from public.d_res;
select count(*) filter (where not ok) as failures from public.d_res;
