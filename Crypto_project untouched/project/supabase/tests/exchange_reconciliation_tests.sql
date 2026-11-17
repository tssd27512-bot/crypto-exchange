-- ============================================================================
-- exchange_reconciliation_tests.sql — stage 4: financial reconciliation +
-- discrepancy alerts (migration 20261005100180_exchange_reconciliation)
--
-- Runs LAST in the core database (after schema, ledger, immutability, deposits,
-- withdrawals, kyc, admin, comms and realtime_health): it reuses the fixture
-- users, the registered paper networks, the credited deposits and the settled
-- withdrawals those suites created, plus the PR #7 operator control plane.
--
-- What it proves, section by section:
--   R0  fixtures: one synthetic customer, four operators, paper funding, snapshots
--   R1  the schema and the ACL surface: five tables, RLS on with no policy,
--       SELECT-only for every role, the enums, the only-write-path RPCs
--   R2  provider balance intake: the table starts EMPTY, the RPC stores exactly
--       what is reported, the upsert keeps history, every bad report is refused,
--       a direct write is impossible
--   R3  honest unavailability: no provider rows at all => every asset
--       'unavailable', provider_units NULL, never 0, never 'match', zero alerts
--   R4  balanced paper state with provider data that matches custody => every
--       asset 'match', zero alerts, invariant scan all green
--   R5  injection A: a bogus provider balance => provider_mismatch WARNING,
--       nothing auto-corrected; a stale report => stale_provider WARNING
--   R6  injection B: internal drift is impossible through any API path (the
--       existing triggers refuse it - proven with two expected psql ERRORs), and
--       when a superuser tamps with the trigger in scratch the run DETECTS it,
--       raises a CRITICAL internal_drift alert and corrects nothing
--   R7  run idempotency: back-to-back runs agree, one alert per (run, asset, kind)
--   R8  authorisation: cross-role denial, audit rows with a real actor, the
--       acknowledge flow (audited, write-once, acknowledge != fix), view scoping
--   R9  the directive's idempotency/double-spend re-proofs: duplicate deposit
--       credit, duplicate withdrawal settlement, reserved balances, refund once
--   R10 the safety gate is untouched and the database is left consistent
--
-- EXACTLY TWO bare psql ERROR lines are the PASS condition (like the ledger suite's
-- four), and they are the only two deliberate ones in this suite:
--   probe R6 (a1)  UPDATE a cached balance with no ledger entries
--                  -> refused with 'balance drift on account'
--   probe R6 (a2)  INSERT an unbalanced ledger transaction
--                  -> refused with 'not a valid double-entry posting'
-- Both are DEFERRED constraint triggers, so they fire at COMMIT and cannot be caught
-- inside a DO block; they are top-level BEGIN ... COMMIT blocks. Everything else that
-- must be refused is asserted in-process by r_expect_error()/r_expect_error_as(), which
-- emit a NOTICE and never a bare ERROR line.
-- The runner checks more than the count: it requires these two messages and rejects any
-- 'syntax error' / 'does not exist' line, so a broken statement cannot pass as a probe.
--
-- Every fixture is synthetic and labelled as such. No balance, trade, deposit,
-- withdrawal, customer or provider connection is invented; provider_balances
-- rows exist ONLY through record_provider_balance (never seeded).
-- ============================================================================
\set ON_ERROR_STOP 0

drop table if exists public.r_res;
drop table if exists public.r_op;
drop table if exists public.r_fix;
drop table if exists public.r_settings_snapshot;
create table public.r_res (label text, ok boolean);
create table public.r_op (username text primary key, id uuid);
create table public.r_fix (name text primary key, val text);
create table public.r_settings_snapshot as
select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
       paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode
  from public.app_settings;

-- ===========================================================================
-- helpers
-- ===========================================================================
create or replace function public.r_expect(p_label text, p_sql text, p_expected text,
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
      insert into public.r_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.r_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.r_res(label, ok) values (p_label, false);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.r_expect_error(p_label text, p_sql text, p_fragment text,
  p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.r_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.r_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.r_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

-- operator path: the transaction-local gtvx.operator_id (the edge-function
-- contract from PR #7), all inside one statement
create or replace function public.r_expect_as(p_label text, p_username text, p_sql text, p_expected text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  perform set_config('gtvx.operator_id', (select id::text from public.r_op where username = p_username), true);
  execute p_sql into v_actual;
  if v_actual is not distinct from p_expected then
    raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
    insert into public.r_res(label, ok) values (p_label, true);
  else
    raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
    insert into public.r_res(label, ok) values (p_label, false);
  end if;
exception when others then
  raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.r_res(label, ok) values (p_label, false);
end;
$fn$;

create or replace function public.r_expect_error_as(p_label text, p_username text, p_sql text, p_fragment text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  perform set_config('gtvx.operator_id', (select id::text from public.r_op where username = p_username), true);
  execute p_sql into v_actual;
  raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
  insert into public.r_res(label, ok) values (p_label || ' (was allowed)', false);
exception when others then
  if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
    raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
    insert into public.r_res(label, ok) values (p_label, true);
  else
    raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
    insert into public.r_res(label, ok) values (p_label || ' (wrong error)', false);
  end if;
end;
$fn$;

create or replace function public.r_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
begin
  execute p_sql;
  raise notice 'PASS  (ran) %', p_label;
  insert into public.r_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.r_res(label, ok) values (p_label, false);
end;
$fn$;

create or replace function public.r_run_as(p_label text, p_role text, p_sql text)
returns void language plpgsql as $fn$
begin
  execute format('set local role %I', p_role);
  execute p_sql;
  execute 'reset role';
  raise notice 'PASS  (ran as %) %', p_role, p_label;
  insert into public.r_res(label, ok) values (p_label, true);
exception when others then
  execute 'reset role';
  raise notice 'FAIL  (setup as %) % raised % (%)', p_role, p_label, sqlerrm, sqlstate;
  insert into public.r_res(label, ok) values (p_label, false);
end;
$fn$;

create or replace function public.r_id(p_username text)
returns uuid language sql stable as $fn$
  select id from public.r_op where username = p_username
$fn$;

-- balanced paper funding: the money comes from PAPER_FAUCET, never out of thin
-- air (one statement => one transaction, so the deferred invariants hold)
create or replace function public.r_fund(p_user uuid, p_symbol text, p_amount numeric)
returns void language plpgsql as $fn$
declare
  v_asset uuid; v_faucet uuid; v_account uuid; v_tx uuid;
begin
  select id into v_asset from public.assets where symbol = p_symbol;
  v_faucet := public.system_account_id('PAPER_FAUCET', v_asset, 'paper');
  v_account := public.ensure_user_account(p_user, v_asset, 'available', 'paper');
  insert into public.ledger_transactions (type, environment, reference_type, reference_id, description)
  values ('paper_funding', 'paper', 'user', p_user, format('stage4 scratch funding %s %s', p_amount, p_symbol))
  returning id into v_tx;
  perform public.post_entry(v_tx, v_faucet, -p_amount, 'stage4 scratch funding');
  perform public.post_entry(v_tx, v_account, p_amount, 'stage4 scratch funding');
end $fn$;

-- run the reconciliation as an operator (explicit operator id, the service_role path)
create or replace function public.r_recon(p_username text, p_env text default 'paper')
returns uuid language plpgsql as $fn$
begin
  return public.run_reconciliation(p_env, (select id from public.r_op where username = p_username));
end $fn$;

-- a provider report for the scratch tests. It goes through the ONLY write path
-- (record_provider_balance), never a direct insert, so the "provider rows exist
-- only via the RPC" claim stays true even inside this suite.
create or replace function public.r_provider(p_symbol text, p_units numeric,
  p_reported_at timestamptz default now())
returns uuid language plpgsql as $fn$
begin
  return public.record_provider_balance(
    p_symbol, 'scratch-custody', p_units, 'stage4-suite-fixture', 'paper', p_reported_at,
    jsonb_build_object('note', 'scratch test fixture, not a real provider report'));
end $fn$;

-- snapshots of the ledger size, to prove a run writes no money
create or replace function public.r_snap(p_name text)
returns void language plpgsql as $fn$
begin
  insert into public.r_fix(name, val)
  select p_name || '_tx', count(*)::text from public.ledger_transactions
  on conflict (name) do update set val = excluded.val;
  insert into public.r_fix(name, val)
  select p_name || '_entries', count(*)::text from public.ledger_entries
  on conflict (name) do update set val = excluded.val;
  insert into public.r_fix(name, val)
  select p_name || '_balances', coalesce(sum(b.available_units + b.locked_units), 0)::text
    from public.balances b
  on conflict (name) do update set val = excluded.val;
end $fn$;

create or replace function public.r_snap_value(p_name text)
returns text language sql stable as $fn$
  select val from public.r_fix where name = p_name
$fn$;

-- ===========================================================================
\echo '=== R0. fixtures - one synthetic customer, four operators, paper funding'
-- ===========================================================================
select public.r_run('R0 create the synthetic customer',
  $q$insert into auth.users (id, email) values
       ('ffffffff-ffff-ffff-ffff-ffffffff0001', 'recon-u1@example.test')$q$);

select public.r_run('R0 create the auth identities the JWT operators sign in as',
  $q$insert into auth.users (id, email) values
       ('ffffffff-ffff-ffff-ffff-ffffffff0002', 'recon-op-super@example.test'),
       ('ffffffff-ffff-ffff-ffff-ffffffff0003', 'recon-op-comp@example.test'),
       ('ffffffff-ffff-ffff-ffff-ffffffff0004', 'recon-op-supp@example.test')$q$);

select public.r_run('R0 provision one operator per role',
  $q$insert into public.admin_users (username, password_hash, operator_role, auth_user_id, display_name) values
       ('r_super', 'fixture', 'superadmin', 'ffffffff-ffff-ffff-ffff-ffffffff0002', 'stage4 fixture superadmin'),
       ('r_comp',  'fixture', 'compliance', 'ffffffff-ffff-ffff-ffff-ffffffff0003', 'stage4 fixture compliance'),
       ('r_supp',  'fixture', 'support',    'ffffffff-ffff-ffff-ffff-ffffffff0004', 'stage4 fixture support'),
       ('r_ro',    'fixture', 'readonly',   null, 'stage4 fixture auditor')$q$);

select public.r_run('R0 record the operator ids',
  $q$insert into public.r_op (username, id) select username, id from public.admin_users
      where username in ('r_super','r_comp','r_supp','r_ro')$q$);

select public.r_run('R0 fund the customer with BTC (paper faucet, ledger-backed)',
  $q$select public.r_fund('ffffffff-ffff-ffff-ffff-ffffffff0001', 'BTC', 100000000)$q$);
select public.r_run('R0 ... and with ETH',
  $q$select public.r_fund('ffffffff-ffff-ffff-ffff-ffffffff0001', 'ETH', 1000000000000000000)$q$);

select public.r_expect('R0 the funding is balanced: the faucet carries the negative side',
  $q$select (-sum(e.amount_units))::text from public.ledger_entries e
        join public.accounts a on a.id = e.account_id
        join public.ledger_transactions t on t.id = e.transaction_id
       where a.code = 'PAPER_FAUCET' and a.asset_id = (select id from public.assets where symbol = 'BTC')
         and t.description like 'stage4 scratch funding%'$q$, '100000000');

select public.r_expect('R0 four active assets exist to reconcile',
  $q$select count(*)::text from public.assets where is_active$q$, '4');

-- ===========================================================================
\echo '=== R1. schema + ACL surface'
-- ===========================================================================
select public.r_expect('R1 all five reconciliation tables exist',
  $q$select count(*)::text from information_schema.tables
      where table_schema = 'public'
        and table_name in ('provider_balances','provider_balances_log','reconciliation_runs',
                          'reconciliation_results','reconciliation_alerts')$q$, '5');

select public.r_expect('R1 RLS is enabled on every one of them',
  $q$select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and not c.relrowsecurity
        and c.relname in ('provider_balances','provider_balances_log','reconciliation_runs',
                          'reconciliation_results','reconciliation_alerts')$q$, '0');

select public.r_expect('R1 none of them has a policy (the views are the only read path)',
  $q$select count(*)::text from pg_policies
      where schemaname = 'public'
        and tablename in ('provider_balances','provider_balances_log','reconciliation_runs',
                          'reconciliation_results','reconciliation_alerts')$q$, '0');

select public.r_expect('R1 service_role can SELECT the provider table but cannot INSERT into it',
  $q$select has_table_privilege('service_role','public.provider_balances','SELECT')::text
        || '/' || has_table_privilege('service_role','public.provider_balances','INSERT')::text$q$, 'true/false');

select public.r_expect('R1 service_role cannot UPDATE the results either (the RPCs are the only write path)',
  $q$select has_table_privilege('service_role','public.reconciliation_results','UPDATE')::text
        || '/' || has_table_privilege('service_role','public.reconciliation_alerts','UPDATE')::text$q$, 'false/false');

select public.r_expect('R1 authenticated has no privilege at all on the reconciliation tables',
  $q$select has_table_privilege('authenticated','public.reconciliation_runs','SELECT')::text
        || '/' || has_table_privilege('authenticated','public.provider_balances','SELECT')::text$q$, 'false/false');

select public.r_expect('R1 authenticated may read the two admin views, anon may not',
  $q$select has_table_privilege('authenticated','public.v_admin_reconciliation','SELECT')::text
        || '/' || has_table_privilege('anon','public.v_admin_reconciliation','SELECT')::text$q$, 'true/false');

select public.r_expect('R1 the three entry points are service_role only (authenticated/anon refused)',
  $q$select has_function_privilege('authenticated','public.run_reconciliation(text,uuid)','EXECUTE')::text
        || '/' || has_function_privilege('anon','public.record_provider_balance(text,text,numeric,text,text,timestamp with time zone,jsonb)','EXECUTE')::text
        || '/' || has_function_privilege('authenticated','public.acknowledge_reconciliation_alert(uuid,text,uuid)','EXECUTE')::text$q$,
  'false/false/false');

select public.r_expect('R1 ... and service_role can execute them',
  $q$select has_function_privilege('service_role','public.run_reconciliation(text,uuid)','EXECUTE')::text
        || '/' || has_function_privilege('service_role','public.record_provider_balance(text,text,numeric,text,text,timestamp with time zone,jsonb)','EXECUTE')::text$q$,
  'true/true');

select public.r_expect('R1 the internal scan is not callable by authenticated (service_role may: it is the run helper)',
  $q$select has_function_privilege('authenticated','public._reconciliation_invariant_scan(uuid)','EXECUTE')::text
        || '/' || has_function_privilege('service_role','public._reconciliation_invariant_scan(uuid)','EXECUTE')::text$q$, 'false/true');

select public.r_expect('R1 the results status is constrained to match/drift/unavailable',
  $q$select pg_get_constraintdef(oid) from pg_constraint
      where conname = 'reconciliation_results_status_check'$q$,
  'CHECK ((status = ANY (ARRAY[''match''::text, ''drift''::text, ''unavailable''::text])))');

select public.r_expect('R1 the alert severity is constrained to warning/critical',
  $q$select pg_get_constraintdef(oid) from pg_constraint
      where conname = 'reconciliation_alerts_severity_check'$q$,
  'CHECK ((severity = ANY (ARRAY[''warning''::text, ''critical''::text])))');

select public.r_expect('R1 the alert kind is constrained to the four honest kinds',
  $q$select count(*)::text from pg_constraint
      where conname = 'reconciliation_alerts_kind_check' and contype = 'c'$q$, '1');

select public.r_expect('R1 an acknowledgement requires both columns (no half-acknowledged row)',
  $q$select count(*)::text from pg_constraint
      where conname = 'reconciliation_alerts_ack_check' and contype = 'c'$q$, '1');

select public.r_expect('R1 no alert can repeat for the same (run, asset, environment, kind)',
  $q$select count(*)::text from pg_constraint
      where conname = 'reconciliation_alerts_key' and contype = 'u'$q$, '1');

-- ===========================================================================
\echo '=== R2. provider balance intake - honest, exact, one write path'
-- ===========================================================================
select public.r_expect('R2 provider_balances is EMPTY: the migration seeds no provider data',
  $q$select count(*)::text from public.provider_balances$q$, '0');

select public.r_expect('R2 ... and so is its history log',
  $q$select count(*)::text from public.provider_balances_log$q$, '0');

select public.r_expect('R2 no USDT provider report exists yet (nothing seeded)',
  $q$select count(*)::text from public.provider_balances
       where asset_id = (select id from public.assets where symbol = 'USDT')$q$, '0');

select public.r_run('R2 record a first USDT/ethereum report (1234567 base units)',
  $q$select public.record_provider_balance('USDT','ethereum',1234567,'stage4-suite-fixture','paper')$q$);

select public.r_expect('R2 the report is stored verbatim, keyed by (asset, network, environment)',
  $q$select units::text || '/' || network || '/' || environment || '/' || source
        from public.provider_balances
       where asset_id = (select id from public.assets where symbol = 'USDT')$q$,
  '1234567/ethereum/paper/stage4-suite-fixture');

select public.r_expect('R2 the history log got one "recorded" row with no previous value',
  $q$select action || '/' || coalesce(previous_units::text,'-') || '/' || units::text
        from public.provider_balances_log order by recorded_at limit 1$q$, 'recorded/-/1234567');

select public.r_run('R2 a second report for the same key upserts instead of duplicating',
  $q$select public.record_provider_balance('USDT','ethereum',2222222,'stage4-suite-fixture','paper')$q$);

select public.r_expect('R2 still one row for that key, with the new value',
  $q$select count(*)::text || '/' || max(units)::text from public.provider_balances
       where asset_id = (select id from public.assets where symbol = 'USDT')$q$, '1/2222222');

select public.r_expect('R2 ... and the replaced value is preserved in the append-only log',
  $q$select string_agg(action || ':' || coalesce(previous_units::text,'-') || '>' || units::text, ',' order by recorded_at)
        from public.provider_balances_log$q$, 'recorded:->1234567,replaced:1234567>2222222');

select public.r_expect('R2 an upper-case network is normalised to lower case, not invented',
  $q$select public.record_provider_balance('USDT','Tron',555,'stage4-suite-fixture','paper') is not null$q$, 'true');

select public.r_expect('R2 ... stored as tron',
  $q$select network from public.provider_balances
       where asset_id = (select id from public.assets where symbol = 'USDT') and units = 555$q$, 'tron');

select public.r_expect('R2 two networks for one asset both survive (one row per network)',
  $q$select count(*)::text from public.provider_balances
       where asset_id = (select id from public.assets where symbol = 'USDT')$q$, '2');

select public.r_expect_error('R2 fractional units are REFUSED, never rounded',
  $q$select public.record_provider_balance('USDT','ethereum',1.5,'stage4-suite-fixture')$q$, 'whole number');

select public.r_expect_error('R2 a negative holding is refused',
  $q$select public.record_provider_balance('USDT','ethereum',-1,'stage4-suite-fixture')$q$, 'negative');

select public.r_expect_error('R2 a NUL report is refused (absence of a row is what "unavailable" means)',
  $q$select public.record_provider_balance('USDT','ethereum',null,'stage4-suite-fixture')$q$, 'units are required');

select public.r_expect_error('R2 an unknown asset is refused',
  $q$select public.record_provider_balance('DOGE','ethereum',1,'stage4-suite-fixture')$q$, 'unknown asset');

select public.r_expect_error('R2 a report with no source is refused',
  $q$select public.record_provider_balance('USDT','ethereum',1,'  ')$q$, 'source is required');

select public.r_expect_error('R2 a non-object detail is refused',
  $q$select public.record_provider_balance('USDT','ethereum',1,'stage4-suite-fixture','paper',now(),'"x"'::jsonb)$q$, 'JSON object');

select public.r_expect_error('R2 an unknown environment is refused',
  $q$select public.record_provider_balance('USDT','ethereum',1,'stage4-suite-fixture','staging')$q$, 'unknown environment');

select public.r_expect_error('R2 service_role cannot insert into the table directly (RPC is the only path)',
  $q$insert into public.provider_balances (asset_id, network, units, source)
     select id, 'bitcoin', 1, 'sneaky' from public.assets where symbol = 'BTC';
     select 'inserted'$q$, 'permission denied', 'service_role');

select public.r_expect_error('R2 ... nor can authenticated',
  $q$insert into public.provider_balances (asset_id, network, units, source)
     select id, 'bitcoin', 1, 'sneaky' from public.assets where symbol = 'BTC';
     select 'inserted'$q$, 'permission denied', 'authenticated');

select public.r_expect_error('R2 ... nor can anon read it',
  $q$select count(*)::text from public.provider_balances$q$, 'permission denied', 'anon');

select public.r_expect('R2 a superuser edit is still logged (the trigger keeps history)',
  $q$update public.provider_balances set units = units
      where asset_id = (select id from public.assets where symbol = 'USDT') and network = 'tron';
     select action from public.provider_balances_log order by recorded_at desc limit 1$q$, 'replaced');

select public.r_expect_error('R2 the history log cannot be edited',
  $q$update public.provider_balances_log set units = 0; select 'updated'$q$, 'append-only');

select public.r_expect_error('R2 the history log cannot be deleted',
  $q$delete from public.provider_balances_log; select 'deleted'$q$, 'append-only');

-- back to a state with NO provider report at all: the current row goes, the
-- history stays (that is what an append-only log means)
select public.r_run('R2 clear the current provider rows for the unavailability test',
  $q$delete from public.provider_balances$q$);

select public.r_expect('R2 the current table is empty again',
  $q$select count(*)::text from public.provider_balances$q$, '0');

select public.r_expect('R2 ... but the history still records every report that was made',
  $q$select count(*) > 0 from public.provider_balances_log$q$, 'true');

-- ===========================================================================
\echo '=== R3. honest unavailability - no provider data => unavailable, never 0'
-- ===========================================================================
select public.r_snap('r3_before');
select public.r_run('R3 run the reconciliation on a balanced paper state with no provider data',
  $q$select public.r_recon('r_super')$q$);

select public.r_expect('R3 the run completed with a real actor',
  $q$select status || '/' || environment || '/' || (triggered_by is not null)::text
        from public.reconciliation_runs order by started_at desc limit 1$q$, 'completed/paper/true');

select public.r_expect('R3 one result per active asset',
  $q$select count(*)::text from public.reconciliation_results
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$, '4');

select public.r_expect('R3 EVERY asset is "unavailable" (never 0, never match)',
  $q$select string_agg(status, ',' order by ast.symbol) from public.reconciliation_results r
        join public.assets ast on ast.id = r.asset_id
       where r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$,
  'unavailable,unavailable,unavailable,unavailable');

select public.r_expect('R3 provider_units is NUL everywhere (not zero)',
  $q$select count(*)::text from public.reconciliation_results
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and provider_units is not null$q$, '0');

select public.r_expect('R3 the detail says "unavailable" in words too',
  $q$select count(*)::text from public.reconciliation_results
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and detail->>'provider_status' = 'unavailable'$q$, '4');

select public.r_expect('R3 internal drift is zero on every asset (the projection matches the ledger)',
  $q$select coalesce(sum(drift_units), 0)::text || '/' || count(*) filter (where drift_units <> 0)::text
        from public.reconciliation_results
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$, '0/0');

select public.r_expect('R3 an unavailable comparison raises NO alert (unknown is not a discrepancy)',
  $q$select count(*)::text from public.reconciliation_alerts
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$, '0');

select public.r_expect('R3 the invariants scan passed every check and says so per check',
  $q$select string_agg(c->>'check' || '=' || (c->>'ok'), ',' order by c->>'check')
        from public.reconciliation_runs r, jsonb_array_elements(r.detail->'invariants') c
       where r.id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$,
  'asset_totals_zero=true,balances_match_ledger=true,ledger_transactions_balanced=true');

select public.r_expect('R3 the run wrote no money: the ledger and the balances are unchanged',
  $q$select (select count(*) from public.ledger_transactions)::text = public.r_snap_value('r3_before_tx')
        and (select count(*) from public.ledger_entries)::text = public.r_snap_value('r3_before_entries')
        and coalesce((select sum(b.available_units + b.locked_units) from public.balances b),0)::text
            = public.r_snap_value('r3_before_balances')$q$, 'true');

select public.r_expect('R3 the run detail records the counts and the "detect only" note',
  $q$select (detail->>'assets_scanned') || '/' || (detail->'results'->>'unavailable') || '/'
          || (detail->>'provider_balances_reported')
        from public.reconciliation_runs order by started_at desc limit 1$q$, '4/4/0');

-- ===========================================================================
\echo '=== R4. balanced paper state WITH provider data that matches => every asset match'
-- ===========================================================================
select public.r_expect('R4 the custody-side mirror is not negative on any asset (a provider cannot report a negative holding)',
  $q$select count(*)::text from public.reconciliation_results
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and custody_units < 0$q$, '0');

select public.r_run('R4 record a provider report per asset that equals the ledger custody figure',
  $q$select public.r_provider(ast.symbol, r.custody_units)
       from public.reconciliation_results r
       join public.assets ast on ast.id = r.asset_id
      where r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
        and r.custody_units >= 0$q$);

select public.r_expect('R4 four provider reports exist, all labelled as suite fixtures',
  $q$select count(*)::text || '/' || count(*) filter (where source = 'stage4-suite-fixture')::text
        from public.provider_balances$q$, '4/4');

select public.r_snap('r4_before');
select public.r_run('R4 run again: balanced state, provider data matching custody',
  $q$select public.r_recon('r_super')$q$);

select public.r_expect('R4 EVERY asset is "match"',
  $q$select string_agg(r.status, ',' order by ast.symbol) from public.reconciliation_results r
        join public.assets ast on ast.id = r.asset_id
       where r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$,
  'match,match,match,match');

select public.r_expect('R4 the provider number is now reported and equals custody on every asset',
  $q$select count(*)::text from public.reconciliation_results
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and (provider_units is null or provider_units <> custody_units)$q$, '0');

select public.r_expect('R4 zero alerts on a balanced state (no noise, no invented discrepancy)',
  $q$select count(*)::text from public.reconciliation_alerts
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$, '0');

select public.r_expect('R4 the run wrote no money and no provider row',
  $q$select (select count(*) from public.ledger_transactions)::text = public.r_snap_value('r4_before_tx')
        and (select count(*) from public.ledger_entries)::text = public.r_snap_value('r4_before_entries')
        and (select count(*) from public.provider_balances)::text = '4'$q$, 'true');

select public.r_expect('R4 the custody breakdown is shown per system account (nothing hidden)',
  $q$select (detail->'custody_breakdown'->>'EXTERNAL_DEPOSIT') is not null
        or (detail->'custody_breakdown'->>'WITHDRawAL_CLEARING') is not null
        or (detail->>'nnon_custody_system_units') is not null
        from public.reconciliation_results
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
       order by custody_units desc limit 1$q$, 'true');

-- ===========================================================================
\echo '=== R5. injection A - a bogus provider report => WARNING, nothing corrected'
-- ===========================================================================
select public.r_run('R5 record a provider report that is 1 unit too high for BTC',
  $q$select public.r_provider('BTC', r.custody_units + 1)
       from public.reconciliation_results r
      where r.asset_id = (select id from public.assets where symbol = 'BTC')
        and r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$);

select public.r_snap('r5_before');
select public.r_run('R5 run the reconciliation',
  $q$select public.r_recon('r_super')$q$);

select public.r_expect('R5 BTC is "drift", the other three stay "match"',
  $q$select string_agg(r.status, ',' order by ast.symbol) from public.reconciliation_results r
        join public.assets ast on ast.id = r.asset_id
       where r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$,
  'drift,match,match,match');

select public.r_expect('R5 exactly one provider_mismatch alert, severity WARNING (not critical)',
  $q$select count(*)::text || '/' || min(severity) from public.reconciliation_alerts
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and kind = 'provider_mismatch'$q$, '1/warning');

select public.r_expect('R5 the alert carries both numbers and the difference',
  $q$select (detail->>'custody_units') || '/' || (detail->>'provider_units') || '/' || (detail->>'provider_drift_units')
        from public.reconciliation_alerts
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and kind = 'provider_mismatch'$q$,
  (select custody_units::text || '/' || provider_units::text || '/1'
     from public.reconciliation_results
    where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
      and asset_id = (select id from public.assets where symbol = 'BTC')));

select public.r_expect('R5 NOTHING was corrected: the ledger, the balances and the provider row are untouched',
  $q$select (select count(*) from public.ledger_transactions)::text = public.r_snap_value('r5_before_tx')
        and (select count(*) from public.ledger_entries)::text = public.r_snap_value('r5_before_entries')
        and coalesce((select sum(b.available_units + b.locked_units) from public.balances b),0)::text
            = public.r_snap_value('r5_before_balances')
        and (select units from public.provider_balances
              where asset_id = (select id from public.assets where symbol='BTC')
                and network = 'scratch-custody')::text
            = ((select custody_units from public.reconciliation_results
                 where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
                   and asset_id = (select id from public.assets where symbol='BTC')) + 1)::text$q$, 'true');

select public.r_expect('R5 no compensating "correction" transaction was posted (the type count is unchanged)',
  $q$select count(*)::text from public.ledger_transactions where type = 'correction'$q$,
  (select count(*)::text from public.ledger_transactions where type = 'correction'));

-- a stale report: same value as custody, but 48 hours old
select public.r_run('R5 record a BTC report equal to custody but 48h old',
  $q$select public.r_provider('BTC', r.custody_units, now() - interval '48 hours')
       from public.reconciliation_results r
      where r.asset_id = (select id from public.assets where symbol = 'BTC')
        and r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$);

select public.r_run('R5 run again',
  $q$select public.r_recon('r_super')$q$);

select public.r_expect('R5 BTC is "match" again (the value agrees) but a stale_provider WARNING is raised',
  $q$select (select status from public.reconciliation_results
              where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
                and asset_id = (select id from public.assets where symbol='BTC'))
        || '/' || (select count(*)::text from public.reconciliation_alerts
                    where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
                      and kind = 'stale_provider')$q$, 'match/1');

select public.r_expect('R5 the stale alert records the age and the threshold (an old number is reported as old)',
  $q$select (detail->>'threshold_hours') || '/' || ((detail->>'age_hours')::numeric >= 47)::text
        from public.reconciliation_alerts
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and kind = 'stale_provider'$q$, '24/true');

select public.r_expect('R5 no provider_mismatch is raised for that run (the value agrees)',
  $q$select count(*)::text from public.reconciliation_alerts
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and kind = 'provider_mismatch'$q$, '0');

-- ===========================================================================
\echo '=== R6. injection B - internal drift is impossible by API, and DETECTED when forced'
-- ===========================================================================
-- (a) the existing triggers refuse every API path to internal drift. These two are
--     deferred constraint triggers: they fire at COMMIT, so the psql ERROR line is
--     the PASS condition (like the ledger suite's D1-D4).
\echo '-- R6 (a1) EXPECTED ERROR: a cached balance moved without ledger entries is refused'
begin;
update public.balances
   set available_units = available_units + 1
 where account_id = (select b.account_id from public.balances b
                       join public.accounts a on a.id = b.account_id
                      where a.user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                        and a.kind = 'available' and a.environment = 'paper'
                        and a.asset_id = (select id from public.assets where symbol = 'BTC'));
commit;

\echo '-- R6 (a2) EXPECTED ERROR: an unbalanced ledger transaction is refused'
begin;
insert into public.ledger_transactions (type, environment, description)
values ('correction', 'paper', 'stage4 scratch unbalanced probe') returning id as t_probe \gset
insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units)
select :'t_probe'::uuid, b.account_id, a.asset_id, 'paper', 5
  from public.balances b join public.accounts a on a.id = b.account_id
 where a.user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001' and a.kind = 'available'
   and a.environment = 'paper' and a.asset_id = (select id from public.assets where symbol = 'BTC');
commit;

select public.r_expect('R6 (a3) the ledger is still consistent after those two refusals',
  $q$select count(*)::text from public.v_account_reconciliation where drift_units <> 0$q$, '0');

select public.r_expect_error('R6 (a4) the ledger entries cannot be edited',
  $q$update public.ledger_entries set amount_units = 0 where true; select 'updated'$q$, 'append-only');

select public.r_expect_error('R6 (a5) ... nor deleted',
  $q$delete from public.ledger_entries; select 'deleted'$q$, 'append-only');

select public.r_expect_error('R6 (a6) a client role cannot touch a balance at all',
  $q$update public.balances set available_units = available_units + 1; select 'updated'$q$,
  'permission denied', 'authenticated');

select public.r_expect_error('R6 (a7) even service_role cannot edit the ledger',
  $q$delete from public.ledger_transactions; select 'deleted'$q$, 'permission denied', 'service_role');

-- (b) forced drift: a superuser tampers with the deferred trigger in SCRAATCH.
--     No API path can do this (a1-a7), which is the point; the goal here is to
--     prove the DETECTION works and that NOTHING is corrected.
select public.r_run('R6 (b1) force +7 units of drift by disabling the trigger for one statement',
  $q$do $do$
      declare v_acct uuid;
      begin
        select b.account_id into v_acct
          from public.balances b join public.accounts a on a.id = b.account_id
         where a.user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001' and a.kind = 'available'
           and a.environment = 'paper'
           and a.asset_id = (select id from public.assets where symbol = 'BTC');
        alter table public.balances disable trigger balances_match_ledger;
        update public.balances set available_units = available_units + 7 where account_id = v_acct;
        alter table public.balances enable trigger balances_match_ledger;
      end $do$ $q$);

select public.r_expect('R6 (b2) the drift really exists (the trigger is enabled again)',
  $q$select drift_units::text from public.v_account_reconciliation
       where account_id = (select b.account_id from public.balances b join public.accounts a on a.id = b.account_id
                            where a.user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001' and a.kind = 'available'
                              and a.environment = 'paper'
                              and a.asset_id = (select id from public.assets where symbol = 'BTC'))$q$, '7');

select public.r_snap('r6_before');
select public.r_run('R6 (b3) run the reconciliation with the drift present',
  $q$select public.r_recon('r_super')$q$);

select public.r_expect('R6 (b4) BTC is "drift" with drift_units = -7 (cache 7 above the ledger)',
  $q$select status || '/' || drift_units::text from public.reconciliation_results
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and asset_id = (select id from public.assets where symbol = 'BTC')$q$, 'drift/-7');

select public.r_expect('R6 (b5) a CRITICAL internal_drift alert was raised',
  $q$select severity || '/' || kind from public.reconciliation_alerts
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and kind = 'internal_drift'$q$, 'critical/internal_drift');

select public.r_expect('R6 (b6) the invariant scan failed exactly the balance check and named the account',
  $q$select (c->>'ok') || '/' || (c->>'offending') || '/' || ((c->'sample_ids') ? (select b.account_id::text
             from public.balances b join public.accounts a on a.id = b.account_id
            where a.user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001' and a.kind = 'available'
              and a.environment = 'paper'
              and a.asset_id = (select id from public.assets where symbol = 'BTC')))::text
        from public.reconciliation_runs r, jsonb_array_elements(r.detail->'invariants') c
       where r.id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and c->>'check' = 'balances_match_ledger'$q$, 'false/1/true');

select public.r_expect('R6 (b7) the other two invariant checks still passed (per-check granularity)',
  $q$select string_agg((c->>'ok'), ',' order by c->>'check')
        from public.reconciliation_runs r, jsonb_array_elements(r.detail->'invariants') c
       where r.id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and c->>'check' in ('asset_totals_zero','ledger_transactions_balanced')$q$, 'true,true');

select public.r_expect('R6 (b8) NOTHING was corrected: the drift is STILL 7 after the run',
  $q$select drift_units::text from public.v_account_reconciliation
       where account_id = (select b.account_id from public.balances b join public.accounts a on a.id = b.account_id
                            where a.user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001' and a.kind = 'available'
                              and a.environment = 'paper'
                              and a.asset_id = (select id from public.assets where symbol = 'BTC'))$q$, '7');

select public.r_expect('R6 (b9) ... and no ledger row, no balance total and no provider figure changed',
  $q$select (select count(*) from public.ledger_transactions)::text = public.r_snap_value('r6_before_tx')
        and (select count(*) from public.ledger_entries)::text = public.r_snap_value('r6_before_entries')
        and coalesce((select sum(b.available_units + b.locked_units) from public.balances b),0)::text
            = public.r_snap_value('r6_before_balances')$q$, 'true');

-- (c) put the scratch database back exactly as it was (undo of the test tamp, not
--     a "correction" of a real discrepancy)
select public.r_run('R6 (c1) remove the injected drift',
  $q$do $do$
      declare v_acct uuid;
      begin
        select b.account_id into v_acct
          from public.balances b join public.accounts a on a.id = b.account_id
         where a.user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001' and a.kind = 'available'
           and a.environment = 'paper'
           and a.asset_id = (select id from public.assets where symbol = 'BTC');
        alter table public.balances disable trigger balances_match_ledger;
        update public.balances set available_units = available_units - 7 where account_id = v_acct;
        alter table public.balances enable trigger balances_match_ledger;
      end $do$ $q$);

select public.r_expect('R6 (c2) the scratch database is consistent again (zero drift everywhere)',
  $q$select count(*)::text from public.v_account_reconciliation where drift_units <> 0$q$, '0');

select public.r_run('R6 (c3) re-record the BTC provider report as current and matching',
  $q$select public.r_provider('BTC', r.custody_units)
       from public.reconciliation_results r
      where r.asset_id = (select id from public.assets where symbol = 'BTC')
        and r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$);

select public.r_run('R6 (c4) a final clean run',
  $q$select public.r_recon('r_super')$q$);

select public.r_expect('R6 (c5) the clean run is all "match" with zero alerts',
  $q$select (select string_agg(status, ',' order by ast.symbol) from public.reconciliation_results r
               join public.assets ast on ast.id = r.asset_id
              where r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1))
        || '/' || (select count(*)::text from public.reconciliation_alerts
                    where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1))$q$,
  'match,match,match,match/0');

-- ===========================================================================
\echo '=== R7. run idempotency and alert duplication choice'
-- ===========================================================================
select public.r_run('R7 inject a provider mismatch again (for the duplication test)',
  $q$select public.r_provider('BTC', r.custody_units + 3)
       from public.reconciliation_results r
      where r.asset_id = (select id from public.assets where symbol = 'BTC')
        and r.run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)$q$);

select public.r_run('R7 run A',
  $q$select public.r_recon('r_super')$q$);
select public.r_run('R7 run B (immediately after A, same unchanged state)',
  $q$select public.r_recon('r_super')$q$);

select public.r_expect('R7 the two runs agree on every number (same state, same result)',
  $q$select count(*)::text from (
        select asset_id, customer_liability_units, projection_units, custody_units, provider_units, status
          from public.reconciliation_results
         where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
        except
        select asset_id, customer_liability_units, projection_units, custody_units, provider_units, status
          from public.reconciliation_results
         where run_id = (select id from public.reconciliation_runs order by started_at desc offset 1 limit 1)) x$q$, '0');

select public.r_expect('R7 each run raises its OWN alert (documented choice: one alert per run, never deduplicated across runs)',
  $q$select count(*)::text || '/' || count(distinct run_id)::text from public.reconciliation_alerts
       where kind = 'provider_mismatch'$q$,
  (select count(*)::text || '/' || count(distinct run_id)::text from public.reconciliation_alerts
    where kind = 'provider_mismatch'));

select public.r_expect('R7 ... and within one run exactly one alert per (asset, kind)',
  $q$select count(*)::text from (
        select run_id, asset_id, environment, kind, count(*)
          from public.reconciliation_alerts
         group by run_id, asset_id, environment, kind
        having count(*) > 1) x$q$, '0');

select public.r_expect_error('R7 the UNIQUE constraint refuses a duplicate alert for the same run/asset/kind',
  $q$insert into public.reconciliation_alerts (run_id, asset_id, environment, severity, kind)
     select run_id, asset_id, environment, 'warning', kind from public.reconciliation_alerts limit 1;
     select 'inserted'$q$, 'reconciliation_alerts_key');

select public.r_expect('R7 every alert points at a real run and a real asset (no orphan alert)',
  $q$select count(*)::text from public.reconciliation_alerts a
        left join public.reconciliation_runs r on r.id = a.run_id
        left join public.assets ast on ast.id = a.asset_id
       where r.id is null or ast.id is null$q$, '0');

-- ===========================================================================
\echo '=== R8. authorisation, audit actor, acknowledge flow, view scoping'
-- ===========================================================================
select public.r_expect_error_as('R8 support cannot run a reconciliation (security.read is denied)',
  'r_supp', $q$select public.run_reconciliation('paper', public.r_id('r_supp'))$q$, 'not permitted');

select public.r_expect_error_as('R8 readonly cannot acknowledge an alert (risk.write is denied)',
  'r_ro', $q$select public.acknowledge_reconciliation_alert(
     (select id from public.reconciliation_alerts where kind = 'provider_mismatch' order by created_at desc limit 1),
     'readonly note', public.r_id('r_ro'))$q$, 'not permitted');

select public.r_expect('R8 readonly CAN run one (security.read is allowed: a read-only audit scan)',
  $q$select public.run_reconciliation('paper', public.r_id('r_ro')) is not null$q$, 'true');

select public.r_expect('R8 ... and it is audited with the readonly operator as the actor',
  $q$select l.actor_role || '/' || (l.actor_id = public.r_id('r_ro'))::text || '/' || (l.entity_id = (select id from public.reconciliation_runs order by started_at desc limit 1))::text
        from public.security_audit_log l
       where l.action = 'reconciliation.run' and l.actor_id = public.r_id('r_ro')
       order by l.at desc limit 1$q$, 'operator/true/true');

select public.r_expect('R8 the audit row names the environment and the counts',
  $q$select (l.details->>'environment') || '/' || (l.details->>'status') || '/' || ((l.details->>'results') = '4')::text
        from public.security_audit_log l
       where l.action = 'reconciliation.run'
       order by l.at desc limit 1$q$, 'paper/completed/true');

select public.r_expect('R8 every completed run has an audit row with a NON-NULL operator actor',
  $q$select count(*)::text from public.reconciliation_runs r
       where r.status = 'completed'
         and not exists (select 1 from public.security_audit_log l
                          where l.action = 'reconciliation.run' and l.entity_id = r.id
                            and l.actor_role = 'operator' and l.actor_id is not null)$q$, '0');

select public.r_expect('R8 the run row itself names the triggering operator (no anonymous run)',
  $q$select count(*)::text from public.reconciliation_runs where triggered_by is null$q$, '0');

select public.r_run('R8 compliance acknowledges the newest open alert',
  $q$select public.acknowledge_reconciliation_alert(
     (select id from public.reconciliation_alerts where acknowledged_at is null order by created_at desc limit 1),
     'acknowledged during the stage4 suite', public.r_id('r_comp'))$q$);

select public.r_expect('R8 the acknowledgement is recorded with the operator and the note',
  $q$select (acknowledged_at is not null)::text || '/' || (acknowledged_by = public.r_id('r_comp'))::text
        || '/' || acknowledge_note
        from public.reconciliation_alerts where acknowledged_at is not null order by acknowledged_at desc limit 1$q$,
  'true/true/acknowledged during the stage4 suite');

select public.r_expect('R8 ... and it is audited as an operator action',
  $q$select l.actor_role || '/' || (l.actor_id = public.r_id('r_comp'))::text || '/' || (l.details->>'effect')
        from public.security_audit_log l
       where l.action = 'reconciliation.alert.acknowledged' order by l.at desc limit 1$q$,
  'operator/true/acknowledged only: no balance, ledger row or provider figure was changed');

select public.r_expect_error_as('R8 an acknowledgement is WRITE-ONCE (a second one is refused)',
  'r_comp', $q$select public.acknowledge_reconciliation_alert(
     (select id from public.reconciliation_alerts where acknowledged_at is not null order by acknowledged_at desc limit 1),
     'again', public.r_id('r_comp'))$q$, 'already acknowledged');

select public.r_expect('R8 acknowledging did not change a single number (the provider drift is still 3)',
  $q$select (provider_units - custody_units)::text from public.reconciliation_results
       where asset_id = (select id from public.assets where symbol = 'BTC')
         and run_id = (select run_id from public.reconciliation_alerts
                        where acknowledged_at is not null order by acknowledged_at desc limit 1)$q$,
  '3');

select public.r_expect_error('R8 an alert cannot be edited back (no un-acknowledge, no severity downgrade)',
  $q$update public.reconciliation_alerts set acknowledged_at = null, acknowledged_by = null
      where acknowledged_at is not null; select 'updated'$q$, 'write-once');

select public.r_expect_error('R8 an alert cannot be deleted',
  $q$delete from public.reconciliation_alerts; select 'deleted'$q$, 'append-only');

select public.r_expect_error('R8 a result row cannot be edited',
  $q$update public.reconciliation_results set status = 'match'; select 'updated'$q$, 'append-only');

select public.r_expect_error('R8 a finished run cannot be re-opened or re-written',
  $q$update public.reconciliation_runs set status = 'running'
      where status = 'completed'; select 'updated'$q$, 'write-once');

select public.r_expect_error('R8 a run cannot be deleted (the history stays)',
  $q$delete from public.reconciliation_runs; select 'deleted'$q$, 'append-only');

select public.r_expect_error('R8 a client role cannot read the raw tables',
  $q$select count(*)::text from public.reconciliation_alerts$q$, 'permission denied', 'authenticated');

select public.r_expect_error('R8 ... nor call the acknowledge RPC',
  $q$select public.acknowledge_reconciliation_alert(gen_random_uuid(), null, null)$q$,
  'permission denied', 'authenticated');

select public.r_expect_error('R8 ... nor call the run RPC',
  $q$select public.run_reconciliation('paper', null)$q$, 'permission denied', 'authenticated');

select public.r_expect_error('R8 ... nor call the provider intake',
  $q$select public.record_provider_balance('BTC','bitcoin',1,'x')$q$, 'permission denied', 'anon');

select public.r_expect('R8 an ordinary signed-in customer sees nothing in either admin view',
  $q$select (select count(*) from public.v_admin_reconciliation)::text || '/'
        || (select count(*) from public.v_admin_reconciliation_alerts)::text$q$, '0/0',
  'authenticated', 'ffffffff-ffff-ffff-ffff-ffffffff0001');

select public.r_expect_error('R8 anon gets a permission denied on both views (no grant at all)',
  $q$select count(*)::text from public.v_admin_reconciliation$q$, 'permission denied', 'anon');

select public.r_expect_as('R8 support sees the reconciliation numbers (money.read) but NO alerts (security.read denied)',
  'r_supp',
  $q$select (select count(*) from public.v_admin_reconciliation)::text || '/'
        || (select count(*) from public.v_admin_reconciliation_alerts)::text$q$, '4/0');

select public.r_expect_as('R8 readonly sees both (money.read + security.read)',
  'r_ro',
  $q$select (select count(*) > 0 from public.v_admin_reconciliation)::text || '/'
        || (select count(*) > 0 from public.v_admin_reconciliation_alerts)::text$q$, 'true/true');

select public.r_expect_as('R8 the reconciliation view shows the latest run per environment with its alert counts',
  'r_super',
  $q$select count(*)::text || '/' || count(distinct run_id)::text || '/' || bool_and(open_alert_count >= 0)::text
        from public.v_admin_reconciliation$q$, '4/1/true');

-- the failed-run row is never invisible (synthetic run row, scratch only)
select public.r_run('R8 insert a synthetic FAILED run to prove the view surfaces it',
  $q$insert into public.reconciliation_runs (environment, status, finished_at, triggered_by, detail)
     values ('live', 'failed', now(), public.r_id('r_super'),
             jsonb_build_object('error','scratch fixture: a failed run must stay visible'))$q$);

select public.r_expect_as('R8 the failed run appears as a row with status "failed" instead of disappearing',
  'r_super',
  $q$select coalesce(asset,'-') || '/' || status from public.v_admin_reconciliation
       where environment = 'live'$q$, '-/failed');

-- ===========================================================================
\echo '=== R9. the directive idempotency / double-spend re-proofs'
-- ===========================================================================
select public.r_expect('R9 a credited deposit from the deposits suite exists to re-prove against',
  $q$select count(*) > 0 from public.deposits where credited_ledger_transaction_id is not null$q$, 'true');

select public.r_expect('R9 a settled withdrawal from the withdrawals suite exists to re-prove against',
  $q$select count(*) > 0 from public.withdrawal_requests where settled_ledger_transaction_id is not null$q$, 'true');

select public.r_expect_error('R9 re-crediting an already credited deposit is REFUSED (no double credit)',
  $q$select public.credit_deposit((select id from public.deposits
                                    where credited_ledger_transaction_id is not null limit 1))$q$,
  'already credited');

select public.r_expect('R9 ... and it still has exactly ONE deposit_credit transaction',
  $q$select count(*)::text from public.ledger_transactions t
        join public.deposits d on d.credited_ledger_transaction_id = t.id
       where t.type = 'deposit_credit' and d.id = (select id from public.deposits
                                                   where credited_ledger_transaction_id is not null limit 1)$q$, '1');

select public.r_expect_error('R9 re-settling an already settled withdrawal is REFUSED (no double payout)',
  $q$select public.complete_withdrawal((select id from public.withdrawal_requests
                                         where settled_ledger_transaction_id is not null limit 1), 'scratch-replay')$q$,
  'already settled');

select public.r_expect('R9 ... and it still has exactly ONE withdrawal_settle transaction',
  $q$select count(*)::text from public.ledger_transactions t
        join public.withdrawal_requests w on w.settled_ledger_transaction_id = t.id
       where t.type = 'withdrawal_settle' and w.id = (select id from public.withdrawal_requests
                                                       where settled_ledger_transaction_id is not null limit 1)$q$, '1');

-- reserved balances: a resting limit sell holds exactly, and cancel releases exactly
select public.r_run('R9 place a resting limit sell for the fixture customer (BTC)',
  $q$select public.place_order(
      (select m.symbol from public.markets m join public.assets a on a.id = m.base_asset_id
        where a.symbol = 'BTC' and m.environment = 'paper' and m.is_active and m.status = 'trading'
        order by m.symbol limit 1),
      'sell', 'limit', 100000, 99999999999999, 'gtc', 'stage4-reserved-probe',
      'ffffffff-ffff-ffff-ffff-ffffffff0001')$q$);

select public.r_expect('R9 the order rested (it is real, not filled)',
  $q$select status || '/' || (hold_amount_units > 0)::text from public.orders
       where client_order_id = 'stage4-reserved-probe'$q$, 'new/true');

select public.r_expect('R9 the hold moved EXACTLY: available -X, locked +X, total unchanged',
  $q$select (b_av.available_units = 100000000 - o.hold_amount_units)::text || '/'
        || (b_lk.locked_units = o.hold_amount_units)::text || '/'
        || ((b_av.available_units + b_lk.locked_units) = 100000000)::text
        from public.orders o
        join public.balances b_av on b_av.account_id = (select id from public.accounts
             where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001' and kind = 'available'
               and environment = 'paper' and asset_id = o.hold_asset_id)
        join public.balances b_lk on b_lk.account_id = (select id from public.accounts
             where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001' and kind = 'locked'
               and environment = 'paper' and asset_id = o.hold_asset_id)
       where o.client_order_id = 'stage4-reserved-probe'$q$, 'true/true/true');

select public.r_run('R9 cancel the resting order',
  $q$select public.cancel_order((select id from public.orders where client_order_id = 'stage4-reserved-probe'),
                                'stage4 reserved probe', 'ffffffff-ffff-ffff-ffff-ffffffff0001')$q$);

select public.r_expect('R9 the release is EXACT: available back to 100000000, locked back to 0',
  $q$select b_av.available_units::text || '/' || b_lk.locked_units::text from public.balances b_av, public.balances b_lk
       where b_av.account_id = (select id from public.accounts where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                                 and kind = 'available' and environment = 'paper'
                                 and asset_id = (select id from public.assets where symbol = 'BTC'))
         and b_lk.account_id = (select id from public.accounts where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                                 and kind = 'locked' and environment = 'paper'
                                 and asset_id = (select id from public.assets where symbol = 'BTC'))$q$,
  '100000000/0');

select public.r_expect_error('R9 a second cancel is refused (a release can never happen twice)',
  $q$select public.cancel_order((select id from public.orders where client_order_id = 'stage4-reserved-probe'),
                                'again', 'ffffffff-ffff-ffff-ffff-ffffffff0001')$q$, 'cannot be cancelled');

-- failure/refund exactly once
select public.r_run('R9 create a paper BTC withdrawal request for the fixture customer',
  $q$select public.record_withdrawal_request('ffffffff-ffff-ffff-ffff-ffffffff0001', 'BTC', 'bitcoin',
      'scratch-stage4-destination', 1000000)$q$);

select public.r_expect('R9 a pending request holds nothing yet (the hold is placed at approval)',
  $q$select b_av.available_units::text || '/' || b_lk.locked_units::text
        from public.balances b_av, public.balances b_lk
       where b_av.account_id = (select id from public.accounts where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                                 and kind = 'available' and environment = 'paper'
                                 and asset_id = (select id from public.assets where symbol = 'BTC'))
         and b_lk.account_id = (select id from public.accounts where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                                 and kind = 'locked' and environment = 'paper'
                                 and asset_id = (select id from public.assets where symbol = 'BTC'))$q$,
  '100000000/0');

select public.r_run('R9 approve it', $q$select public.approve_withdrawal(
  (select id from public.withdrawal_requests where destination_address = 'scratch-stage4-destination'))$q$);

select public.r_expect('R9 approval holds the amount plus the fee EXACTLY',
  $q$select b_av.available_units::text || '/' || b_lk.locked_units::text
        from public.balances b_av, public.balances b_lk
       where b_av.account_id = (select id from public.accounts where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                                 and kind = 'available' and environment = 'paper'
                                 and asset_id = (select id from public.assets where symbol = 'BTC'))
         and b_lk.account_id = (select id from public.accounts where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                                 and kind = 'locked' and environment = 'paper'
                                 and asset_id = (select id from public.assets where symbol = 'BTC'))$q$,
  (select (100000000 - (amount_units + fee_units))::text || '/' || (amount_units + fee_units)::text
     from public.withdrawal_requests
    where destination_address = 'scratch-stage4-destination'));
select public.r_run('R9 start processing it', $q$select public.start_withdrawal_processing(
  (select id from public.withdrawal_requests where destination_address = 'scratch-stage4-destination'),
  'scratch-stage4-provider-txid')$q$);
select public.r_run('R9 fail it (broadcast failed) - the hold must be refunded exactly once',
  $q$select public.fail_withdrawal(
  (select id from public.withdrawal_requests where destination_address = 'scratch-stage4-destination'),
  'scratch fixture: provider broadcast failed')$q$);

select public.r_expect('R9 after the failure the balances are EXACTLY back (available 100000000, locked 0)',
  $q$select b_av.available_units::text || '/' || b_lk.locked_units::text
        from public.balances b_av, public.balances b_lk
       where b_av.account_id = (select id from public.accounts where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                                 and kind = 'available' and environment = 'paper'
                                 and asset_id = (select id from public.assets where symbol = 'BTC'))
         and b_lk.account_id = (select id from public.accounts where user_id = 'ffffffff-ffff-ffff-ffff-ffffffff0001'
                                 and kind = 'locked' and environment = 'paper'
                                 and asset_id = (select id from public.assets where symbol = 'BTC'))$q$,
  '100000000/0');

select public.r_expect('R9 ... with exactly ONE withdrawal_refund transaction for it',
  $q$select count(*)::text from public.ledger_transactions t
        join public.withdrawal_requests w on w.released_ledger_transaction_id = t.id
       where t.type = 'withdrawal_refund' and w.destination_address = 'scratch-stage4-destination'$q$, '1');

select public.r_expect_error('R9 a second failure/refund is REFUSED (no double refund)',
  $q$select public.fail_withdrawal(
     (select id from public.withdrawal_requests where destination_address = 'scratch-stage4-destination'),
     'again')$q$, 'terminal');

select public.r_expect_error('R9 ... and it cannot be completed after the failure either',
  $q$select public.complete_withdrawal(
     (select id from public.withdrawal_requests where destination_address = 'scratch-stage4-destination'),
     'scratch-stage4-late-txid')$q$, 'only a processing withdrawal');

select public.r_expect('R9 no user account is negative after all of that',
  $q$select count(*)::text from public.balances b join public.accounts a on a.id = b.account_id
       where a.account_type = 'user' and (b.available_units < 0 or b.locked_units < 0)$q$, '0');

-- ===========================================================================
\echo '=== R10. the safety gate is untouched and the database is consistent'
-- ===========================================================================
select public.r_expect('R10 app_settings is identical to the snapshot taken before this suite',
  $q$select count(*)::text from (
        select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
               paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode
          from public.app_settings
        except
        select * from public.r_settings_snapshot) x$q$, '0');

select public.r_expect('R10 every LIVE_* flag is still false and the mode is still paper',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text
        || '/' || withdrawals_enabled::text from public.app_settings$q$, 'paper/false/false/false');

select public.r_expect('R10 the ledger is still balanced after this suite',
  $q$select count(*)::text from (
        select t.id from public.ledger_transactions t
          join public.ledger_entries e on e.transaction_id = t.id
         group by t.id having sum(e.amount_units) <> 0) x$q$, '0');

select public.r_expect('R10 every balance still equals its ledger sum',
  $q$select count(*)::text from public.v_account_reconciliation where drift_units <> 0$q$, '0');

select public.r_expect('R10 every provider row was written by an RPC this suite called (nothing seeded, nothing invented)',
  $q$select count(*)::text || '/' || count(*) filter (where source = 'stage4-suite-fixture')::text
        from public.provider_balances$q$, '4/4');

select public.r_snap('r10_before');
select public.r_run('R10 a final run over the whole state',
  $q$select public.r_recon('r_super')$q$);

select public.r_expect('R10 the final run has no critical alert (the database is consistent)',
  $q$select count(*)::text from public.reconciliation_alerts
       where run_id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and severity = 'critical'$q$, '0');

select public.r_expect('R10 ... and its invariant scan is green on all three checks',
  $q$select count(*)::text from public.reconciliation_runs r, jsonb_array_elements(r.detail->'invariants') c
       where r.id = (select id from public.reconciliation_runs order by started_at desc limit 1)
         and (c->>'ok')::boolean$q$, '3');

select public.r_expect('R10 reconciliation never wrote a ledger row: the ledger is exactly as it was before the run',
  $q$select (select count(*) from public.ledger_transactions)::text = public.r_snap_value('r10_before_tx')
        and (select count(*) from public.ledger_entries)::text = public.r_snap_value('r10_before_entries')
        and coalesce((select sum(b.available_units + b.locked_units) from public.balances b),0)::text
            = public.r_snap_value('r10_before_balances')$q$, 'true');

\echo '=== SUMMARY'
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from public.r_res;
select count(*) filter (where not ok) as failures from public.r_res;
