-- ============================================================================
-- exchange_separation_audit.sql — Stage 5: paper/live separation audit
-- ============================================================================
-- Purpose: for EVERY user-reachable money/state path, prove the mode separation
-- from BOTH directions, and prove the three gates added by migration
-- 20261005100190 (assert_trading_enabled / record_provider_balance /
-- run_reconciliation) in BOTH directions.
--
-- This suite does NOT re-verify what the other ten suites already prove
-- (state machines, fee math, RLS, operator permissions, idempotency). It asserts
-- exactly one property per path: which environment it may touch, and what happens
-- when you call it from the other one.
--
--   S0  fixtures (synthetic users + operator), baseline: paper mode, every LIVE_*
--       flag false, live_enabled_at NULL, paper switches on, no maintenance
--   S1  PAPER MODE — every paper path is ALLOWED (the controls: a refusal in S2/S3
--       must not be attributable to a broken fixture)
--   S2  PAPER MODE — every live/adapter path is REFUSED, including the two NEW
--       gates (live provider-balance intake, live reconciliation run)
--   S3  LIVE MODE — every paper path is REFUSED, the live/adapter paths are no
--       longer refused by the mode gate, and the two NEW gates accept a live
--       report/run
--   S4  LIVE MODE — the NEW trading guard: mode='live' + live_trading_enabled but
--       live_enabled_at IS NULL must refuse to trade (injection: the table CHECK is
--       dropped inside one DO block and restored by that block)
--   S5  REVERTED — app_settings identical to the S0 snapshot, zero live money rows,
--       and the ledger invariants still hold
--   S6  STATIC separation matrix — every audited function's prosrc contains the
--       gate the matrix in SCHEMA.md says it contains (and the release paths do
--       NOT read the paper switch; the non-money paths read no mode gate at all)
--
-- Cross-environment probes run through the REAL public entry points
-- (place_order, cancel_order, record_deposit, credit_deposit,
-- record_withdrawal_request, approve_withdrawal, submit_kyc,
-- record_provider_*, run_reconciliation), never through a direct table write,
-- except where the probe is explicitly about the table-level trigger.
--
-- NO FAKE MONEY. Every fixture balance comes from the seeded PAPER_FAUCET system
-- account through a balanced `paper_funding` ledger transaction, exactly like the
-- other suites. NO LIVE MONEY IS CREATED ANYWHERE IN THIS SUITE: the live-mode
-- window proves the gates open by watching the refusal MOVE PAST the mode gate
-- (to the next honest error), not by inventing live balances. The two live rows
-- this suite does leave behind are a provider report and a reconciliation run,
-- both created through their real entry points with source 'stage5-separation-probe'
-- and both labelled as such.
--
-- Every refusal is caught in-process (NOTICE PASS/FAIL). This suite produces NO
-- bare psql ERROR line, so the runner expects exactly 0 for it.
--
-- Runs LAST in the core database (it flips app_settings.mode to live and back, so
-- it must not overlap another suite) and is NOT idempotent: use a freshly migrated
-- database.
-- ============================================================================
\set ON_ERROR_STOP 0

drop table if exists public.s_res;
drop table if exists public.s_op;
drop table if exists public.s_fix;
drop table if exists public.s_settings_snapshot;
create table public.s_res (label text, ok boolean);
create table public.s_op (username text primary key, id uuid);
create table public.s_fix (name text primary key, val text);
create table public.s_settings_snapshot as
select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
       paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode,
       live_enabled_at is null as live_at_null
  from public.app_settings;

-- ===========================================================================
-- helpers (same assertion style as the other exchange suites)
-- ===========================================================================
create or replace function public.s_expect(p_label text, p_sql text, p_expected text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    execute p_sql into v_actual;
    if v_actual is not distinct from p_expected then
      raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
      insert into public.s_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.s_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.s_res(label, ok) values (p_label, false);
  end;
end;
$fn$;

create or replace function public.s_expect_error(p_label text, p_sql text, p_fragment text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.s_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.s_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.s_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
end;
$fn$;

-- the refusal must have MOVED PAST the mode gate: used in the live window to show
-- the adapter path is open without inventing a live deposit/withdrawal/submission
create or replace function public.s_expect_error_ne(p_label text, p_sql text, p_fragment text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.s_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'FAIL  % is STILL blocked by the mode gate: %', p_label, sqlerrm;
      insert into public.s_res(label, ok) values (p_label || ' (still mode-gated)', false);
    else
      raise notice 'PASS  % past the mode gate [%] %', p_label, sqlstate, sqlerrm;
      insert into public.s_res(label, ok) values (p_label, true);
    end if;
  end;
end;
$fn$;

create or replace function public.s_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
begin
  execute p_sql;
  raise notice 'PASS  (ran) %', p_label;
  insert into public.s_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.s_res(label, ok) values (p_label, false);
end;
$fn$;

-- balanced paper funding from the seeded PAPER_FAUCET account (never out of thin air)
create or replace function public.s_fund(p_user uuid, p_symbol text, p_amount numeric)
returns void language plpgsql as $fn$
declare
  v_asset uuid; v_faucet uuid; v_account uuid; v_tx uuid;
begin
  select id into v_asset from public.assets where symbol = p_symbol;
  v_faucet  := public.system_account_id('PAPER_FAUCET', v_asset, 'paper');
  v_account := public.ensure_user_account(p_user, v_asset, 'available', 'paper');
  insert into public.ledger_transactions (type, environment, reference_type, reference_id, description)
  values ('paper_funding', 'paper', 'user', p_user,
          format('stage5 separation probe funding %s %s', p_amount, p_symbol))
  returning id into v_tx;
  perform public.post_entry(v_tx, v_faucet,  -p_amount, 'stage5 separation probe funding');
  perform public.post_entry(v_tx, v_account,  p_amount, 'stage5 separation probe funding');
end;
$fn$;

-- does a function's body contain a given gate call? (the static matrix probe)
create or replace function public.s_gate(p_name text, p_needle text)
returns text language sql stable as $fn$
  select case when coalesce((select prosrc from pg_proc p
                               join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname = 'public' and p.proname = p_name
                              limit 1), '') like '%' || p_needle || '%'
              then 'yes' else 'no' end
$fn$;

create or replace function public.s_mode() returns text language sql stable as $fn$
  select mode from public.app_settings
$fn$;

create or replace function public.s_op_id(p_username text) returns uuid language sql stable as $fn$
  select id from public.s_op where username = p_username
$fn$;

-- ===========================================================================
\echo '=== S0. fixtures + baseline: the exchange is paper-only, every LIVE_* flag off'
-- ===========================================================================
select public.s_run('S0 create two synthetic identities and a superadmin operator',
  $q$insert into auth.users (id, email) values
       ('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 'separation-u1@example.test'),
       ('eeeeeeee-eeee-eeee-eeee-eeeeeeee0002', 'separation-op@example.test');
     insert into public.admin_users (username, password_hash, operator_role, auth_user_id, display_name)
       values ('s_super', 'fixture', 'superadmin', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0002',
               'separation fixture superadmin');
     insert into public.s_op (username, id) select username, id from public.admin_users where username = 's_super'$q$);

select public.s_expect('S0 the fixture user and operator exist exactly once',
  $q$select (select count(*) from auth.users where id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001')::text
        || '/' || (select count(*) from public.s_op)::text$q$, '1/1');

select public.s_expect('S0 baseline mode is paper', $q$select public.s_mode()$q$, 'paper');
select public.s_expect('S0 baseline: paper trading on, live trading off, live_enabled_at NULL',
  $q$select paper_trading_enabled::text || '/' || live_trading_enabled::text || '/' || (live_enabled_at is null)::text
       from public.app_settings$q$, 'true/false/true');
select public.s_expect('S0 baseline: live deposits and withdrawals off, both paper switches on',
  $q$select deposits_enabled::text || '/' || withdrawals_enabled::text || '/' ||
            paper_deposits_enabled::text || '/' || paper_withdrawals_enabled::text
       from public.app_settings$q$, 'false/false/true/true');
select public.s_expect('S0 baseline: no maintenance mode', $q$select (not public.maintenance_mode())::text$q$, 'true');

-- ===========================================================================
\echo '=== S1. PAPER MODE: every paper path is allowed (the controls)'
-- ===========================================================================
select public.s_run('S1 fund the synthetic customer from PAPER_FAUCET (balanced)',
  $q$select public.s_fund('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 'BTC',  100000000);
     select public.s_fund('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 'USDT', 200000000);
     select public.s_fund('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 'SOL',  1000000000)$q$);

-- a market of its own, so the trading probes cannot cross a resting order left by an
-- earlier suite (a cross would test settlement, which the matching suite already covers)
select public.s_run('S1 open a scratch PAPER market SOL/BTC to trade on',
  $q$select public.admin_upsert_market('SOL/BTC', 'SOL', 'BTC', 8::smallint, 1::numeric, 1::numeric,
                                       2, 5, 'trading', true, 'paper', public.s_op_id('s_super'))$q$);

select public.s_run('S1 place a paper sell order through place_order',
  $q$insert into public.s_fix (name, val)
     select 'order1', public.place_order('SOL/BTC', 'sell', 'limit', 1000000, 200000,
                                          'gtc', 'stage5-separation-order-1',
                                          'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001') ->> 'order_id'$q$);

select public.s_expect('S1 TRADING: place_order writes an order in the PAPER environment',
  $q$select environment from public.orders
      where id = (select val::uuid from public.s_fix where name = 'order1')$q$, 'paper');

select public.s_expect('S1 TRADING: cancel_order is allowed in paper mode (status canceled)',
  $q$select public.cancel_order((select val::uuid from public.s_fix where name = 'order1'),
                                'stage5 separation probe', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001') ->> 'status'$q$,
  'canceled');

select public.s_run('S1 DEPOSITS: record a paper deposit (paper_operator path)',
  $q$insert into public.s_fix (name, val)
     select 'dep1', public.record_deposit('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 'BTC', 'bitcoin',
                                          'SEPARATIONPROBETX1', 100000000, -1, 'SEPARATIONPROBEADDR1')::text$q$);

select public.s_expect('S1 DEPOSITS: the paper deposit starts pending',
  $q$select status from public.deposits where id = (select val::uuid from public.s_fix where name = 'dep1')$q$,
  'pending');

select public.s_expect('S1 DEPOSITS: set_deposit_confirmations reaches the network policy',
  $q$select public.set_deposit_confirmations((select val::uuid from public.s_fix where name = 'dep1'), 3)$q$,
  'confirmed');

select public.s_expect('S1 DEPOSITS: credit_deposit credits the paper deposit',
  $q$select (public.credit_deposit((select val::uuid from public.s_fix where name = 'dep1')) is not null)::text$q$,
  'true');

select public.s_expect('S1 DEPOSITS: the paper deposit is now credited (credit is data, not a status)',
  $q$select (credited_ledger_transaction_id is not null)::text from public.deposits
      where id = (select val::uuid from public.s_fix where name = 'dep1')$q$,
  'true');

select public.s_run('S1 WITHDRAWALS: record a paper withdrawal request (paper_operator path)',
  $q$insert into public.s_fix (name, val)
     select 'wd1', public.record_withdrawal_request('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 'BTC', 'bitcoin',
                                                    'SEPARATIONPROBEADDR2', 1000000)::text$q$);

select public.s_expect('S1 WITHDRAWALS: approve_withdrawal is allowed in paper mode',
  $q$select public.approve_withdrawal((select val::uuid from public.s_fix where name = 'wd1'))$q$, 'approved');

select public.s_run('S1 KYC: submit_kyc (paper_operator path) is allowed in paper mode',
  $q$insert into public.s_fix (name, val)
     select 'kyc1', public.submit_kyc('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 1, '{}'::jsonb)::text$q$);

select public.s_expect('S1 KYC: the paper submission exists with source paper_operator',
  $q$select source from public.kyc_submissions where id = (select val::uuid from public.s_fix where name = 'kyc1')$q$,
  'paper_operator');

select public.s_expect('S1 RECONCILIATION: a PAPER run is allowed in paper mode',
  $q$select (public.run_reconciliation('paper', public.s_op_id('s_super')) is not null)::text$q$, 'true');

select public.s_expect('S1 PROVIDER INTAKE: a PAPER provider report is allowed in paper mode',
  $q$select (public.record_provider_balance('BTC', 'bitcoin', 0, 'stage5-separation-probe',
                                            'paper', now(),
                                            '{"note":"stage 5 separation probe: paper report"}'::jsonb) is not null)::text$q$,
  'true');

-- ===========================================================================
\echo '=== S2. PAPER MODE: every live / adapter path is refused'
-- ===========================================================================
select public.s_expect_error('S2 DEPOSITS: the provider adapter deposit path is refused in paper mode',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC",
        "user_id":"eeeeeeee-eeee-eeee-eeee-eeeeeeee0001","txid":"SEPARATIONPROBETX2",
        "amount_units":100000000}'::jsonb)$q$,
  'provider adapter path is live-only');

select public.s_expect_error('S2 DEPOSITS: the operator (paper) deposit path cannot be forged as an adapter event',
  $q$select public._deposit_ingest('provider_adapter', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001',
        'BTC', 'bitcoin', 'SEPARATIONPROBETX3', 100000000, -1, null, null, 0, '{}'::jsonb)$q$,
  'provider adapter path is live-only');

select public.s_expect_error('S2 WITHDRAWALS: the provider adapter withdrawal path is refused in paper mode',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC",
        "user_id":"eeeeeeee-eeee-eeee-eeee-eeeeeeee0001",
        "destination_address":"SEPARATIONPROBEADDR3","amount_units":1000000}'::jsonb)$q$,
  'provider adapter path is live-only');

select public.s_expect_error('S2 KYC: the provider adapter KYC path is refused in paper mode',
  $q$select public.record_provider_kyc_event('{"event_type":"approve",
        "user_id":"eeeeeeee-eeee-eeee-eeee-eeeeeeee0001",
        "submission_reference":"stage5-separation-ref-1"}'::jsonb)$q$,
  'provider adapter KYC path is live-only');

select public.s_expect_error('S2 RECONCILIATION [NEW]: a LIVE provider report is refused in paper mode',
  $q$select public.record_provider_balance('BTC', 'bitcoin', 5, 'stage5-separation-probe', 'live')$q$,
  'refusing a live report in paper mode');

select public.s_expect_error('S2 RECONCILIATION [NEW]: a LIVE reconciliation run is refused in paper mode',
  $q$select public.run_reconciliation('live', public.s_op_id('s_super'))$q$,
  'refusing a live run in paper mode');

select public.s_expect_error('S2 TRADING: the environment trigger refuses a live order row in paper mode',
  $q$insert into public.orders (user_id, market_id, side, type, time_in_force, qty_units, price_units,
                                status, environment)
     select 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', m.id, 'sell', 'limit', 'gtc', 1, 1, 'open', 'live'
       from public.markets m where m.environment = 'paper' limit 1$q$,
  'live row rejected');

select public.s_expect_error('S2 TRADING: the environment trigger refuses a live account in paper mode',
  $q$insert into public.accounts (user_id, asset_id, account_type, kind, code, environment)
     select 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', a.id, 'user', 'available', 'AVAILABLE', 'live'
       from public.assets a where a.symbol = 'BTC'$q$,
  'live row rejected');

select public.s_expect('S2 no live money row exists anywhere while the exchange is paper',
  $q$select ((select count(*) from public.orders where environment = 'live')
           + (select count(*) from public.trades where environment = 'live')
           + (select count(*) from public.deposits where environment = 'live')
           + (select count(*) from public.withdrawal_requests where environment = 'live')
           + (select count(*) from public.accounts where environment = 'live')
           + (select count(*) from public.ledger_transactions where environment = 'live'))::text$q$,
  '0');

-- ===========================================================================
\echo '=== S3. LIVE MODE: paper paths refused, live/adapter paths open'
-- ===========================================================================
select public.s_run('S3 flip to live mode (live_trading_enabled + live_enabled_at, the only legal way)',
  $q$update public.app_settings
        set live_trading_enabled = true, live_enabled_at = now(), mode = 'live'$q$);

select public.s_expect('S3 the exchange is now live', $q$select public.s_mode()$q$, 'live');

select public.s_expect('S3 TRADING: assert_trading_enabled returns live (mode + flag + timestamp all set)',
  $q$select public.assert_trading_enabled()$q$, 'live');

select public.s_expect_error('S3 TRADING: place_order cannot create a paper order in live mode (no live market)',
  $q$select public.place_order('SOL/BTC', 'sell', 'limit', 1000000, 200000, 'gtc',
                               'stage5-separation-order-2', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001')$q$,
  'unknown market');

select public.s_expect('S3 TRADING: that attempt wrote no paper order (the engine runs in the live environment only)',
  $q$select count(*)::text from public.orders
      where client_order_id = 'stage5-separation-order-2' and environment = 'paper'$q$, '0');

select public.s_expect_error('S3 DEPOSITS: the operator (paper) deposit path is refused in live mode',
  $q$select public.record_deposit('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 'BTC', 'bitcoin',
                                  'SEPARATIONPROBETX4', 100000000)$q$,
  'operator/test deposit path is paper-only');

select public.s_expect_error('S3 DEPOSITS: the LIVE adapter path is still gated by deposits_enabled',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC",
        "user_id":"eeeeeeee-eeee-eeee-eeee-eeeeeeee0001","txid":"SEPARATIONPROBETX5",
        "amount_units":100000000}'::jsonb)$q$,
  'live deposits are disabled');

select public.s_run('S3 open the live deposit flag (scratch only, reverted in S5)',
  $q$update public.app_settings set deposits_enabled = true$q$);

select public.s_expect_error_ne('S3 DEPOSITS: with mode=live and deposits_enabled the adapter path is past the mode gate',
  $q$select public.record_provider_deposit('{"network":"bitcoin","asset_symbol":"BTC",
        "user_id":"eeeeeeee-eeee-eeee-eeee-eeeeeeee0001","txid":"SEPARATIONPROBETX6",
        "amount_units":100000000}'::jsonb)$q$,
  'live-only');

select public.s_run('S3 close the live deposit flag again',
  $q$update public.app_settings set deposits_enabled = false$q$);

select public.s_expect_error('S3 WITHDRAWALS: the operator (paper) withdrawal path is refused in live mode',
  $q$select public.record_withdrawal_request('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 'BTC', 'bitcoin',
                                             'SEPARATIONPROBEADDR4', 1000000)$q$,
  'operator/test withdrawal path is paper-only');

select public.s_expect_error('S3 WITHDRAWALS: the LIVE adapter path is still gated by withdrawals_enabled',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC",
        "user_id":"eeeeeeee-eeee-eeee-eeee-eeeeeeee0001",
        "destination_address":"SEPARATIONPROBEADDR5","amount_units":1000000}'::jsonb)$q$,
  'live withdrawals are disabled');

select public.s_run('S3 open the live withdrawal flag (scratch only, reverted in S5)',
  $q$update public.app_settings set withdrawals_enabled = true$q$);

select public.s_expect_error_ne('S3 WITHDRAWALS: with mode=live and withdrawals_enabled the adapter path is past the mode gate',
  $q$select public.record_provider_withdrawal('{"network":"bitcoin","asset_symbol":"BTC",
        "user_id":"eeeeeeee-eeee-eeee-eeee-eeeeeeee0001",
        "destination_address":"SEPARATIONPROBEADDR6","amount_units":1000000}'::jsonb)$q$,
  'live-only');

select public.s_run('S3 close the live withdrawal flag again',
  $q$update public.app_settings set withdrawals_enabled = false$q$);

select public.s_expect_error('S3 KYC: the operator (paper) KYC path is refused in live mode',
  $q$select public.submit_kyc('eeeeeeee-eeee-eeee-eeee-eeeeeeee0001', 1, '{}'::jsonb)$q$,
  'KYC path is refused while the exchange is live');

select public.s_expect_error_ne('S3 KYC: the provider adapter KYC path is past the mode gate in live mode',
  $q$select public.record_provider_kyc_event('{"event_type":"approve",
        "user_id":"eeeeeeee-eeee-eeee-eeee-eeeeeeee0001",
        "submission_reference":"stage5-separation-ref-2"}'::jsonb)$q$,
  'live-only');

select public.s_expect('S3 RECONCILIATION [NEW]: a LIVE provider report is accepted in live mode',
  $q$select (public.record_provider_balance('BTC', 'bitcoin', 0, 'stage5-separation-probe',
                                            'live', now(),
                                            '{"note":"stage 5 separation probe: live report, no live money exists"}'::jsonb) is not null)::text$q$,
  'true');

select public.s_expect('S3 RECONCILIATION [NEW]: a LIVE reconciliation run is accepted in live mode',
  $q$select (public.run_reconciliation('live', public.s_op_id('s_super')) is not null)::text$q$, 'true');

select public.s_expect('S3 RECONCILIATION: the live run compared the live environment only (honest empty book)',
  $q$select count(*)::text from public.reconciliation_results r
        join public.reconciliation_runs u on u.id = r.run_id
      where u.environment = 'live' and r.environment = 'live'$q$,
  (select count(*)::text from public.assets where true));

-- ===========================================================================
\echo '=== S4. LIVE MODE: the NEW trading guard — live_enabled_at is required'
-- ===========================================================================
-- The table CHECK app_settings_live_gate_check already forbids mode='live' without
-- live_enabled_at, so the only way to reach this state is to drop it. The whole
-- injection happens inside ONE DO block: if anything raises, the block rolls back
-- and the constraint is restored automatically.
do $fn$
begin
  if (select live_enabled_at is null from public.app_settings) then
    raise exception 'S4 precondition: live_enabled_at should be set before the injection';
  end if;

  alter table public.app_settings drop constraint app_settings_live_gate_check;
  update public.app_settings set live_enabled_at = null;

  perform public.s_expect('S4 pre-injection state is exactly the one the guard exists for (mode live, flag on, no timestamp)',
    $q$select mode || '/' || live_trading_enabled::text || '/' || (live_enabled_at is null)::text
         from public.app_settings$q$, 'live/true/true');

  perform public.s_expect_error('S4 TRADING [NEW]: place_order refuses to trade live with live_enabled_at NULL',
    $q$select public.place_order('BTC/USDT', 'sell', 'limit', 100000, 6000000000000, 'gtc',
                                 'stage5-separation-order-3', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001')$q$,
    'live_enabled_at is NULL');

  perform public.s_expect_error('S4 TRADING [NEW]: assert_trading_enabled itself refuses that state',
    $q$select public.assert_trading_enabled()$q$,
    'live_enabled_at is NULL');

  update public.app_settings set live_enabled_at = now();

  alter table public.app_settings
    add constraint app_settings_live_gate_check
    check (mode <> 'live' OR (live_trading_enabled AND live_enabled_at IS NOT NULL));

  perform public.s_expect('S4 TRADING [NEW]: with the timestamp restored, assert_trading_enabled returns live again',
    $q$select public.assert_trading_enabled()$q$, 'live');
end;
$fn$;

select public.s_expect('S4 the live-gate constraint is back and enforced (mode=live with a NULL timestamp is refused again)',
  $q$select (select count(*) from pg_constraint
              where conrelid = 'public.app_settings'::regclass
                and conname = 'app_settings_live_gate_check')::text$q$, '1');

select public.s_expect_error('S4 the constraint really is enforced (not just present)',
  $q$update public.app_settings set live_enabled_at = null returning 1$q$,
  'app_settings_live_gate_check');

-- ===========================================================================
\echo '=== S5. REVERTED: settings identical to the snapshot, no live money, invariants hold'
-- ===========================================================================
select public.s_run('S5 revert to paper mode and clear every live flag',
  $q$update public.app_settings
        set mode = 'paper', live_trading_enabled = false, live_enabled_at = null,
            deposits_enabled = false, withdrawals_enabled = false,
            paper_trading_enabled = true, paper_deposits_enabled = true,
            paper_withdrawals_enabled = true, maintenance_mode = false$q$);

select public.s_expect('S5 app_settings is byte-identical to the S0 snapshot',
  $q$select count(*)::text from (
       select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
              paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode,
              live_enabled_at is null as live_at_null
         from public.app_settings
       except
       select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
              paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode,
              live_at_null
         from public.s_settings_snapshot
     ) d$q$, '0');

select public.s_expect('S5 the suite created NO live money (orders/trades/deposits/withdrawals/accounts/ledger)',
  $q$select ((select count(*) from public.orders where environment = 'live')
           + (select count(*) from public.trades where environment = 'live')
           + (select count(*) from public.deposits where environment = 'live')
           + (select count(*) from public.withdrawal_requests where environment = 'live')
           + (select count(*) from public.accounts where environment = 'live')
           + (select count(*) from public.ledger_transactions where environment = 'live'))::text$q$,
  '0');

select public.s_expect('S5 every ledger transaction still sums to zero',
  $q$select count(*)::text from (
       select t.id from public.ledger_transactions t
         join public.ledger_entries e on e.transaction_id = t.id
        group by t.id having sum(e.amount_units) <> 0) b$q$, '0');

select public.s_expect('S5 every cached balance still equals its ledger entries',
  $q$select count(*)::text from (
       select acc.id
         from public.accounts acc
         left join public.balances b on b.account_id = acc.id
         left join (select account_id, sum(amount_units) u from public.ledger_entries group by account_id) e
                on e.account_id = acc.id
        where coalesce(b.available_units, 0) + coalesce(b.locked_units, 0)
              is distinct from coalesce(e.u, 0)) d$q$, '0');

select public.s_expect('S5 paper trading works again after the revert (the controls are not inert)',
  $q$select (public.place_order('SOL/BTC', 'sell', 'limit', 1000000, 200000, 'gtc',
                                'stage5-separation-order-4', 'eeeeeeee-eeee-eeee-eeee-eeeeeeee0001')
             ->> 'environment')$q$, 'paper');

-- ===========================================================================
\echo '=== S6. STATIC separation matrix (pg_proc.prosrc)'
-- ===========================================================================
select public.s_expect('S6 place_order is gated by assert_trading_enabled',
  $q$select public.s_gate('place_order', 'assert_trading_enabled')$q$, 'yes');
select public.s_expect('S6 place_order is gated by maintenance + account restrictions',
  $q$select public.s_gate('place_order', 'assert_not_in_maintenance') || '/' ||
            public.s_gate('place_order', 'assert_account_not_restricted')$q$, 'yes/yes');
select public.s_expect('S6 cancel_order is gated by assert_trading_enabled',
  $q$select public.s_gate('cancel_order', 'assert_trading_enabled')$q$, 'yes');
select public.s_expect('S6 cancel_order deliberately does NOT read maintenance/restrictions (release must stay available)',
  $q$select public.s_gate('cancel_order', 'assert_not_in_maintenance') || '/' ||
            public.s_gate('cancel_order', 'assert_account_not_restricted')$q$, 'no/no');
select public.s_expect('S6 settle_fill re-asserts the trading gate',
  $q$select public.s_gate('settle_fill', 'assert_trading_enabled')$q$, 'yes');

select public.s_expect('S6 _deposit_ingest reads the live gate, the paper switch, maintenance and restrictions',
  $q$select public.s_gate('_deposit_ingest', 'assert_deposits_enabled') || '/' ||
            public.s_gate('_deposit_ingest', 'assert_paper_deposits_enabled') || '/' ||
            public.s_gate('_deposit_ingest', 'assert_not_in_maintenance') || '/' ||
            public.s_gate('_deposit_ingest', 'assert_account_not_restricted')$q$, 'yes/yes/yes/yes');
select public.s_expect('S6 _deposit_ingest pairs source with mode (paper_operator refused outside paper)',
  $q$select public.s_gate('_deposit_ingest', 'operator/test deposit path is paper-only')$q$, 'yes');
select public.s_expect('S6 credit_deposit reads the live gate and the paper switch',
  $q$select public.s_gate('credit_deposit', 'assert_deposits_enabled') || '/' ||
            public.s_gate('credit_deposit', 'assert_paper_deposits_enabled')$q$, 'yes/yes');

select public.s_expect('S6 _withdrawal_ingest reads the live gate, the paper switch, maintenance and restrictions',
  $q$select public.s_gate('_withdrawal_ingest', 'assert_withdrawals_enabled') || '/' ||
            public.s_gate('_withdrawal_ingest', 'assert_paper_withdrawals_enabled') || '/' ||
            public.s_gate('_withdrawal_ingest', 'assert_not_in_maintenance') || '/' ||
            public.s_gate('_withdrawal_ingest', 'assert_account_not_restricted')$q$, 'yes/yes/yes/yes');
select public.s_expect('S6 approve_withdrawal reads the live gate and the paper switch',
  $q$select public.s_gate('approve_withdrawal', 'assert_withdrawals_enabled') || '/' ||
            public.s_gate('approve_withdrawal', 'assert_paper_withdrawals_enabled')$q$, 'yes/yes');
select public.s_expect('S6 complete_withdrawal reads the live gate and the paper switch',
  $q$select public.s_gate('complete_withdrawal', 'assert_withdrawals_enabled') || '/' ||
            public.s_gate('complete_withdrawal', 'assert_paper_withdrawals_enabled')$q$, 'yes/yes');
select public.s_expect('S6 the release paths read the live gate but deliberately NOT the paper switch',
  $q$select public.s_gate('reject_withdrawal', 'assert_withdrawals_enabled') || '/' ||
            public.s_gate('reject_withdrawal', 'assert_paper_withdrawals_enabled') || '/' ||
            public.s_gate('fail_withdrawal', 'assert_withdrawals_enabled') || '/' ||
            public.s_gate('fail_withdrawal', 'assert_paper_withdrawals_enabled')$q$, 'yes/no/yes/no');

select public.s_expect('S6 every KYC decision path reads assert_kyc_path',
  $q$select public.s_gate('submit_kyc', 'assert_kyc_path') || '/' ||
            public.s_gate('record_provider_kyc_event', 'assert_kyc_path') || '/' ||
            public.s_gate('approve_kyc', 'assert_kyc_path') || '/' ||
            public.s_gate('reject_kyc', 'assert_kyc_path') || '/' ||
            public.s_gate('set_kyc_under_review', 'assert_kyc_path')$q$, 'yes/yes/yes/yes/yes');

select public.s_expect('S6 [NEW] assert_trading_enabled now reads live_enabled_at',
  $q$select public.s_gate('assert_trading_enabled', 'live_enabled_at')$q$, 'yes');
select public.s_expect('S6 [NEW] record_provider_balance refuses a live report in paper mode',
  $q$select public.s_gate('record_provider_balance', 'a live provider balance may only be recorded while the exchange is live')$q$, 'yes');
select public.s_expect('S6 [NEW] run_reconciliation refuses a live run in paper mode',
  $q$select public.s_gate('run_reconciliation', 'a live reconciliation run may only happen while the exchange is live')$q$, 'yes');

select public.s_expect('S6 NON-MONEY paths (notifications, announcements, support, health) read no mode gate',
  $q$select public.s_gate('admin_send_notification', 'assert_trading_enabled') || '/' ||
            public.s_gate('admin_send_notification', 'assert_deposits_enabled') || '/' ||
            public.s_gate('admin_create_announcement', 'assert_withdrawals_enabled') || '/' ||
            public.s_gate('user_mark_notification_read', 'app_mode') || '/' ||
            public.s_gate('admin_support_reply', 'app_mode')$q$, 'no/no/no/no/no');

select public.s_expect('S6 the environment-gate trigger covers every money table',
  $q$select count(*)::text from pg_trigger t
        join pg_class c on c.oid = t.tgrelid
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and not t.tgisinternal
         and t.tgname in ('accounts_environment_gate','ledger_transactions_environment_gate',
                          'orders_environment_gate','trades_environment_gate',
                          'deposits_environment_gate','withdrawal_requests_environment_gate')$q$, '6');

-- ===========================================================================
\echo '=== SUMMARY'
-- ===========================================================================
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) as summary
  from public.s_res;
select label from public.s_res where not ok order by label;
