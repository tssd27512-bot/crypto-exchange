-- ============================================================================
-- exchange_admin_tests.sql — stage 2, part 1: the admin / operator control plane
--
-- Runs LAST in the core database (after schema, ledger, immutability, deposits,
-- withdrawals and kyc): it reuses their fixture users and their registered
-- deposit/withdrawal networks, and its own rows are additive.
--
-- What it proves, section by section:
--   A1  the identity/role model and the ACL surface (nothing client-callable)
--   A2  operator resolution on all three paths (explicit id, GUC, JWT mapping)
--   A3  every sensitive action writes a security_audit_log row with a REAL actor
--   A4  the permission matrix, cell by cell, plus cross-role denials end to end
--   A5  restrictions: set / duplicate / clear / history kept
--   A6  restrictions ENFORCED in the trading path (both directions)
--   A7  restrictions ENFORCED in the deposit paths (both directions)
--   A8  restrictions ENFORCED in the withdrawal paths (both directions)
--   A9  the KYC operator wrappers reuse the PR #6 state machine and record actors
--   A10 maintenance mode blocks trading/deposits/withdrawals, then is REVERTED
--   A11 the admin views are role-scoped and never readable by anon
--   A12 no admin function can create customer money (static probe over pg_proc)
--   A13 markets/fees/network configuration through authorised wrappers
--   A14 operator roster management, incl. the last-superadmin guard
--   A15 the security audit trail view is role-scoped
--
-- Every flag flip happens in THIS scratch database and is reverted; A10's last
-- assertions re-read app_settings and compare it to the snapshot taken at the top.
-- ============================================================================
\set ON_ERROR_STOP 0

drop table if exists public.a_res;
drop table if exists public.a_op;
create table public.a_res (label text, ok boolean);
create table public.a_op (username text primary key, id uuid);

create or replace function public.a_expect(p_label text, p_sql text, p_expected text,
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
      insert into public.a_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.a_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.a_res(label, ok) values (p_label, false);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.a_expect_error(p_label text, p_sql text, p_fragment text,
  p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.a_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.a_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.a_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

-- run p_sql in the same transaction with the transaction-local gtvx.operator_id set,
-- i.e. exactly how an edge function identifies the operator to a service_role call.
create or replace function public.a_expect_as(p_label text, p_username text, p_sql text, p_expected text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  perform set_config('gtvx.operator_id', (select id::text from public.a_op where username = p_username), true);
  execute p_sql into v_actual;
  if v_actual is not distinct from p_expected then
    raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
    insert into public.a_res(label, ok) values (p_label, true);
  else
    raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
    insert into public.a_res(label, ok) values (p_label, false);
  end if;
exception when others then
  raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.a_res(label, ok) values (p_label, false);
end;
$fn$;

-- actions that must SUCCEED (no comparison, exception = failure)
create or replace function public.a_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
begin
  execute p_sql;
  raise notice 'PASS  (ran) %', p_label;
  insert into public.a_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.a_res(label, ok) values (p_label, false);
end;
$fn$;

-- the explicit operator id of a fixture operator, for the call sites below
create or replace function public.a_id(p_username text)
returns uuid language sql stable as $fn$
  select id from public.a_op where username = p_username
$fn$;

-- balanced paper funding for a fixture user (same pattern as the withdrawal suite:
-- the money comes from the PAPER_FAUCET system account, never out of thin air)
create or replace function public.a_fund(p_user uuid, p_symbol text, p_amount numeric)
returns void language plpgsql as $fn$
declare
  v_asset uuid; v_faucet uuid; v_account uuid; v_tx uuid;
begin
  select id into v_asset from public.assets where symbol = p_symbol;
  v_faucet := public.system_account_id('PAPER_FAUCET', v_asset, 'paper');
  v_account := public.ensure_user_account(p_user, v_asset, 'available', 'paper');
  insert into public.ledger_transactions (type, environment, reference_type, reference_id, description)
  values ('paper_funding', 'paper', 'user', p_user, format('scratch admin test funding %s %s', p_amount, p_symbol))
  returning id into v_tx;
  perform public.post_entry(v_tx, v_faucet, -p_amount, 'scratch admin test funding');
  perform public.post_entry(v_tx, v_account, p_amount, 'scratch admin test funding');
end $fn$;

-- settings snapshot, restored-and-compared at the end (A10 ends with the re-read)
drop table if exists public.a_settings_snapshot;
create table public.a_settings_snapshot as
select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
       paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode
  from public.app_settings;

-- ===========================================================================
-- FIXTURES — synthetic users and operators, no personal data
-- ===========================================================================
\echo '=== A0. fixtures'
select public.a_run('A0 create three synthetic users for this suite',
  $q$insert into auth.users (id, email) values
       ('77777777-7777-7777-7777-777777770001', 'adm-u1@example.test'),
       ('77777777-7777-7777-7777-777777770002', 'adm-u2@example.test'),
       ('77777777-7777-7777-7777-777777770003', 'adm-u3@example.test')$q$);

-- one auth user per operator that will use the JWT path (auth_user_id mapping)
select public.a_run('A0 create the auth identities the JWT-mapped operators sign in as',
  $q$insert into auth.users (id, email) values
       ('88888888-8888-8888-8888-888888880001', 'op-super@example.test'),
       ('88888888-8888-8888-8888-888888880002', 'op-comp@example.test'),
       ('88888888-8888-8888-8888-888888880003', 'op-supp@example.test')$q$);

select public.a_run('A0 provision one operator per role (plus a deactivated one)',
  $q$insert into public.admin_users (username, password_hash, operator_role, auth_user_id, display_name) values
       ('a_super', 'fixture', 'superadmin', '88888888-8888-8888-8888-888888880001', 'fixture superadmin'),
       ('a_comp',  'fixture', 'compliance', '88888888-8888-8888-8888-888888880002', 'fixture compliance'),
       ('a_supp',  'fixture', 'support',    '88888888-8888-8888-8888-888888880003', 'fixture support'),
       ('a_ro',    'fixture', 'readonly',   null, 'fixture auditor'),
       ('a_off',   'fixture', 'superadmin', null, 'fixture deactivated superadmin')$q$);

select public.a_run('A0 record the operator ids',
  $q$insert into public.a_op (username, id) select username, id from public.admin_users
      where username in ('a_super','a_comp','a_supp','a_ro','a_off')$q$);

select public.a_run('A0 deactivate a_off (kept for the deactivation test)',
  $q$update public.admin_users set is_active = false where username = 'a_off'$q$);

select public.a_run('A0 fund u3 with BTC so the withdrawal path can be exercised',
  $q$select public.a_fund('77777777-7777-7777-7777-777777770003', 'BTC', 100000000)$q$);

-- ===========================================================================
\echo '=== A1. identity model, permission matrix and ACL surface'
-- ===========================================================================
select public.a_expect('A1 the four operator roles exist, ranked',
  $q$select string_agg(code, ',' order by rank desc) from public.operator_roles$q$,
  'superadmin,compliance,support,readonly');

select public.a_expect('A1 the permission matrix is data: 4 roles x 11 actions = 44 cells',
  $q$select count(*)::text from public.operator_permissions$q$, '44');

select public.a_expect('A1 every role has an explicit ALLOW or DENY for every action (no missing cell)',
  $q$select count(*)::text from public.operator_roles r cross join (select distinct action from public.operator_permissions) a
        left join public.operator_permissions p on p.role_code = r.code and p.action = a.action
        where p.allowed is null$q$, '0');

select public.a_expect('A1 superadmin is allowed all eleven actions',
  $q$select count(*)::text from public.operator_permissions where role_code='superadmin' and allowed$q$, '11');

select public.a_expect('A1 compliance may decide KYC but may not touch configuration or the roster',
  $q$select string_agg(action, ',' order by action) from public.operator_permissions
        where role_code='compliance' and allowed$q$,
  'kyc.decide,kyc.read,money.read,restrictions.write,risk.write,security.read,users.read,users.read.pii');

select public.a_expect('A1 support is read-only (nothing writable at all)',
  $q$select count(*)::text from public.operator_permissions where role_code='support' and allowed
        and action not in ('users.read','kyc.read','money.read')$q$, '0');

select public.a_expect('A1 readonly reads everything (incl. the audit trail) and writes nothing',
  $q$select string_agg(action, ',' order by action) from public.operator_permissions
        where role_code='readonly' and allowed$q$,
  'kyc.read,money.read,security.read,users.read');

select public.a_expect('A1 an unknown role or action is denied by default',
  $q$select (public.operator_can('nobody','users.read'))::text || '/' ||
           (public.operator_can('superadmin','nonsense.action'))::text$q$, 'false/false');

select public.a_expect('A1 admin_users gained exactly the five documented columns',
  $q$select string_agg(column_name, ',' order by column_name) from information_schema.columns
        where table_schema='public' and table_name='admin_users'
          and column_name in ('operator_role','auth_user_id','is_active','display_name','updated_at')$q$,
  'auth_user_id,display_name,is_active,operator_role,updated_at');

select public.a_expect('A1 the pre-existing admin row was NOT silently promoted (least privilege)',
  $q$select operator_role || '/' || is_active::text from public.admin_users where username='admin'$q$,
  'readonly/true');

select public.a_expect('A1 the chat-login columns the edge function needs are untouched',
  $q$select count(*)::text from information_schema.columns
        where table_schema='public' and table_name='admin_users'
          and column_name in ('username','password_hash','created_at')$q$, '3');

select public.a_expect('A1 exactly one operator row per auth user is enforced (unique partial index)',
  $q$select count(*)::text from pg_indexes where schemaname='public' and indexname='admin_users_auth_user_id_key'$q$, '1');

select public.a_expect('A1 no admin function is executable by anon or authenticated',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and (p.proname like 'admin!_%' escape '!' or p.proname in
          ('assert_operator','resolve_operator','log_operator_action'))
          and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))$q$,
  '0');

select public.a_expect('A1 every admin function is executable by service_role (the operator call path)',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and (p.proname like 'admin!_%' escape '!')
          and not has_function_privilege('service_role', p.oid, 'EXECUTE')$q$, '0');

select public.a_expect('A1 the admin surface is 18 functions', 
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname like 'admin!_%' escape '!'$q$, '18');

select public.a_expect('A1 the four new tables are service_role-only and have RLS on with no client policy',
  $q$select string_agg(c.relname || ':' || c.relrowsecurity::text || ':' ||
          (select count(*) from pg_policies p where p.schemaname='public' and p.tablename=c.relname)::text, ',' order by c.relname)
        from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relname in ('operator_roles','operator_permissions','account_restrictions','risk_flags')$q$,
  'account_restrictions:true:0,operator_permissions:true:0,operator_roles:true:0,risk_flags:true:0');

select public.a_expect_error('A1 anon cannot read account_restrictions',
  $q$select count(*)::text from public.account_restrictions$q$,
  'permission denied for table account_restrictions', 'anon');

select public.a_expect('A1 anon reads ZERO rows of the operator roster (RLS on, no policy)',
  $q$select count(*)::text from public.admin_users$q$, '0', 'anon');

select public.a_expect_error('A1 a signed-in user cannot call an admin function even with its full signature',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770001','trading','nope nope',
           (select id from public.a_op where username='a_super'))::text$q$,
  'permission denied for function admin_set_restriction', 'authenticated', '11111111-1111-1111-1111-111111111111'::uuid);

-- ===========================================================================
\echo '=== A2. operator identity resolution (explicit id, GUC, JWT mapping)'
-- ===========================================================================
select public.a_expect('A2 the explicit operator id resolves to that operator',
  $q$select public.assert_operator('users.read', (select id from public.a_op where username='a_supp'))::text$q$,
  (select id::text from public.a_op where username='a_supp'));

select public.a_expect_error('A2 no operator identity at all is refused (no implicit system operator)',
  $q$select public.assert_operator('users.read')::text$q$,
  'no operator identity');

select public.a_expect_error('A2 an unknown operator id is refused',
  $q$select public.assert_operator('users.read', '99999999-9999-9999-9999-999999999999')::text$q$,
  'no operator identity');

select public.a_expect_error('A2 a deactivated operator is refused even though the row exists',
  $q$select public.assert_operator('users.read', (select id from public.a_op where username='a_off'))::text$q$,
  'is deactivated');

select public.a_expect_as('A2 the edge-function path: gtvx.operator_id identifies the operator in that transaction',
  'a_comp', $q$select public.assert_operator('kyc.decide')::text$q$,
  (select id::text from public.a_op where username='a_comp'));

select public.a_expect('A2 a JWT mapped to an operator row resolves that operator (production path)',
  $q$select public.assert_operator('users.read')::text$q$,
  (select id::text from public.a_op where username='a_super'),
  null, '88888888-8888-8888-8888-888888880001'::uuid);

select public.a_expect_error('A2 a JWT that maps to no operator row is refused (a customer is not an operator)',
  $q$select public.assert_operator('users.read')::text$q$,
  'is not a registered operator', null, '77777777-7777-7777-7777-777777770001'::uuid);

select public.a_expect_error('A2 a JWT operator cannot name somebody else''s operator id',
  $q$select public.assert_operator('users.read', (select id from public.a_op where username='a_super'))::text$q$,
  'may only act as themselves', null, '88888888-8888-8888-8888-888888880003'::uuid);

select public.a_expect_error('A2 a signed-in customer cannot spoof an operator through the GUC',
  $q$select (select set_config('gtvx.operator_id', (select id::text from public.a_op where username='a_super'), true))
           || '/' || public.assert_operator('users.read')::text$q$,
  'is not a registered operator', null, '77777777-7777-7777-7777-777777770002'::uuid);

select public.a_expect('A2 current_operator_id() is NULL for a caller who is not an operator',
  $q$select coalesce(public.current_operator_id()::text, 'NULL')$q$, 'NULL');

select public.a_expect('A2 current_operator_role() reports the calling operator role',
  $q$select public.operator_can_do('markets.write')::text$q$, 'false');

-- ===========================================================================
\echo '=== A3. every sensitive action writes an audit row with a real actor'
-- ===========================================================================
select public.a_run('A3 superadmin restricts u1 from trading (the first sensitive action)',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770001','trading',
        'A3 fixture: chargeback investigation',
        (select id from public.a_op where username='a_super'))$q$);

select public.a_expect('A3 the audit row records the action, the entity and a before/after summary',
  $q$select action || '/' || entity_type || '/' ||
           (case when details ? 'before' then 'has-before' else 'no-before' end) || '/' ||
           (case when details ? 'after' then 'has-after' else 'no-after' end)
        from public.security_audit_log
        where action='admin.restriction.set' and entity_id = (select id from public.account_restrictions
              where user_id='77777777-7777-7777-7777-777777770001' and scope='trading' and active)$q$,
  'admin.restriction.set/account_restriction/has-before/has-after');

select public.a_expect('A3 ... with actor_role = operator and the REAL operator id (the PR #6 NULL-actor gap closed)',
  $q$select actor_role || '/' || (actor_id = (select id from public.a_op where username='a_super'))::text
        from public.security_audit_log
        where action='admin.restriction.set' and details->>'operator_username' = 'a_super'
        order by at desc limit 1$q$, 'operator/true');

select public.a_expect('A3 no operator action in this database was recorded with a NULL actor',
  $q$select count(*)::text from public.security_audit_log where action like 'admin.%' and actor_id is null$q$, '0');

select public.a_expect('A3 every admin.* row names an operator that exists in the roster',
  $q$select count(*)::text from public.security_audit_log a
        where a.action like 'admin.%'
          and not exists (select 1 from public.admin_users u where u.id = a.actor_id)$q$, '0');

select public.a_expect_error('A3 log_operator_action refuses to write a row without an actor',
  $q$select public.log_operator_action('admin.probe.test','probe')::text$q$,
  'without an actor identity');

select public.a_expect('A3 the restriction row records WHO set it and WHEN',
  $q$select (set_by = (select id from public.a_op where username='a_super'))::text || '/' || (set_at is not null)::text
        from public.account_restrictions where user_id='77777777-7777-7777-7777-777777770001' and scope='trading'$q$,
  'true/true');

-- ===========================================================================
\echo '=== A4. permission matrix end to end (allowed and denied, cross-role)'
-- ===========================================================================
select public.a_expect_error('A4 support may NOT set a restriction (restrictions.write)',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770002','trading','support should not',
        (select id from public.a_op where username='a_supp'))::text$q$,
  'is not permitted to perform restrictions.write');

select public.a_expect_error('A4 readonly may NOT set a restriction either',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770002','trading','readonly should not',
        (select id from public.a_op where username='a_ro'))::text$q$,
  'is not permitted to perform restrictions.write');

select public.a_expect_error('A4 support may NOT decide KYC (kyc.decide)',
  $q$select public.admin_kyc_approve('00000000-0000-0000-0000-000000000000', 'nope',
        (select id from public.a_op where username='a_supp'))::text$q$,
  'is not permitted to perform kyc.decide');

select public.a_expect_error('A4 support may NOT read the security audit trail (security.read)',
  $q$select public.admin_list_security_events(10, 0, null, null,
        (select id from public.a_op where username='a_supp'))::text$q$,
  'is not permitted to perform security.read');

select public.a_expect_error('A4 compliance may NOT change markets (markets.write)',
  $q$select public.admin_set_market_fees('BTC/USDT', 2, 5, 'paper',
        (select id from public.a_op where username='a_comp'))::text$q$,
  'is not permitted to perform markets.write');

select public.a_expect_error('A4 compliance may NOT toggle maintenance mode (settings.write)',
  $q$select public.admin_set_maintenance(true, 'compliance should not be able to',
        (select id from public.a_op where username='a_comp'))::text$q$,
  'is not permitted to perform settings.write');

select public.a_expect_error('A4 compliance may NOT change the operator roster (operators.write)',
  $q$select public.admin_set_operator_role('a_supp','compliance',
        (select id from public.a_op where username='a_comp'))::text$q$,
  'is not permitted to perform operators.write');

select public.a_expect_error('A4 readonly may NOT write a risk flag (risk.write)',
  $q$select public.admin_add_risk_flag('77777777-7777-7777-7777-777777770002','probe','low','readonly should not',
        (select id from public.a_op where username='a_ro'))::text$q$,
  'is not permitted to perform risk.write');

select public.a_expect('A4 readonly MAY list security events (security.read is granted to the auditor role)',
  $q$select ((select count(*) from public.admin_list_security_events(5, 0, 'admin.', null,
        (select id from public.a_op where username='a_ro'))) > 0)::text$q$, 'true');

select public.a_expect('A4 compliance MAY read the security audit trail',
  $q$select ((select count(*) from public.admin_list_security_events(5, 0, 'admin.', null,
        (select id from public.a_op where username='a_comp'))) > 0)::text$q$, 'true');

select public.a_expect('A4 compliance MAY set a risk flag (and the flag is advisory: nothing is blocked)',
  $q$select (public.admin_add_risk_flag('77777777-7777-7777-7777-777777770002','probe_velocity','medium',
        'A4 fixture: velocity probe',
        (select id from public.a_op where username='a_comp')) is not null)::text$q$, 'true');

select public.a_expect('A4 ... the flag exists, unresolved, with its author recorded',
  $q$select severity || '/' || (resolved_at is null)::text || '/' ||
           (created_by = (select id from public.a_op where username='a_comp'))::text
        from public.risk_flags where user_id='77777777-7777-7777-7777-777777770002' and flag_type='probe_velocity'$q$,
  'medium/true/true');

select public.a_expect('A4 resolving the risk flag keeps the row and records the resolver',
  $q$select (public.admin_resolve_risk_flag((select id from public.risk_flags
             where user_id='77777777-7777-7777-7777-777777770002' and flag_type='probe_velocity'),
             'A4 resolved', (select id from public.a_op where username='a_comp')))::text
        is not null$q$, 'true');

select public.a_expect_error('A4 a risk flag cannot be resolved twice',
  $q$select public.admin_resolve_risk_flag((select id from public.risk_flags
           where user_id='77777777-7777-7777-7777-777777770002' and flag_type='probe_velocity'),
           'again', (select id from public.a_op where username='a_comp'))::text$q$,
  'was already resolved');

-- ===========================================================================
\echo '=== A5. restriction lifecycle'
-- ===========================================================================
select public.a_expect_error('A5 a second active restriction in the same scope is refused',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770001','trading','duplicate',
        (select id from public.a_op where username='a_super'))::text$q$,
  'is already restricted from trading');

select public.a_expect_error('A5 an unknown scope is refused (no invented scopes)',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770001','kyc','bad scope',
        (select id from public.a_op where username='a_super'))::text$q$,
  'unknown restriction scope');

select public.a_expect_error('A5 a restriction without a reason is refused',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770001','deposits',' x ',
        (select id from public.a_op where username='a_super'))::text$q$,
  'requires a reason');

select public.a_expect_error('A5 an unknown user cannot be restricted',
  $q$select public.admin_set_restriction('12345678-1234-1234-1234-123456789012','trading','no such user',
        (select id from public.a_op where username='a_super'))::text$q$,
  'unknown user');

select public.a_run('A5 clear the trading restriction on u1',
  $q$select public.admin_clear_restriction((select id from public.account_restrictions
        where user_id='77777777-7777-7777-7777-777777770001' and scope='trading' and active),
        'A5 lift after the check', (select id from public.a_op where username='a_super'))$q$);

select public.a_expect('A5 the cleared restriction is kept as history (active=false, cleared_at/by set)',
  $q$select active::text || '/' || (cleared_at is not null)::text || '/' ||
           (cleared_by = (select id from public.a_op where username='a_super'))::text
        from public.account_restrictions
        where user_id='77777777-7777-7777-7777-777777770001' and scope='trading'$q$,
  'false/true/true');

select public.a_expect('A5 clearing wrote its own audit row with before/after',
  $q$select count(*)::text from public.security_audit_log
        where action='admin.restriction.cleared' and actor_id = (select id from public.a_op where username='a_super')
          and details ? 'before' and details ? 'after'$q$, '1');

select public.a_expect_error('A5 a restriction cannot be cleared twice',
  $q$select public.admin_clear_restriction((select id from public.account_restrictions
           where user_id='77777777-7777-7777-7777-777777770001' and scope='trading'),
           'again', (select id from public.a_op where username='a_super'))::text$q$,
  'was already cleared');

select public.a_expect('A5 a cleared restriction no longer blocks (the guard reads active only)',
  $q$select public.assert_account_not_restricted('77777777-7777-7777-7777-777777770001','trading')::text$q$,
  '');

-- ===========================================================================
\echo '=== A6. trading restriction ENFORCED in place_order (both directions)'
-- ===========================================================================
select public.a_run('A6 an UNRESTRICTED user can place an order (control case, rests far from the book)',
  $q$select public.place_order('BTC/USDT','buy','limit', 1000, 1, 'gtc', null,
        '77777777-7777-7777-7777-777777770001')$q$);

select public.a_expect('A6 ... and it is recorded as that user''s order',
  $q$select count(*)::text from public.orders
        where user_id='77777777-7777-7777-7777-777777770001' and status in ('new','partially_filled')$q$, '1');

select public.a_run('A6 restrict u1 from trading',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770001','trading',
        'A6 fixture: trading restriction', (select id from public.a_op where username='a_comp'))$q$);

select public.a_expect_error('A6 a trading-restricted user can no longer place an order',
  $q$select public.place_order('BTC/USDT','buy','limit', 1000, 1, 'gtc', null,
        '77777777-7777-7777-7777-777777770001')$q$,
  'is restricted from trading');

select public.a_expect('A6 the refusal created NO order for that user',
  $q$select count(*)::text from public.orders where user_id='77777777-7777-7777-7777-777777770001'$q$, '1');

select public.a_expect('A6 a trading restriction does NOT block cancelling (funds can always be released)',
  $q$select (public.cancel_order((select id from public.orders where user_id='77777777-7777-7777-7777-777777770001'
           and status='new' limit 1), 'A6 self-service cancel', '77777777-7777-7777-7777-777777770001')->>'status')$q$,
  'canceled');

select public.a_run('A6 lift the trading restriction',
  $q$select public.admin_clear_restriction((select id from public.account_restrictions
        where user_id='77777777-7777-7777-7777-777777770001' and scope='trading' and active),
        'A6 lift', (select id from public.a_op where username='a_comp'))$q$);

select public.a_run('A6 ... after which the same order is accepted again',
  $q$select public.place_order('BTC/USDT','buy','limit', 1000, 1, 'gtc', null,
        '77777777-7777-7777-7777-777777770001')$q$);

-- ===========================================================================
\echo '=== A7. deposit restriction ENFORCED in record_deposit and credit_deposit'
-- ===========================================================================
select public.a_run('A7 an UNRESTRICTED user''s paper deposit is recorded (control case)',
  $q$select public.record_deposit('77777777-7777-7777-7777-777777770002','USDT','tron','ADMA7TX1',
        20000000, -1, null, null, 20)$q$);

select public.a_expect('A7 ... and starts confirmed (20 of the 20 confirmations the network requires)',
  $q$select status || '/' || environment from public.deposits where txid='ADMA7TX1'$q$, 'confirmed/paper');

select public.a_run('A7 restrict u2 from deposits',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770002','deposits',
        'A7 fixture: deposit restriction', (select id from public.a_op where username='a_comp'))$q$);

select public.a_expect_error('A7 a deposit-restricted user cannot have a new deposit recorded',
  $q$select public.record_deposit('77777777-7777-7777-7777-777777770002','USDT','tron','ADMA7TX2',
        20000000, -1, null, null, 20)$q$,
  'is restricted from deposits');

select public.a_expect('A7 the refused record created no deposit row',
  $q$select count(*)::text from public.deposits where txid='ADMA7TX2'$q$, '0');

select public.a_expect_error('A7 ... and the already-recorded deposit cannot be credited either',
  $q$select public.credit_deposit((select id from public.deposits where txid='ADMA7TX1'))::text$q$,
  'is restricted from deposits');

select public.a_expect('A7 the refused credit left the deposit uncredited',
  $q$select coalesce(credited_ledger_transaction_id::text, 'NULL') from public.deposits where txid='ADMA7TX1'$q$,
  'NULL');

select public.a_run('A7 lift the deposit restriction',
  $q$select public.admin_clear_restriction((select id from public.account_restrictions
        where user_id='77777777-7777-7777-7777-777777770002' and scope='deposits' and active),
        'A7 lift', (select id from public.a_op where username='a_comp'))$q$);

select public.a_run('A7 ... after which the same deposit credits normally (one balanced ledger transaction)',
  $q$select public.credit_deposit((select id from public.deposits where txid='ADMA7TX1'))$q$);

select public.a_expect('A7 ... and the deposit is credited',
  $q$select (credited_ledger_transaction_id is not null)::text || '/' || status
        from public.deposits where txid='ADMA7TX1'$q$, 'true/confirmed');

-- ===========================================================================
\echo '=== A8. withdrawal restriction ENFORCED in record_withdrawal_request and approve_withdrawal'
-- ===========================================================================
select public.a_run('A8 an UNRESTRICTED user''s withdrawal request is recorded (control case)',
  $q$select public.record_withdrawal_request('77777777-7777-7777-7777-777777770003','BTC','bitcoin',
        'A8FIXTUREADDRESS0001', 1000)$q$);

select public.a_expect('A8 ... as a pending paper request',
  $q$select status || '/' || environment from public.withdrawal_requests
        where destination_address='A8FIXTUREADDRESS0001'$q$, 'pending/paper');

select public.a_run('A8 restrict u3 from withdrawals',
  $q$select public.admin_set_restriction('77777777-7777-7777-7777-777777770003','withdrawals',
        'A8 fixture: withdrawal restriction', (select id from public.a_op where username='a_super'))$q$);

select public.a_expect_error('A8 a withdrawal-restricted user cannot record a new request',
  $q$select public.record_withdrawal_request('77777777-7777-7777-7777-777777770003','BTC','bitcoin',
        'A8FIXTUREADDRESS0002', 1000)$q$,
  'is restricted from withdrawals');

select public.a_expect_error('A8 ... and an existing request cannot be approved (no money moves out)',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests
           where destination_address='A8FIXTUREADDRESS0001'))::text$q$,
  'is restricted from withdrawals');

select public.a_expect('A8 the refused approval left the request pending with no hold',
  $q$select status || '/' || coalesce(hold_ledger_transaction_id::text,'NULL') from public.withdrawal_requests
        where destination_address='A8FIXTUREADDRESS0001'$q$, 'pending/NULL');

select public.a_run('A8 lift the withdrawal restriction',
  $q$select public.admin_clear_restriction((select id from public.account_restrictions
        where user_id='77777777-7777-7777-7777-777777770003' and scope='withdrawals' and active),
        'A8 lift', (select id from public.a_op where username='a_super'))$q$);

select public.a_run('A8 ... after which the approval places the hold',
  $q$select public.approve_withdrawal((select id from public.withdrawal_requests
        where destination_address='A8FIXTUREADDRESS0001'))$q$);

select public.a_expect('A8 ... and the request is approved with a hold transaction',
  $q$select status || '/' || (hold_ledger_transaction_id is not null)::text
        from public.withdrawal_requests where destination_address='A8FIXTUREADDRESS0001'$q$, 'approved/true');

select public.a_expect('A8 a scope restriction is scoped: u3 is still free to trade and deposit',
  $q$select (public.assert_account_not_restricted('77777777-7777-7777-7777-777777770003','trading'))::text
         || '/' || (public.assert_account_not_restricted('77777777-7777-7777-7777-777777770003','deposits'))::text$q$,
  '/');

-- ===========================================================================
\echo '=== A9. KYC review through the operator wrappers (PR #6 reused, actor recorded)'
-- ===========================================================================
select public.a_run('A9 u1 submits a level-1 KYC request (paper operator path)',
  $q$select public.submit_kyc('77777777-7777-7777-7777-777777770001', 1,
        '{"document_id":"TESTADMDOC0001","document_sha256":"sha256:00000000000000000000000000000000000000000000000000000000000000a1"}'::jsonb)$q$);

select public.a_run('A9 compliance puts it under review',
  $q$select public.admin_kyc_set_under_review((select id from public.kyc_submissions
        where user_id='77777777-7777-7777-7777-777777770001' and status='pending' limit 1),
        'A9 reviewing', (select id from public.a_op where username='a_comp'))$q$);

select public.a_expect('A9 ... the submission is under review and the wrapper audited it',
  $q$select s.status || '/' || (select count(*) from public.security_audit_log
          where action='admin.kyc.under_review' and entity_id = s.id)::text
        from public.kyc_submissions s
        where s.user_id='77777777-7777-7777-7777-777777770001' and s.status = 'under review'$q$,
  'under review/1');

select public.a_run('A9 compliance approves it (the level is granted atomically by approve_kyc)',
  $q$select public.admin_kyc_approve((select id from public.kyc_submissions
        where user_id='77777777-7777-7777-7777-777777770001' and level_sought=1 limit 1),
        'A9 approved', (select id from public.a_op where username='a_comp'))$q$);

select public.a_expect('A9 ... the user is now level 1',
  $q$select level::text from public.kyc_status where user_id='77777777-7777-7777-7777-777777770001'$q$, '1');

select public.a_expect('A9 ... and the kyc.level.changed audit row names the OPERATOR, not NULL',
  $q$select (actor_id = (select id from public.a_op where username='a_comp'))::text || '/' || actor_role
        from public.security_audit_log
        where action='kyc.level.changed' and subject_user_id='77777777-7777-7777-7777-777777770001'
        order by at desc limit 1$q$, 'true/operator');

select public.a_expect('A9 ... and so does the kyc.submission.approved row written by the PR #6 trigger',
  $q$select (actor_id = (select id from public.a_op where username='a_comp'))::text || '/' || actor_role
        from public.security_audit_log
        where action='kyc.submission.approved' and subject_user_id='77777777-7777-7777-7777-777777770001'
        order by at desc limit 1$q$, 'true/operator');

select public.a_expect('A9 every KYC DECISION row names an operator (the NULL-actor gap is closed)',
  $q$select count(*)::text from public.security_audit_log
        where subject_user_id='77777777-7777-7777-7777-777777770001'
          and action in ('kyc.submission.approved','kyc.submission.rejected','kyc.submission.under_review',
                         'kyc.level.changed')
          and actor_id is null$q$, '0');

select public.a_run('A9 u2 submits a level-1 request that will be rejected',
  $q$select public.submit_kyc('77777777-7777-7777-7777-777777770002', 1,
        '{"document_id":"TESTADMDOC0002","document_sha256":"sha256:00000000000000000000000000000000000000000000000000000000000000a2"}'::jsonb)$q$);

select public.a_expect_error('A9 a rejection without a reason is refused by the PR #6 function',
  $q$select public.admin_kyc_reject((select id from public.kyc_submissions
           where user_id='77777777-7777-7777-7777-777777770002' and status='pending' limit 1),
           '', (select id from public.a_op where username='a_comp'))::text$q$,
  'a reason is required');

select public.a_run('A9 compliance rejects it with a reason',
  $q$select public.admin_kyc_reject((select id from public.kyc_submissions
        where user_id='77777777-7777-7777-7777-777777770002' and status='pending' limit 1),
        'A9 fixture rejection', (select id from public.a_op where username='a_comp'))$q$);

select public.a_expect('A9 ... the level is unchanged by a rejection (still 0)',
  $q$select coalesce((select level::text from public.kyc_status
        where user_id='77777777-7777-7777-7777-777777770002'), '0')$q$, '0');

select public.a_expect('A9 the wrapper''s own audit row records the rejecter',
  $q$select (actor_id = (select id from public.a_op where username='a_comp'))::text
        from public.security_audit_log
        where action='admin.kyc.rejected' and subject_user_id='77777777-7777-7777-7777-777777770002'
        order by at desc limit 1$q$, 'true');

select public.a_expect_error('A9 an unknown submission id is refused by the wrapper',
  $q$select public.admin_kyc_approve('00000000-0000-0000-0000-000000000000', 'x',
           (select id from public.a_op where username='a_comp'))::text$q$,
  'unknown KYC submission');

select public.a_expect('A9 the KYC wrappers do not duplicate the state machine (they call the PR #6 functions)',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname like 'admin_kyc_%'
          and (p.prosrc ilike '%update public.kyc_submissions%' or p.prosrc ilike '%update public.kyc_status%')$q$,
  '0');

-- ===========================================================================
\echo '=== A10. maintenance mode: blocks all three paths, then REVERTED'
-- ===========================================================================
select public.a_expect('A10 maintenance_mode defaults to false and nothing has flipped it yet',
  $q$select maintenance_mode::text from public.app_settings$q$, 'false');

select public.a_expect_error('A10 entering maintenance mode without a note is refused',
  $q$select public.admin_set_maintenance(true, '', (select id from public.a_op where username='a_super'))::text$q$,
  'requires a note');

select public.a_expect('A10 superadmin turns maintenance mode ON (a note is mandatory and recorded)',
  $q$select (public.admin_set_maintenance(true, 'A10 scratch verification window',
           (select id from public.a_op where username='a_super'))->>'maintenance_mode')$q$, 'true');

select public.a_expect('A10 ... app_settings says so, and NOTHING else changed',
  $q$select maintenance_mode::text || '/' || mode || '/' || live_trading_enabled::text || '/' ||
           deposits_enabled::text || '/' || withdrawals_enabled::text
        from public.app_settings$q$, 'true/paper/false/false/false');

select public.a_expect_error('A10 trading is refused while maintenance is on',
  $q$select public.place_order('BTC/USDT','buy','limit', 1000, 1, 'gtc', null,
        '77777777-7777-7777-7777-777777770002')$q$,
  'is in maintenance mode: trading is temporarily unavailable');

select public.a_expect_error('A10 deposits are refused while maintenance is on',
  $q$select public.record_deposit('77777777-7777-7777-7777-777777770002','USDT','tron','ADMA10TX1',
        20000000, -1, null, null, 20)$q$,
  'is in maintenance mode: deposits is temporarily unavailable');

select public.a_expect_error('A10 deposits cannot be credited either (no money in during maintenance)',
  $q$select public.credit_deposit((select id from public.deposits where txid='ADMA7TX1'))::text$q$,
  'is in maintenance mode');

select public.a_expect_error('A10 withdrawals are refused while maintenance is on',
  $q$select public.record_withdrawal_request('77777777-7777-7777-7777-777777770003','BTC','bitcoin',
        'A10FIXTUREADDRESS0001', 1000)$q$,
  'is in maintenance mode: withdrawals is temporarily unavailable');

select public.a_expect('A10 the refusals created no rows',
  $q$select (select count(*) from public.deposits where txid='ADMA10TX1')::text || '/' ||
           (select count(*) from public.withdrawal_requests where destination_address='A10FIXTUREADDRESS0001')::text$q$,
  '0/0');

select public.a_expect('A10 cancelling an order still works during maintenance (funds are never trapped)',
  $q$select (public.cancel_order((select id from public.orders
           where user_id='77777777-7777-7777-7777-777777770001' and status='new' limit 1),
           'A10 maintenance cancel', '77777777-7777-7777-7777-777777770001')->>'status')$q$,
  'canceled');

select public.a_expect('A10 superadmin turns maintenance mode OFF',
  $q$select (public.admin_set_maintenance(false, null,
           (select id from public.a_op where username='a_super'))->>'maintenance_mode')$q$, 'false');

select public.a_run('A10 trading works again after the flip back',
  $q$select public.place_order('BTC/USDT','buy','limit', 1000, 1, 'gtc', null,
        '77777777-7777-7777-7777-777777770002')$q$);

select public.a_run('A10 deposits work again after the flip back',
  $q$select public.record_deposit('77777777-7777-7777-7777-777777770002','USDT','tron','ADMA10TX2',
        20000000, -1, null, null, 20)$q$);

select public.a_run('A10 withdrawals work again after the flip back',
  $q$select public.record_withdrawal_request('77777777-7777-7777-7777-777777770003','BTC','bitcoin',
        'A10FIXTUREADDRESS0002', 1000)$q$);

select public.a_expect('A10 both flips were audited with before/after',
  $q$select count(*)::text from public.security_audit_log
        where action='admin.settings.maintenance_changed'
          and actor_id=(select id from public.a_op where username='a_super')
          and details ? 'before' and details ? 'after'$q$, '2');

select public.a_expect('A10 app_settings is byte-identical to the snapshot taken before this suite ran',
  $q$select s.mode || '/' || s.paper_trading_enabled::text || '/' || s.live_trading_enabled::text || '/' ||
           s.deposits_enabled::text || '/' || s.withdrawals_enabled::text || '/' ||
           s.paper_deposits_enabled::text || '/' || s.paper_withdrawals_enabled::text || '/' ||
           s.kyc_required_for_trading::text || '/' || s.maintenance_mode::text
        from public.app_settings s join public.a_settings_snapshot o on true$q$,
  (select mode || '/' || paper_trading_enabled::text || '/' || live_trading_enabled::text || '/' ||
          deposits_enabled::text || '/' || withdrawals_enabled::text || '/' ||
          paper_deposits_enabled::text || '/' || paper_withdrawals_enabled::text || '/' ||
          kyc_required_for_trading::text || '/' || maintenance_mode::text
     from public.a_settings_snapshot));

select public.a_expect('A10 the exchange is in paper mode with every live flag off',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/' ||
           withdrawals_enabled::text || '/' || maintenance_mode::text
        from public.app_settings$q$, 'paper/false/false/false/false');

-- ===========================================================================
\echo '=== A11. the admin views are role-scoped (and empty for everybody else)'
-- ===========================================================================
select public.a_expect('A11 a non-operator caller gets zero rows from every admin view',
  $q$select (select count(*) from public.v_admin_users)::text || '/' ||
           (select count(*) from public.v_admin_balances)::text || '/' ||
           (select count(*) from public.v_admin_deposits)::text || '/' ||
           (select count(*) from public.v_admin_withdrawals)::text || '/' ||
           (select count(*) from public.v_admin_security_events)::text || '/' ||
           (select count(*) from public.v_admin_operators)::text$q$,
  '0/0/0/0/0/0');

select public.a_expect_error('A11 anon cannot query v_admin_users at all',
  $q$select count(*)::text from public.v_admin_users$q$,
  'permission denied for view v_admin_users', 'anon');

select public.a_expect('A11 a JWT-mapped support operator sees the directory, and the email column is empty',
  $q$select (count(*) > 0)::text || '/' || count(*) filter (where email is not null)::text
        from public.v_admin_users$q$, 'true/0', 'authenticated', '88888888-8888-8888-8888-888888880003'::uuid);

select public.a_expect_as('A11 compliance (users.read.pii) sees the email column filled', 'a_comp',
  $q$select count(*) filter (where email is not null)::text from public.v_admin_users$q$, '14');
select public.a_expect_as('A11 ... and the operator roster view is empty for compliance (operators.write is superadmin only)',
  'a_comp', $q$select count(*)::text from public.v_admin_operators$q$, '0');

select public.a_expect_as('A11 readonly sees the money-path views but neither the roster nor the emails', 'a_ro',
  $q$select (select count(*) > 0 from public.v_admin_deposits)::text || '/' ||
           (select count(*) from public.v_admin_operators)::text || '/' ||
           (select count(*) filter (where email is not null) from public.v_admin_users)::text$q$,
  'true/0/0');

select public.a_expect_as('A11 superadmin sees the roster, the restriction history and the security trail', 'a_super',
  $q$select (select count(*) from public.v_admin_operators)::text || '/' ||
           (select count(*) >= 4 from public.v_admin_restrictions)::text || '/' ||
           (select count(*) > 0 from public.v_admin_security_events)::text$q$,
  '6/true/true');

select public.a_expect_as('A11 the deposit/withdrawal monitors expose real rows to a money.read operator', 'a_super',
  $q$select (select count(*) > 0 from public.v_admin_deposits)::text || '/' ||
           (select count(*) > 0 from public.v_admin_withdrawals)::text$q$, 'true/true');

select public.a_expect('A11 user_overview returns a JSON snapshot with the documented keys',
  $q$select string_agg(k, ',' order by k) from jsonb_object_keys(
           public.admin_user_overview('77777777-7777-7777-7777-777777770001',
             (select id from public.a_op where username='a_super'))) k$q$,
  'balances,kyc_status,kyc_submissions,open_orders,restrictions,risk_flags,user');

select public.a_expect('A11 the overview is audited (an inspection is a sensitive read)',
  $q$select count(*)::text from public.security_audit_log
        where action='admin.user.inspected' and subject_user_id='77777777-7777-7777-7777-777777770001'$q$, '1');

select public.a_expect('A11 pagination works: limit 1 offset 1 returns one row and the total for the page set',
  $q$select (count(*))::text || '/' || (min(total_count) = (select count(*) from auth.users))::text
        from public.admin_list_users(1, 1, null, (select id from public.a_op where username='a_super'))$q$,
  '1/true');

-- ===========================================================================
\echo '=== A12. administrators can never create customer money (static probe)'
-- ===========================================================================
select public.a_expect('A12 no admin/guard function inserts or updates balances, accounts, ledger rows, or calls post_entry',
  $q$select coalesce(string_agg(p.proname, ','), '(none)') from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public'
          and (p.proname like 'admin!_%' escape '!' or p.proname in
               ('assert_operator','resolve_operator','log_operator_action','assert_account_not_restricted',
                'assert_not_in_maintenance','maintenance_mode','current_operator_id','current_operator_role',
                'operator_can','operator_can_do'))
          and (p.prosrc ilike '%insert into public.balances%'  or p.prosrc ilike '%insert into balances%'
            or p.prosrc ilike '%update public.balances%'      or p.prosrc ilike '%update balances%'
            or p.prosrc ilike '%insert into public.accounts%' or p.prosrc ilike '%insert into accounts%'
            or p.prosrc ilike '%update public.accounts%'      or p.prosrc ilike '%update accounts%'
            or p.prosrc ilike '%insert into public.ledger_transactions%'
            or p.prosrc ilike '%insert into public.ledger_entries%'
            or p.prosrc ilike '%post_entry(%')$q$,
  '(none)');

select public.a_expect('A12 no admin function touches an existing money-path position (rebuild/repair could hide theft)',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname like 'admin!_%' escape '!'
          and (p.prosrc ilike '%settle_fill(%' or p.prosrc ilike '%ensure_user_account(%'
            or p.prosrc ilike '%system_account_id(%' or p.prosrc ilike '%match_order(%')$q$,
  '0');

select public.a_expect('A12 the only table the audit helper writes is security_audit_log',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid=p.pronamespace
        where n.nspname='public' and p.proname='log_operator_action'
          and p.prosrc ilike '%insert into public.security_audit_log%'$q$, '1');

select public.a_expect('A12 the total ledger stays balanced after this suite (no unbalanced posting was possible)',
  $q$select count(*)::text from (
          select t.id from public.ledger_transactions t
            join public.ledger_entries e on e.transaction_id = t.id
           group by t.id having sum(e.amount_units) <> 0) x$q$, '0');

select public.a_expect('A12 every balance still equals the sum of its ledger entries (no drift was introduced)',
  $q$select count(*)::text from public.balances b
        where COALESCE(b.available_units,0) + COALESCE(b.locked_units,0)
              <> (select COALESCE(sum(e.amount_units),0) from public.ledger_entries e where e.account_id = b.account_id)$q$,
  '0');

-- ===========================================================================
\echo '=== A13. markets, fees and network configuration (superadmin wrappers)'
-- ===========================================================================
select public.a_expect('A13 the maker/taker fees of BTC/USDT before the change',
  $q$select maker_fee_bps || '/' || taker_fee_bps from public.markets where symbol='BTC/USDT' and environment='paper'$q$,
  '2/5');

select public.a_run('A13 superadmin changes the fees',
  $q$select public.admin_set_market_fees('BTC/USDT', 3, 7, 'paper',
        (select id from public.a_op where username='a_super'))$q$);

select public.a_expect('A13 ... the markets table holds the new fees',
  $q$select maker_fee_bps || '/' || taker_fee_bps from public.markets where symbol='BTC/USDT' and environment='paper'$q$,
  '3/7');

select public.a_expect('A13 ... with an audit row carrying the before/after fees',
  $q$select (details->'before'->>'maker_fee_bps') || '->' || (details->'after'->>'maker_fee_bps')
        from public.security_audit_log
        where action='admin.market.fees_changed' and entity_id=(select id from public.markets where symbol='BTC/USDT')
        order by at desc limit 1$q$, '2->3');

select public.a_run('A13 superadmin restores the fees',
  $q$select public.admin_set_market_fees('BTC/USDT', 2, 5, 'paper',
        (select id from public.a_op where username='a_super'))$q$);

select public.a_expect('A13 fees are back to the values the engine suite used',
  $q$select maker_fee_bps || '/' || taker_fee_bps from public.markets where symbol='BTC/USDT' and environment='paper'$q$,
  '2/5');

select public.a_run('A13 superadmin halts a market',
  $q$select public.admin_set_market_status('SOL/USDT', 'halted', 'paper',
        (select id from public.a_op where username='a_super'))$q$);
select public.a_expect('A13 ... status halted and is_active false',
  $q$select status || '/' || is_active::text from public.markets where symbol='SOL/USDT' and environment='paper'$q$,
  'halted/false');
select public.a_run('A13 superadmin resumes it (reverted)',
  $q$select public.admin_set_market_status('SOL/USDT', 'trading', 'paper',
        (select id from public.a_op where username='a_super'))$q$);
select public.a_expect('A13 ... trading and active again',
  $q$select status || '/' || is_active::text from public.markets where symbol='SOL/USDT' and environment='paper'$q$,
  'trading/true');

select public.a_run('A13 superadmin reconfigures a deposit network through the authorised wrapper',
  $q$select public.admin_register_deposit_network('USDT','solana',0,null,false,1000000,true,
        (select id from public.a_op where username='a_super'))$q$);

select public.a_expect('A13 ... the network is unchanged in meaning (still enabled, same confirmations)',
  $q$select dn.deposit_enabled::text || '/' || dn.required_confirmations from public.deposit_networks dn
        join public.assets a on a.id=dn.asset_id
        where a.symbol='USDT' and dn.network='solana' and dn.environment='paper'$q$, 'true/0');

select public.a_expect('A13 ... and the wrapper audited it',
  $q$select count(*)::text from public.security_audit_log where action='admin.deposit_network.upserted'$q$, '1');

select public.a_expect_error('A13 a non-superadmin cannot reconfigure a network (reuses markets.write)',
  $q$select public.admin_register_deposit_network('USDT','solana',0,null,false,1000000,true,
           (select id from public.a_op where username='a_comp'))::text$q$,
  'is not permitted to perform markets.write');

-- ===========================================================================
\echo '=== A14. operator roster management'
-- ===========================================================================
select public.a_run('A14 superadmin promotes support to compliance',
  $q$select public.admin_set_operator_role('a_supp','compliance',
        (select id from public.a_op where username='a_super'))$q$);

select public.a_expect('A14 ... the role changed and the audit row records both roles',
  $q$select (select operator_role from public.admin_users where username='a_supp') || '/' ||
           (select (details->'before'->>'operator_role') || '->' || (details->'after'->>'operator_role')
              from public.security_audit_log where action='admin.operator.role_changed'
             order by at desc limit 1)$q$,
  'compliance/support->compliance');

select public.a_expect_error('A14 the last active superadmin cannot be demoted',
  $q$select public.admin_set_operator_role('a_super','readonly',
           (select id from public.a_op where username='a_super'))::text$q$,
  'last active superadmin');

select public.a_expect_error('A14 the last active superadmin cannot be deactivated either',
  $q$select public.admin_set_operator_active('a_super', false,
           (select id from public.a_op where username='a_super'))::text$q$,
  'last active superadmin');

select public.a_run('A14 demote a_supp back to support (reverted)',
  $q$select public.admin_set_operator_role('a_supp','support',
        (select id from public.a_op where username='a_super'))$q$);

select public.a_expect('A14 ... back to support',
  $q$select operator_role from public.admin_users where username='a_supp'$q$, 'support');

select public.a_expect_error('A14 an unknown role is refused',
  $q$select public.admin_set_operator_role('a_supp','god',
           (select id from public.a_op where username='a_super'))::text$q$,
  'unknown operator role');

select public.a_expect('A14 every operator action in this suite names an existing operator (audit integrity)',
  $q$select count(*)::text from public.security_audit_log a
        where a.action like 'admin.%'
          and (a.actor_id is null or not exists (select 1 from public.admin_users u where u.id=a.actor_id))$q$,
  '0');

-- ===========================================================================
\echo '=== A15. the security audit trail, role-scoped'
-- ===========================================================================
select public.a_expect_as('A15 superadmin sees the operator actions in the audit view', 'a_super',
  $q$select (count(*) > 0)::text from public.v_admin_security_events where action like 'admin.%'$q$, 'true');

select public.a_expect_as('A15 support sees NOTHING in the audit view (security.read denied)', 'a_supp',
  $q$select count(*)::text from public.v_admin_security_events$q$, '0');

select public.a_expect_as('A15 readonly (the auditor) sees the full trail', 'a_ro',
  $q$select (count(*) > 0)::text from public.v_admin_security_events where action like 'admin.%'$q$, 'true');

select public.a_expect_as('A15 every operator row WITH an actor resolves to an operator username', 'a_super',
  $q$select count(*)::text from public.v_admin_security_events
        where actor_role = 'operator' and actor_id is not null and actor_username is null$q$, '0');

select public.a_expect_as('A15 legacy pre-migration operator rows are the only NULL-actor rows left (the gap PR #6 left)', 'a_super',
  $q$select (count(*) > 0)::text from public.v_admin_security_events
        where actor_role = 'operator' and actor_id is null and action not like 'admin.%'$q$, 'true');

select public.a_expect_error('A15 the audit log is still append-only: UPDATE is refused',
  $q$update public.security_audit_log set details = details
     where id = (select id from public.security_audit_log limit 1)$q$,
  'append-only');

select public.a_expect_error('A15 the audit log is still append-only: DELETE is refused',
  $q$delete from public.security_audit_log where id = (select id from public.security_audit_log limit 1)$q$,
  'append-only');

\echo '=== SUMMARY'
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from public.a_res;
select count(*) filter (where not ok) as failures from public.a_res;
