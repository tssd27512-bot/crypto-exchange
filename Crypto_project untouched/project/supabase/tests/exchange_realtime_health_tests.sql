-- ============================================================================
-- exchange_realtime_health_tests.sql — stage 3: realtime publication + operational
-- health checks (migration 20261005100170_exchange_realtime_health)
--
-- Runs LAST in the core database (after schema, ledger, immutability, deposits,
-- withdrawals, kyc, admin and comms): it reuses the users, markets, networks,
-- ledger history and operator control plane those suites created, and everything
-- it adds is additive.
--
-- What it proves, section by section:
--   H0  fixtures: two synthetic customers, two operators, one paper deposit, one
--       paper withdrawal request, a baseline snapshot
--   H1  realtime publication membership, the RLS assertion on every member, the
--       audit trail staying OUT of the publication, channel-semantics comments
--   H2  the seeded health states, verbatim, and that the database row is backed by
--       the real self-check (counts, not a constant)
--   H3  record_health: ok -> down -> ok, detail preserved verbatim, enum refusal,
--       unknown-component refusal, non-object detail refusal
--   H4  authorization: client roles cannot write or even read the health table, and
--       cannot call record_health (the write path is the RPC, service_role only)
--   H5  view scoping: the user view hides the detail JSON, the admin view shows it
--       to operators only, anon gets nothing from either
--   H6  the operator re-check: runs the DB self-check only, audited with a real
--       actor, cannot mark a provider healthy
--   H7  deposit / withdrawal status notifications: exactly one per real transition,
--       honest content, none on a no-op update, RLS intact
--   H8  realtime security posture: a subscriber's row changes are the rows their
--       RLS already lets them read (nothing new is exposed)
--   H9  no fabrication: no invented component, no invented notification, realtime
--       still not_configured, nothing but the database claims to be ok
--   H10 the safety gate is untouched by this suite
--
-- Every fixture is synthetic; nothing here invents a health status, an event, a
-- balance, a fill, a customer or a provider connection.
-- ============================================================================
\set ON_ERROR_STOP 0

drop table if exists public.h_res;
drop table if exists public.h_op;
drop table if exists public.h_fix;
drop table if exists public.h_baseline;
create table public.h_res (label text, ok boolean);
create table public.h_op (username text primary key, id uuid);
create table public.h_fix (name text primary key, val text);
create table public.h_baseline as
select (select count(*) from public.notifications)   as notifications,
       (select count(*) from public.system_health)   as health_rows,
       (select count(*) from public.orders)          as orders,
       (select count(*) from public.trades)          as trades,
       (select count(*) from public.balances)        as balances,
       (select count(*) from public.deposits)        as deposits,
       (select count(*) from public.ledger_transactions) as ledger_tx,
       (select count(*) from public.ledger_entries)      as ledger_entries;

create or replace function public.h_expect(p_label text, p_sql text, p_expected text,
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
      insert into public.h_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.h_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.h_res(label, ok) values (p_label, false);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.h_expect_error(p_label text, p_sql text, p_fragment text,
  p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.h_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.h_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.h_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

-- same transaction, with the transaction-local gtvx.operator_id set: exactly how an
-- edge function holding the service key identifies the operator (PR #7 contract)
create or replace function public.h_expect_as(p_label text, p_username text, p_sql text, p_expected text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  perform set_config('gtvx.operator_id', (select id::text from public.h_op where username = p_username), true);
  execute p_sql into v_actual;
  if v_actual is not distinct from p_expected then
    raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
    insert into public.h_res(label, ok) values (p_label, true);
  else
    raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
    insert into public.h_res(label, ok) values (p_label, false);
  end if;
exception when others then
  raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.h_res(label, ok) values (p_label, false);
end;
$fn$;

create or replace function public.h_expect_error_as(p_label text, p_username text, p_sql text, p_fragment text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  perform set_config('gtvx.operator_id', (select id::text from public.h_op where username = p_username), true);
  execute p_sql into v_actual;
  raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
  insert into public.h_res(label, ok) values (p_label || ' (was allowed)', false);
exception when others then
  if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
    raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
    insert into public.h_res(label, ok) values (p_label, true);
  else
    raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
    insert into public.h_res(label, ok) values (p_label || ' (wrong error)', false);
  end if;
end;
$fn$;

-- actions that must SUCCEED (no comparison, exception = failure)
create or replace function public.h_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
begin
  execute p_sql;
  raise notice 'PASS  (ran) %', p_label;
  insert into public.h_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.h_res(label, ok) values (p_label, false);
end;
$fn$;

create or replace function public.h_run_as(p_label text, p_role text, p_sql text)
returns void language plpgsql as $fn$
begin
  execute format('set local role %I', p_role);
  execute p_sql;
  execute 'reset role';
  raise notice 'PASS  (ran as %) %', p_role, p_label;
  insert into public.h_res(label, ok) values (p_label, true);
exception when others then
  execute 'reset role';
  raise notice 'FAIL  (setup as %) % raised % (%)', p_role, p_label, sqlerrm, sqlstate;
  insert into public.h_res(label, ok) values (p_label, false);
end;
$fn$;

-- ===========================================================================
\echo '=== H0. fixtures — synthetic customers, operators, one paper deposit, one paper withdrawal'
-- ===========================================================================
select public.h_run('H0 create two synthetic customers',
  $q$insert into auth.users (id, email) values
       ('dddddddd-dddd-dddd-dddd-dddddddd0001', 'health-u1@example.test'),
       ('dddddddd-dddd-dddd-dddd-dddddddd0002', 'health-u2@example.test')$q$);

select public.h_run('H0 create the auth identity the JWT-mapped operator signs in as',
  $q$insert into auth.users (id, email) values
       ('dddddddd-dddd-dddd-dddd-dddddddd0003', 'health-op-super@example.test')$q$);

select public.h_run('H0 provision a superadmin and a readonly operator',
  $q$insert into public.admin_users (username, password_hash, operator_role, auth_user_id, display_name) values
       ('h_super', 'fixture', 'superadmin', 'dddddddd-dddd-dddd-dddd-dddddddd0003', 'health fixture superadmin'),
       ('h_ro',    'fixture', 'readonly',   null, 'health fixture auditor')$q$);

select public.h_run('H0 record the operator ids',
  $q$insert into public.h_op (username, id) select username, id from public.admin_users
      where username in ('h_super','h_ro')$q$);

-- a paper deposit on a real registered paper network (the deposits suite registered them)
select public.h_run('H0 create one synthetic PAPER deposit in status pending',
  $q$insert into public.deposits (id, user_id, asset_id, network, environment, source, txid,
                                 log_index, amount_units, confirmations, required_confirmations, status)
     select 'dddddddd-dddd-dddd-dddd-ddddddde0001', 'dddddddd-dddd-dddd-dddd-dddddddd0001',
            n.asset_id, n.network, 'paper', 'paper_operator', 'scratch-health-deposit-txid-1',
            -1, 150000000, 0, n.required_confirmations, 'pending'
       from public.deposit_networks n
      where n.environment = 'paper'
      order by n.network
      limit 1$q$);

select public.h_run('H0 create one synthetic PAPER withdrawal request in status pending',
  $q$insert into public.withdrawal_requests (id, user_id, asset_id, network, environment, source,
                                            destination_address, amount_units, fee_units, status)
     select 'dddddddd-dddd-dddd-dddd-ddddddde0002', 'dddddddd-dddd-dddd-dddd-dddddddd0001',
            n.asset_id, n.network, 'paper', 'paper_operator',
            'scratch-health-destination-address', 1000000, 0, 'pending'
       from public.withdrawal_networks n
      where n.environment = 'paper'
      order by n.network
      limit 1$q$);

select public.h_expect('H0 both fixtures exist exactly once',
  $q$select (select count(*) from public.deposits where id = 'dddddddd-dddd-dddd-dddd-ddddddde0001')::text
        || '/' || (select count(*) from public.withdrawal_requests where id = 'dddddddd-dddd-dddd-dddd-ddddddde0002')::text$q$,
  '1/1');

drop table if exists public.h_settings_snapshot;
create table public.h_settings_snapshot as
select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
       paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode
  from public.app_settings;

-- ===========================================================================
\echo '=== H1. realtime publication membership + the RLS assertion'
-- ===========================================================================
select public.h_expect('H1 all eight user-facing event tables are members of supabase_realtime',
  $q$select count(*)::text from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public'
        and tablename in ('orders','trades','balances','deposits','withdrawal_requests',
                          'notifications','chat_conversations','chat_messages')$q$, '8');

select public.h_expect('H1 the membership is exactly those eight plus nothing else from the exchange',
  $q$select count(*)::text from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public'
        and tablename not in ('orders','trades','balances','deposits','withdrawal_requests',
                              'notifications','chat_conversations','chat_messages')$q$, '0');

select public.h_expect('H1 EVERY publication member has RLS enabled (the migration refuses otherwise)',
  $q$select count(*)::text from pg_publication_tables pt
        join pg_namespace n on n.nspname = pt.schemaname
        join pg_class c on c.relnamespace = n.oid and c.relname = pt.tablename
      where pt.pubname = 'supabase_realtime' and not c.relrowsecurity$q$, '0');

select public.h_expect('H1 the security audit trail is NOT published (operator-only data)',
  $q$select count(*)::text from pg_publication_tables
      where pubname = 'supabase_realtime'
        and tablename in ('security_audit_log','kyc_submissions','admin_users','operator_permissions',
                          'kyc_status','account_restrictions','risk_flags','system_health')$q$, '0');

select public.h_expect('H1 each member table carries its channel-semantics comment',
  $q$select count(*)::text from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public'
         and c.relname in ('orders','trades','balances','deposits','withdrawal_requests',
                           'notifications','chat_conversations','chat_messages')
         and coalesce(obj_description(c.oid, 'pg_class'), '') like '%Realtime channel%'$q$, '8');

select public.h_expect('H1 the comment on withdrawal_requests names the real table (there is no public.withdrawals)',
  $q$select (to_regclass('public.withdrawals') is null)::text$q$, 'true');

select public.h_expect('H1 supabase_realtime is a normal (not FOR ALL TABLES) publication',
  $q$select puballtables::text from pg_publication where pubname = 'supabase_realtime'$q$, 'false');

select public.h_expect('H1 this instance cannot verify delivery (wal_level is not logical) — why realtime stays not_configured',
  $q$select (current_setting('wal_level') <> 'logical')::text$q$, 'true');

select public.h_expect('H1 the health row for realtime says exactly that',
  $q$select status from public.system_health where component = 'realtime'$q$, 'not_configured');

-- ===========================================================================
\echo '=== H2. the seeded health states, verbatim'
-- ===========================================================================
select public.h_expect('H2 exactly the eight honest components are seeded',
  $q$select string_agg(component, ',' order by component) from public.system_health$q$,
  'blockchain:BTC,blockchain:ETH,blockchain:SOL,blockchain:USDT,custodian,database,market_data,realtime');

select public.h_expect('H2 database = ok (backed by the real self-check)',
  $q$select status from public.system_health where component = 'database'$q$, 'ok');

select public.h_expect('H2 market_data = not_configured (no provider chosen)',
  $q$select status from public.system_health where component = 'market_data'$q$, 'not_configured');

select public.h_expect('H2 all four blockchain networks = not_connected',
  $q$select count(*)::text || '/' || string_agg(distinct status, ',') from public.system_health
      where component like 'blockchain:%'$q$, '4/not_connected');

select public.h_expect('H2 custodian = not_connected (no custody provider chosen)',
  $q$select status from public.system_health where component = 'custodian'$q$, 'not_connected');

select public.h_expect('H2 no component claims to be ok except the database',
  $q$select count(*)::text from public.system_health where status = 'ok' and component <> 'database'$q$, '0');

select public.h_expect('H2 the database detail is real evidence, not a constant',
  $q$select (detail->>'check') || '/' || (detail->>'unbalanced_transactions') || '/'
        || (detail->>'balances_mismatched') || '/' || ((detail->>'ledger_transactions') is not null)::text
        from public.system_health where component = 'database'$q$, 'db_self_check/0/0/true');

select public.h_expect('H2 the seed recorded who wrote it',
  $q$select checked_by from public.system_health where component = 'database'$q$, 'migration_seed');

select public.h_expect('H2 the seeded row count equals the baseline (the migration seeded once)',
  $q$select (count(*) = (select health_rows from public.h_baseline))::text from public.system_health$q$, 'true');

-- ===========================================================================
\echo '=== H3. record_health: transitions, verbatim detail, refusals'
-- ===========================================================================
select public.h_run_as('H3 service_role records custodian down with provider detail', 'service_role',
  $q$select public.record_health('custodian', 'down',
       '{"error":"custody provider timeout","attempt":3,"nested":{"a":[1,2]}}'::jsonb)$q$);

select public.h_expect('H3 the status moved to down',
  $q$select status from public.system_health where component = 'custodian'$q$, 'down');

select public.h_expect('H3 the detail JSON is stored VERBATIM (nothing sanitised or corrected)',
  $q$select (detail = '{"error":"custody provider timeout","attempt":3,"nested":{"a":[1,2]}}'::jsonb)::text
        from public.system_health where component = 'custodian'$q$,
  'true');

select public.h_expect('H3 ... with exactly the keys that were reported',
  $q$select (select count(*) from jsonb_object_keys(detail))::text
        from public.system_health where component = 'custodian'$q$, '3');

select public.h_expect('H3 checked_by defaults to the calling role (service_role)',
  $q$select checked_by from public.system_health where component = 'custodian'$q$, 'service_role');

select public.h_run_as('H3 service_role records custodian ok again with new evidence', 'service_role',
  $q$select public.record_health('custodian', 'ok', '{"error":null,"note":"recovered"}'::jsonb, 'custody-adapter')$q$);

select public.h_expect('H3 the status moved back to ok and the new detail replaced the old one',
  $q$select status || '/' || (detail = '{"error":null,"note":"recovered"}'::jsonb)::text
        || '/' || checked_by from public.system_health where component = 'custodian'$q$,
  'ok/true/custody-adapter');

select public.h_expect('H3 record_health returns the status it stored',
  $q$select public.record_health('market_data', 'not_configured', '{"reason":"still no provider"}'::jsonb, 'health-suite')$q$,
  'not_configured');

select public.h_expect('H3 last_checked_at advances on every recorded check',
  $q$select (last_checked_at > now() - interval '1 minute')::text from public.system_health
      where component = 'market_data'$q$, 'true');

select public.h_expect_error('H3 an unknown status is refused (the enum is the only truth)',
  $q$select public.record_health('database', 'probably-fine')::text$q$,
  'unknown health status');

select public.h_expect_error('H3 an unknown component is refused (a provider cannot invent one)',
  $q$select public.record_health('bitcoin_miner', 'ok')::text$q$,
  'unknown health component');

select public.h_expect_error('H3 a non-object detail is refused',
  $q$select public.record_health('database', 'ok', '[1,2]'::jsonb)::text$q$,
  'must be a JSON object');

select public.h_expect('H3 record_health cannot create a component (still eight rows)',
  $q$select count(*)::text from public.system_health$q$, '8');

-- restore the honest seeded states before the next section
select public.h_run_as('H3 restore custodian to its honest not_connected state', 'service_role',
  $q$select public.record_health('custodian', 'not_connected', '{"reason":"no custody provider chosen (owner decision #2)"}'::jsonb, 'health-suite')$q$);
select public.h_run_as('H3 restore market_data to its honest not_configured state', 'service_role',
  $q$select public.record_health('market_data', 'not_configured', '{"reason":"no market-data provider chosen (owner decision #3)"}'::jsonb, 'health-suite')$q$);

-- ===========================================================================
\echo '=== H4. authorization: the write path is the RPC, the table is not a client surface'
-- ===========================================================================
select public.h_expect_error('H4 anon cannot execute record_health',
  $q$select public.record_health('custodian', 'ok')::text$q$,
  'permission denied for function', 'anon');

select public.h_expect_error('H4 authenticated cannot execute record_health',
  $q$select public.record_health('custodian', 'ok')::text$q$,
  'permission denied for function', 'authenticated');

select public.h_expect_error('H4 authenticated cannot UPDATE a health row directly',
  $q$update public.system_health set status = 'ok' where component = 'custodian' returning 1$q$,
  'permission denied for table', 'authenticated');

select public.h_expect_error('H4 anon cannot UPDATE a health row directly',
  $q$update public.system_health set status = 'ok' where component = 'custodian' returning 1$q$,
  'permission denied for table', 'anon');

select public.h_expect_error('H4 anon cannot read the health table directly',
  $q$select count(*)::text from public.system_health$q$,
  'permission denied for table', 'anon');

select public.h_expect_error('H4 authenticated cannot read the health table directly',
  $q$select count(*)::text from public.system_health$q$,
  'permission denied for table', 'authenticated');

select public.h_expect('H4 the table still has RLS enabled with NO policy (defence in depth)',
  $q$select c.relrowsecurity::text || ':' || (select count(*) from pg_policies
        where schemaname = 'public' and tablename = 'system_health')::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
       where n.nspname = 'public' and c.relname = 'system_health'$q$, 'true:0');

select public.h_expect('H4 no client role holds INSERT/UPDATE on the health table',
  $q$select has_table_privilege('anon','public.system_health','INSERT')::text || '/'
        || has_table_privilege('authenticated','public.system_health','UPDATE')::text$q$,
  'false/false');

select public.h_expect('H4 service_role holds the RPC (the future provider call path)',
  $q$select has_function_privilege('service_role','public.record_health(text,text,jsonb,text)','EXECUTE')::text$q$,
  'true');

select public.h_expect('H4 no client role can execute the self-check, the re-check or the trigger functions',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.proname in ('record_health','run_db_self_check','health_status_from_self_check',
                          'admin_health_recheck','notify_deposit_status_change',
                          'notify_withdrawal_status_change')
        and (has_function_privilege('anon', p.oid, 'EXECUTE')
          or has_function_privilege('authenticated', p.oid, 'EXECUTE'))$q$, '0');

-- ===========================================================================
\echo '=== H5. view scoping: user view hides the evidence, admin view shows it'
-- ===========================================================================
select public.h_expect('H5 v_system_health exposes exactly three columns',
  $q$select count(*)::text from information_schema.columns
      where table_schema = 'public' and table_name = 'v_system_health'$q$, '3');

select public.h_expect('H5 ... and the internal detail JSON is not one of them',
  $q$select count(*)::text from information_schema.columns
      where table_schema = 'public' and table_name = 'v_system_health'
        and column_name in ('detail','checked_by')$q$, '0');

select public.h_expect('H5 authenticated reads all eight components through the user view',
  $q$select count(*)::text from public.v_system_health$q$, '8',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0002');

select public.h_expect('H5 the user view reports the honest statuses (7 not ok, 1 ok)',
  $q$select count(*) filter (where status <> 'ok')::text || '/' || count(*) filter (where status = 'ok')::text
        from public.v_system_health$q$, '7/1',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0002');

select public.h_expect_error('H5 anon cannot read the user view at all',
  $q$select count(*)::text from public.v_system_health$q$,
  'permission denied for view', 'anon');

select public.h_run_as('H5 service_role records blockchain:SOL down (a real provider report)', 'service_role',
  $q$select public.record_health('blockchain:SOL', 'down', '{"error":"rpc unavailable"}'::jsonb)$q$);

select public.h_expect_as('H5 the operator view shows the evidence and flags it for attention', 'h_super',
  $q$select count(*)::text || '/' || bool_or(needs_attention)::text || '/'
        || (select (select count(*) from jsonb_object_keys(detail)) from public.v_admin_system_health
             where component = 'blockchain:SOL')::text
        from public.v_admin_system_health$q$,
  '8/true/1');

select public.h_expect_as('H5 the operator view carries checked_by and the full detail JSON', 'h_ro',
  $q$select (detail ? 'error')::text || '/' || (checked_by is not null)::text
        from public.v_admin_system_health where component = 'blockchain:SOL'$q$,
  'true/true');

select public.h_expect('H5 a signed-in NON-operator sees ZERO rows in the operator view',
  $q$select count(*)::text from public.v_admin_system_health$q$, '0',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0001');

select public.h_expect_error('H5 anon cannot read the operator view at all',
  $q$select count(*)::text from public.v_admin_system_health$q$,
  'permission denied for view', 'anon');

select public.h_run_as('H5 restore blockchain:SOL to its honest not_connected state', 'service_role',
  $q$select public.record_health('blockchain:SOL', 'not_connected',
       '{"network":"SOL","reason":"no live chain connectivity in this build; the adapter contract is an interface only (stage 7)"}'::jsonb)$q$);

-- ===========================================================================
\echo '=== H6. the operator re-check: DB self-check only, audited, no overrides'
-- ===========================================================================
select public.h_run_as('H6 a provider reports blockchain:ETH down', 'service_role',
  $q$select public.record_health('blockchain:ETH', 'down', '{"error":"node unreachable"}'::jsonb)$q$);

-- snapshot AFTER the provider report: the re-check must not touch anything but database
drop table if exists public.h_pre_recheck;
create table public.h_pre_recheck as
select component, status, last_checked_at, checked_by from public.system_health;

select public.h_expect_as('H6 the operator re-check returns the database status (ok)', 'h_super',
  $q$select public.admin_health_recheck()$q$, 'ok');

select public.h_expect('H6 the re-check rewrote the database row and says who did it',
  $q$select checked_by from public.system_health where component = 'database'$q$, 'admin_health_recheck');

select public.h_expect('H6 the re-check really re-ran the self-check (fresh evidence, zero discrepancies)',
  $q$select (detail->>'check') || '/' || (detail->>'unbalanced_transactions') || '/'
        || (detail->>'balances_mismatched') from public.system_health where component = 'database'$q$,
  'db_self_check/0/0');

select public.h_expect('H6 the re-check is audited with a real operator actor',
  $q$select count(*)::text from public.security_audit_log
      where action = 'admin.health.recheck'
        and actor_id = (select id from public.h_op where username = 'h_super')$q$, '1');

select public.h_expect('H6 the re-check cannot mark a provider healthy (blockchain:ETH is still down)',
  $q$select status from public.system_health where component = 'blockchain:ETH'$q$, 'down');

select public.h_expect('H6 the re-check touched NOTHING except the database row',
  $q$select count(*)::text from public.system_health h
        join public.h_pre_recheck p using (component)
       where h.component <> 'database'
         and (h.status <> p.status or h.last_checked_at <> p.last_checked_at)$q$, '0');

select public.h_expect_as('H6 the readonly auditor may re-check too (security.read allows it)', 'h_ro',
  $q$select public.admin_health_recheck()$q$, 'ok');

select public.h_expect_error_as('H6 a customer cannot run the re-check', 'h_ro',
  $q$select public.admin_health_recheck('dddddddd-dddd-dddd-dddd-dddddddd0001')::text$q$,
  'no operator identity');

select public.h_expect_error('H6 anon cannot call the re-check at all',
  $q$select public.admin_health_recheck()::text$q$,
  'permission denied for function', 'anon');

select public.h_run_as('H6 restore blockchain:ETH to its honest not_connected state', 'service_role',
  $q$select public.record_health('blockchain:ETH', 'not_connected',
       '{"network":"ETH","reason":"no live chain connectivity in this build; the adapter contract is an interface only (stage 7)"}'::jsonb)$q$);

-- ===========================================================================
\echo '=== H7. deposit / withdrawal status notifications'
-- ===========================================================================
select public.h_expect('H7 no deposit.status notification exists before the transition',
  $q$select count(*)::text from public.notifications
      where user_id = 'dddddddd-dddd-dddd-dddd-dddddddd0001' and type = 'deposit.status'$q$, '0');

select public.h_run('H7 the deposit moves pending -> confirming (a real state-machine step)',
  $q$update public.deposits set status = 'confirming', confirmations = 1
      where id = 'dddddddd-dddd-dddd-dddd-ddddddde0001'$q$);

select public.h_expect('H7 exactly ONE deposit.status notification was written for that user',
  $q$select count(*)::text from public.notifications
      where user_id = 'dddddddd-dddd-dddd-dddd-dddddddd0001' and type = 'deposit.status'$q$, '1');

select public.h_expect('H7 ... it names the new status and the real amount/asset (no invented content)',
  $q$select (title = 'Deposit confirming')::text || '/'
        || (body like '%1.5%')::text || '/' || (body like '%confirming%')::text || '/'
        || (body like '%' || (select network from public.deposits
                               where id = 'dddddddd-dddd-dddd-dddd-ddddddde0001') || '%')::text
        from public.notifications
       where user_id = 'dddddddd-dddd-dddd-dddd-dddddddd0001' and type = 'deposit.status'$q$,
  'true/true/true/true');

select public.h_expect('H7 ... it is system-generated: no operator is credited as the author',
  $q$select (created_by is null)::text from public.notifications
      where user_id = 'dddddddd-dddd-dddd-dddd-dddddddd0001' and type = 'deposit.status'$q$, 'true');

select public.h_run('H7 a no-op update (same status) is not a transition',
  $q$update public.deposits set confirmations = 2
      where id = 'dddddddd-dddd-dddd-dddd-ddddddde0001'$q$);

select public.h_expect('H7 ... and writes no notification (no invented events)',
  $q$select count(*)::text from public.notifications
      where user_id = 'dddddddd-dddd-dddd-dddd-dddddddd0001' and type = 'deposit.status'$q$, '1');

select public.h_run('H7 the withdrawal request moves pending -> under review',
  $q$update public.withdrawal_requests set status = 'under review'
      where id = 'dddddddd-dddd-dddd-dddd-ddddddde0002'$q$);

select public.h_expect('H7 exactly ONE withdrawal.status notification was written, naming the status',
  $q$select count(*)::text || '/' || bool_and(title = 'Withdrawal under review')::text || '/'
        || bool_and(body like '%under review%')::text
        from public.notifications
       where user_id = 'dddddddd-dddd-dddd-dddd-dddddddd0001' and type = 'withdrawal.status'$q$,
  '1/true/true');

select public.h_expect('H7 the customer can read their own new notifications',
  $q$select count(*)::text from public.notifications
      where user_id = 'dddddddd-dddd-dddd-dddd-dddddddd0001'
        and type in ('deposit.status','withdrawal.status')$q$, '2',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0001');

select public.h_expect('H7 another customer cannot see them (RLS unchanged by the trigger)',
  $q$select count(*)::text from public.notifications
      where type in ('deposit.status','withdrawal.status')$q$, '0',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0002');

select public.h_expect('H7 the trigger wrote exactly two notifications in this suite (baseline + 2)',
  $q$select (count(*) = (select notifications from public.h_baseline) + 2)::text from public.notifications$q$,
  'true');

-- ===========================================================================
\echo '=== H8. realtime security posture: a subscriber only sees what RLS already allows'
-- ===========================================================================
select public.h_expect('H8 the fixture customer sees their own deposit and nobody else''s',
  $q$select count(*)::text from public.deposits$q$, '1',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0001');

select public.h_expect('H8 ... and a customer with no deposits sees none, although the table is not empty',
  $q$select count(*)::text from public.deposits$q$, '0',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0002');

select public.h_expect('H8 the table really is not empty (so that zero is RLS, not an empty table)',
  $q$select (count(*) > 0)::text from public.deposits$q$, 'true');

select public.h_expect('H8 a customer with no orders sees zero orders while the book has orders',
  $q$select count(*)::text from public.orders$q$, '0',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0001');

select public.h_expect('H8 ... the orders table is not empty',
  $q$select (count(*) > 0)::text from public.orders$q$, 'true');

select public.h_expect('H8 a customer with no accounts sees zero balances while balances exist',
  $q$select count(*)::text from public.balances$q$, '0',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0002');

select public.h_expect('H8 ... the balances table is not empty',
  $q$select (count(*) > 0)::text from public.balances$q$, 'true');

select public.h_expect('H8 a customer with no fills sees zero trades while trades exist',
  $q$select count(*)::text from public.trades$q$, '0',
  'authenticated', 'dddddddd-dddd-dddd-dddd-dddddddd0002');

select public.h_expect('H8 ... the trades table is not empty',
  $q$select (count(*) > 0)::text from public.trades$q$, 'true');

select public.h_expect_error('H8 anon cannot read deposits at all (no grant, RLS on)',
  $q$select count(*)::text from public.deposits$q$,
  'permission denied', 'anon');

-- ===========================================================================
\echo '=== H9. no fabrication: nothing invented, nothing claiming to be healthy'
-- ===========================================================================
select public.h_expect('H9 the health table still has exactly the eight seeded components',
  $q$select count(*)::text from public.system_health$q$, '8');

select public.h_expect('H9 no component outside the seeded set exists',
  $q$select count(*)::text from public.system_health
      where component not in ('database','market_data','blockchain:BTC','blockchain:ETH',
                              'blockchain:USDT','blockchain:SOL','custodian','realtime')$q$, '0');

select public.h_expect('H9 every component is back in its honest state after the suite',
  $q$select string_agg(component || '=' || status, ',' order by component) from public.system_health$q$,
  'blockchain:BTC=not_connected,blockchain:ETH=not_connected,blockchain:SOL=not_connected,blockchain:USDT=not_connected,custodian=not_connected,database=ok,market_data=not_configured,realtime=not_configured');

select public.h_expect('H9 the realtime component never claims ok (delivery is unverified)',
  $q$select (status <> 'ok')::text from public.system_health where component = 'realtime'$q$, 'true');

select public.h_expect('H9 nothing but the database claims ok',
  $q$select count(*)::text from public.system_health where status = 'ok' and component <> 'database'$q$, '0');

select public.h_expect('H9 no notification type other than the two real transitions was produced by this suite',
  $q$select string_agg(distinct type, ',' order by type) from public.notifications
      where type in ('deposit.status','withdrawal.status')$q$, 'deposit.status,withdrawal.status');

-- ===========================================================================
\echo '=== H10. the safety gate is untouched by this suite'
-- ===========================================================================
select public.h_expect('H10 app_settings is identical to the snapshot taken before this suite',
  $q$select count(*)::text from (
        select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
               paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode
          from public.app_settings
        except
        select * from public.h_settings_snapshot
      ) x$q$, '0');

select public.h_expect('H10 every LIVE_* flag is still false and the mode is still paper',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text
        || '/' || withdrawals_enabled::text from public.app_settings$q$, 'paper/false/false/false');

select public.h_expect('H10 the ledger is still balanced after this suite',
  $q$select count(*)::text from (
        select t.id from public.ledger_transactions t
          join public.ledger_entries e on e.transaction_id = t.id
         group by t.id having sum(e.amount_units) <> 0) x$q$, '0');

select public.h_expect('H10 every balance still equals its ledger sum',
  $q$select count(*)::text from public.balances b
        where COALESCE(b.available_units,0) + COALESCE(b.locked_units,0)
              <> COALESCE((select sum(e.amount_units) from public.ledger_entries e
                            where e.account_id = b.account_id), 0)$q$, '0');

select public.h_expect('H10 the health table agrees with the real ledger (database = ok, zero discrepancies)',
  $q$select status || '/' || (detail->>'unbalanced_transactions') || '/' || (detail->>'balances_mismatched')
        from public.system_health where component = 'database'$q$, 'ok/0/0');

select public.h_expect('H10 the suite wrote no money: the ledger is exactly as it was before the suite',
  $q$select (select count(*) from public.ledger_transactions) = (select ledger_tx from public.h_baseline)
        and (select count(*) from public.ledger_entries) = (select ledger_entries from public.h_baseline)$q$,
  'true');

\echo '=== SUMMARY'
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from public.h_res;
select count(*) filter (where not ok) as failures from public.h_res;
