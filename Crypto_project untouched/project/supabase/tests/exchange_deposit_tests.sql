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
-- Gating choice this suite pins down (flagged in the build report): in paper
-- mode the operator path is NOT gated by app_settings.deposits_enabled — that
-- flag is the DB side of the plan's LIVE_DEPOSITS_ENABLED and gates the live
-- path, which is asserted here by refusing a live row in paper mode and by
-- refusing a live row while deposits_enabled = false.
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
end $g$;

-- counters live in a real table so that a statement that is later rolled back
-- (there is none: this suite never relies on a rollback) cannot lose a result
create table if not exists public.d_res(seq serial primary key, label text, ok boolean);
delete from public.d_res;

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
select public.d_run('register USDT/ethereum, USDT/tron (enabled, min 10 USDT), USDT/solana',
  $q$select (public.register_deposit_network('USDT', 'ethereum', 12, 1, false, 10000000, false))::text ||
           (public.register_deposit_network('USDT', 'tron', 20, null, false, 10000000, true))::text ||
           (public.register_deposit_network('USDT', 'solana', 1, null, false, 10000000, false))::text$q$);
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
select public.d_expect_error('an address on an unregistered network is refused',
  $q$select public.register_deposit_address('11111111-1111-1111-1111-111111111111', 'ETH', 'ethereum', 'TESTFIXTUREETHADDRESS0001')$q$,
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
select public.d_expect('a new deposit starts detected', $q$select status from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, 'detected');
select public.d_expect('required_confirmations is the network snapshot at record time',
  $q$select required_confirmations::text from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, '3');
select public.d_expect('amount is stored in integer base units', $q$select amount_units::text from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, '100000000');
select public.d_expect('replaying the same (network, txid, log_index) returns the same deposit',
  $q$select (public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTURETXBT1', 100000000, -1) =
             (select id from public.deposits where txid = 'TESTFIXTURETXBT1'))::text$q$, 'true');
select public.d_expect('... and did not create a second row', $q$select count(*)::text from public.deposits$q$, '1');
select public.d_expect_error('a direct duplicate insert violates deposits_chain_key (unique guard #1)',
  $q$insert into public.deposits (user_id, asset_id, network, environment, txid, log_index, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'paper', 'TESTFIXTURETXBT2', -1, 100000000, 3, 'detected' from public.assets a where a.symbol = 'BTC';
     insert into public.deposits (user_id, asset_id, network, environment, txid, log_index, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'paper', 'TESTFIXTURETXBT2', -1, 100000000, 3, 'detected' from public.assets a where a.symbol = 'BTC';
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

select public.d_expect_error('crediting below the confirmation policy is refused',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'))$q$, 'required confirmations');
select public.d_expect('set_deposit_confirmations moves detected -> confirming',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 1)$q$, 'confirming');
select public.d_expect('still below the policy after 2 of 3 confirmations',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 2)$q$, 'confirming');
select public.d_expect_error('confirmations cannot go backwards',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 1)$q$, 'cannot go backwards');
select public.d_expect_error('crediting a deposit on a network that is not enabled is refused',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'))$q$, 'deposits are not enabled');
select public.d_run('enable the BTC/bitcoin network (operator configuration)',
  $q$select public.register_deposit_network('BTC', 'bitcoin', 3, 0, false, 50000000, true)$q$);
select public.d_run('reach the confirmation policy (3 of 3)',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 3)$q$);

\echo '=== D3. crediting posts through the immutable double-entry ledger'
select public.d_expect('credit_deposit returns the ledger transaction it wrote',
  $q$select (public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1')) =
             (select credited_ledger_transaction_id from public.deposits where txid = 'TESTFIXTURETXBT1'))::text$q$, 'true');
select public.d_expect('the deposit is credited', $q$select status from public.deposits where txid = 'TESTFIXTURETXBT1'$q$, 'credited');
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
\echo '=== D4. state machine: illegal transitions and immutable identity'
select public.d_expect_error('a credited deposit cannot move to failed',
  $q$update public.deposits set status = 'failed' where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'illegal deposit status transition');
select public.d_expect_error('fail_deposit refuses a credited deposit',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 'failed', 'nope')$q$, 'terminal');
select public.d_expect_error('fail_deposit only accepts the terminal non-credit states',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 'credited', 'nope')$q$, 'can only move a deposit to');
select public.d_expect_error('the chain identity of a deposit is immutable (txid)',
  $q$update public.deposits set txid = 'TESTFIXTUREOTHER' where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'immutable');
select public.d_expect_error('the chain identity of a deposit is immutable (amount)',
  $q$update public.deposits set amount_units = 1 where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'immutable');
select public.d_expect_error('confirmations cannot be lowered after the fact',
  $q$update public.deposits set confirmations = 0 where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'cannot go backwards');
select public.d_expect_error('confirmations of a terminal deposit cannot be updated',
  $q$select public.set_deposit_confirmations((select id from public.deposits where txid = 'TESTFIXTURETXBT1'), 9)$q$, 'terminal');
select public.d_expect_error('a credited row can never exist without its ledger transaction (CHECK)',
  $q$update public.deposits set credited_ledger_transaction_id = null where txid = 'TESTFIXTURETXBT1'; select 'moved'$q$, 'immutable');

select public.d_run('record a USDT/tron deposit for the second user, already at 20 confirmations',
  $q$select public.record_deposit('22222222-2222-2222-2222-222222222222', 'USDT', 'tron', 'TESTFIXTURETXUSDT1', 20000000, 0, 'TESTFIXTUREUSDTTRON0001', null, 20)$q$);
select public.d_expect('a deposit recorded above the policy starts confirming, not detected',
  $q$select status from public.deposits where txid = 'TESTFIXTURETXUSDT1'$q$, 'confirming');
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
  $q$select status from public.deposits where txid = 'TESTFIXTURETXUSDT1' and log_index = 3$q$, 'confirming');
select public.d_run('record a deposit on a network whose minimum deposit is not configured (ETH/ethereum)',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'ETH', 'ethereum', 'TESTFIXTURENOMIN', 1000000000000000000, -1, null, null, 0)$q$);
select public.d_run('record an observed SOL deposit that will be orphaned',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'SOL', 'solana', 'TESTFIXTUREORPHAN', 2000000000, -1, null, null, 0)$q$);
select public.d_expect_error('a network with no configured minimum cannot credit (NULL = not configured)',
  $q$select public.credit_deposit((select id from public.deposits where txid = 'TESTFIXTURENOMIN'))$q$, 'minimum deposit is configured');
select public.d_run('cancel an uncredited deposit (operator decision)',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURETXUSDT1' and log_index = 3), 'cancelled', 'operator cancelled the off-policy amount')$q$);
select public.d_expect('the cancelled deposit is cancelled', $q$select status from public.deposits where txid = 'TESTFIXTURETXUSDT1' and log_index = 3$q$, 'cancelled');
select public.d_expect_error('a terminal deposit cannot be failed again',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTURETXUSDT1' and log_index = 3), 'failed', 'again')$q$, 'terminal');
select public.d_run('mark an uncredited SOL deposit orphaned',
  $q$select public.fail_deposit((select id from public.deposits where txid = 'TESTFIXTUREORPHAN'), 'orphaned', 'dropped from the mempool')$q$);

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
select public.d_expect_error('anon cannot call register_deposit_address',
  $q$select public.register_deposit_address('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREANON2')$q$,
  'permission denied', 'anon');

select public.d_expect('u1 sees only their own deposits',
  $q$select count(*)::text from public.deposits$q$, '3', 'authenticated', '11111111-1111-1111-1111-111111111111');
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
  $q$insert into public.deposits (user_id, asset_id, network, environment, txid, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'paper', 'TESTFIXTURECLIENT', 100000000, 3, 'detected' from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect_error('a signed-in user cannot rewrite their own deposit',
  $q$update public.deposits set status = 'credited' where txid = 'TESTFIXTURETXBT1'; select 'updated'$q$,
  'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect_error('a signed-in user cannot credit their own deposit',
  $q$select public.credit_deposit((select id from public.deposits limit 1))$q$,
  'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect_error('a signed-in user cannot record a deposit',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREUSERREC', 100000000)$q$,
  'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select public.d_expect('service_role sees every deposit',
  $q$select count(*)::text from public.deposits$q$, '5', 'service_role');
select public.d_expect('service_role sees every address',
  $q$select count(*)::text from public.deposit_addresses$q$, '2', 'service_role');

select public.d_expect('no new function is executable by anon or PUBLIC',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('assert_deposits_enabled','register_deposit_network','register_deposit_address','record_deposit','set_deposit_confirmations','fail_deposit','credit_deposit')
           and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))$q$, '0');
select public.d_expect('all seven service_role entry points exist and are executable by service_role',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('assert_deposits_enabled','register_deposit_network','register_deposit_address','record_deposit','set_deposit_confirmations','fail_deposit','credit_deposit')
           and has_function_privilege('service_role', p.oid, 'EXECUTE')$q$, '7');
select public.d_expect('no view exposes deposit data',
  $q$select count(*)::text from pg_views where schemaname = 'public' and (definition ilike '%deposit%' or viewname ilike '%deposit%')$q$, '0');
select public.d_expect('the deposit tables are not in a publication (no realtime leak)',
  $q$select count(*)::text from pg_publication_tables where schemaname = 'public' and tablename in ('deposits','deposit_addresses','deposit_networks')$q$, '0');

\echo '=== D6. LIVE_DEPOSITS_ENABLED gate behaviour'
select public.d_expect_error('a live deposit row is refused while the exchange is in paper mode',
  $q$insert into public.deposits (user_id, asset_id, network, environment, txid, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'live', 'TESTFIXTURELIVE1', 100000000, 3, 'detected' from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'live row rejected');
select public.d_run('open the live switch as an operator would (mode=live, live_trading_enabled=true, deposits_enabled=false)',
  $q$update public.app_settings set mode = 'live', live_trading_enabled = true, live_enabled_at = now(), deposits_enabled = false$q$);
select public.d_run('register the network in the live environment',
  $q$select public.register_deposit_network('BTC', 'bitcoin', 3, 0, false, 50000000, false)$q$);
select public.d_expect_error('with deposits_enabled = false a live deposit is refused by the flag',
  $q$insert into public.deposits (user_id, asset_id, network, environment, txid, amount_units, required_confirmations, status)
     select '11111111-1111-1111-1111-111111111111', a.id, 'bitcoin', 'live', 'TESTFIXTURELIVE2', 100000000, 3, 'detected' from public.assets a where a.symbol = 'BTC';
     select 'inserted'$q$, 'deposits is not enabled');
select public.d_run('flip deposits_enabled on', $q$update public.app_settings set deposits_enabled = true$q$);
select public.d_expect('with the flag on, the live row is accepted (so the refusal above was the flag, not a syntax artefact)',
  $q$select count(*)::text from public.deposits where environment = 'live'$q$, '1');
select public.d_run('close the live switch again and remove the live probe rows',
  $q$delete from public.deposits where environment = 'live';
     delete from public.deposit_networks where environment = 'live';
     update public.app_settings set mode = 'paper', live_trading_enabled = false, live_enabled_at = null, deposits_enabled = false$q$);
select public.d_expect('the switch is back where it started (paper, all live flags off)',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/' || (live_enabled_at is null)::text from public.app_settings$q$,
  'paper/false/false/true');
select public.d_expect('no live deposit row survived the probe',
  $q$select count(*)::text from public.deposits where environment = 'live'$q$, '0');
select public.d_run('paper-mode operator path still works while deposits_enabled = false (the flag gates the live path)',
  $q$select public.record_deposit('11111111-1111-1111-1111-111111111111', 'BTC', 'bitcoin', 'TESTFIXTUREPAPER1', 100000000, -1, null, null, 0)$q$);
select public.d_expect('... recorded as a paper deposit', $q$select environment || '/' || status from public.deposits where txid = 'TESTFIXTUREPAPER1'$q$, 'paper/detected');

\echo '=== SUMMARY'
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from public.d_res;
select count(*) filter (where not ok) as failures from public.d_res;
