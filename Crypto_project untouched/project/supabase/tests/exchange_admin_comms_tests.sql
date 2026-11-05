-- ============================================================================
-- exchange_admin_comms_tests.sql — stage 2, part 2: admin support, communications
-- and status views (migration 20261005100160_exchange_admin_comms)
--
-- Runs LAST in the core database (after schema, ledger, immutability, deposits,
-- withdrawals, kyc and admin): it reuses the users, markets, ledger history and
-- operator control plane those suites created, and everything it adds is additive.
--
-- What it proves, section by section:
--   C0  fixtures: synthetic users, one operator per role, a visitor conversation
--   C1  support management: role-scoped list/read over the EXISTING chat tables,
--       the user-side chat RLS is UNCHANGED (3 + 2 policies, still world-readable)
--   C2  operator replies land in chat_messages as sender = agent, are visible to
--       anon (the visitor path), and write an audit row with a real actor
--   C3  close/reopen is audited, refuses a no-op, and blocks replying
--   C4  notification RPC authz per role + audit rows with a non-NULL actor
--   C5  notification RLS: own + broadcast visible, other users' invisible, anon
--       denied, no client write path, mark-read only for your own non-broadcast row
--   C6  announcements: window logic, public read path, deactivation, audit, anon
--       cannot read the table
--   C7  v_admin_custody: connectivity = 'not_connected' everywhere and
--       ledger_units = balance_units on every system account
--   C8  v_admin_liquidity: honest empty state on a fresh market, correct
--       aggregates once real orders rest, and agreement with the raw orders table
--   C9  v_admin_alerts: restrictions + risk flags + recent security events, scoped
--   C10 the ACL surface: no new admin function is client-callable, none can create
--       money, and the RLS/policy shape of the two new tables is as documented
--   C11 app_settings and the ledger are exactly as they were before the suite
--
-- Every fixture is synthetic; nothing here invents a notification, an announcement,
-- a balance, a fill, a customer or a custody connection.
-- ============================================================================
\set ON_ERROR_STOP 0

drop table if exists public.c_res;
drop table if exists public.c_op;
create table public.c_res (label text, ok boolean);
drop table if exists public.c_ids;
create table public.c_ids (name text primary key, id uuid);
create table public.c_op (username text primary key, id uuid);

create or replace function public.c_expect(p_label text, p_sql text, p_expected text,
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
      insert into public.c_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.c_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.c_res(label, ok) values (p_label, false);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.c_expect_error(p_label text, p_sql text, p_fragment text,
  p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.c_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.c_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.c_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

-- same transaction, with the transaction-local gtvx.operator_id set: exactly how an
-- edge function holding the service key identifies the operator (PR #7 contract)
create or replace function public.c_expect_as(p_label text, p_username text, p_sql text, p_expected text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  perform set_config('gtvx.operator_id', (select id::text from public.c_op where username = p_username), true);
  execute p_sql into v_actual;
  if v_actual is not distinct from p_expected then
    raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
    insert into public.c_res(label, ok) values (p_label, true);
  else
    raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
    insert into public.c_res(label, ok) values (p_label, false);
  end if;
exception when others then
  raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.c_res(label, ok) values (p_label, false);
end;
$fn$;

create or replace function public.c_expect_error_as(p_label text, p_username text, p_sql text, p_fragment text)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  perform set_config('gtvx.operator_id', (select id::text from public.c_op where username = p_username), true);
  execute p_sql into v_actual;
  raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
  insert into public.c_res(label, ok) values (p_label || ' (was allowed)', false);
exception when others then
  if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
    raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
    insert into public.c_res(label, ok) values (p_label, true);
  else
    raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
    insert into public.c_res(label, ok) values (p_label || ' (wrong error)', false);
  end if;
end;
$fn$;

-- actions that must SUCCEED (no comparison, exception = failure)
create or replace function public.c_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
begin
  execute p_sql;
  raise notice 'PASS  (ran) %', p_label;
  insert into public.c_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.c_res(label, ok) values (p_label, false);
end;
$fn$;

-- run a statement AS a client role (used to exercise the visitor / anon chat path)
create or replace function public.c_run_as(p_label text, p_role text, p_sql text)
returns void language plpgsql as $fn$
begin
  execute format('set local role %I', p_role);
  execute p_sql;
  execute 'reset role';
  raise notice 'PASS  (ran as %) %', p_role, p_label;
  insert into public.c_res(label, ok) values (p_label, true);
exception when others then
  execute 'reset role';
  raise notice 'FAIL  (setup as %) % raised % (%)', p_role, p_label, sqlerrm, sqlstate;
  insert into public.c_res(label, ok) values (p_label, false);
end;
$fn$;

create or replace function public.c_id(p_username text)
returns uuid language sql stable as $fn$
  select id from public.c_op where username = p_username
$fn$;

-- balanced paper funding (the money comes from PAPER_FAUCET, never out of thin air)
create or replace function public.c_fund(p_user uuid, p_symbol text, p_amount numeric)
returns void language plpgsql as $fn$
declare
  v_asset uuid; v_faucet uuid; v_account uuid; v_tx uuid;
begin
  select id into v_asset from public.assets where symbol = p_symbol;
  v_faucet := public.system_account_id('PAPER_FAUCET', v_asset, 'paper');
  v_account := public.ensure_user_account(p_user, v_asset, 'available', 'paper');
  insert into public.ledger_transactions (type, environment, reference_type, reference_id, description)
  values ('paper_funding', 'paper', 'user', p_user, format('scratch comms test funding %s %s', p_amount, p_symbol))
  returning id into v_tx;
  perform public.post_entry(v_tx, v_faucet, -p_amount, 'scratch comms test funding');
  perform public.post_entry(v_tx, v_account, p_amount, 'scratch comms test funding');
end $fn$;

drop table if exists public.c_settings_snapshot;
create table public.c_settings_snapshot as
select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
       paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode
  from public.app_settings;

-- ===========================================================================
\echo '=== C0. fixtures — synthetic users, operators, one visitor conversation'
-- ===========================================================================
select public.c_run('C0 create two synthetic customers',
  $q$insert into auth.users (id, email) values
       ('99999999-9999-9999-9999-999999990001', 'comms-u1@example.test'),
       ('99999999-9999-9999-9999-999999990002', 'comms-u2@example.test')$q$);

select public.c_run('C0 create the auth identities the JWT-mapped operators sign in as',
  $q$insert into auth.users (id, email) values
       ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaa001', 'comms-op-super@example.test'),
       ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaa002', 'comms-op-comp@example.test'),
       ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaa003', 'comms-op-supp@example.test')$q$);

select public.c_run('C0 provision one operator per role',
  $q$insert into public.admin_users (username, password_hash, operator_role, auth_user_id, display_name) values
       ('c_super', 'fixture', 'superadmin', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaa001', 'comms fixture superadmin'),
       ('c_comp',  'fixture', 'compliance', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaa002', 'comms fixture compliance'),
       ('c_supp',  'fixture', 'support',    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaa003', 'comms fixture support'),
       ('c_ro',    'fixture', 'readonly',   null, 'comms fixture auditor')$q$);

select public.c_run('C0 record the operator ids',
  $q$insert into public.c_op (username, id) select username, id from public.admin_users
      where username in ('c_super','c_comp','c_supp','c_ro')$q$);

select public.c_run('C0 fund c_u1 with BTC and ETH so real orders can rest',
  $q$select public.c_fund('99999999-9999-9999-9999-999999990001','BTC', 500000000)$q$);
select public.c_run('C0 ... and with ETH',
  $q$select public.c_fund('99999999-9999-9999-9999-999999990001','ETH', 1000000000000000000)$q$);

-- the visitor path: an anonymous browser opens a conversation and writes two messages
select public.c_run_as('C0 an anon visitor opens a chat conversation', 'anon',
  $q$insert into public.chat_conversations (id, visitor_id, visitor_name, status)
     values ('cccccccc-cccc-cccc-cccc-cccccccc0001', 'visitor-c1', 'fixture visitor', 'open')$q$);

select public.c_run_as('C0 the visitor writes a first message', 'anon',
  $q$insert into public.chat_messages (conversation_id, sender, content)
     values ('cccccccc-cccc-cccc-cccc-cccccccc0001', 'visitor', 'Hello, my deposit has not arrived.')$q$);

select public.c_run_as('C0 the visitor writes a second message', 'anon',
  $q$insert into public.chat_messages (conversation_id, sender, content)
     values ('cccccccc-cccc-cccc-cccc-cccccccc0001', 'visitor', 'It was 0.01 BTC an hour ago.')$q$);

-- ===========================================================================
\echo '=== C1. support management: role-scoped reads over the EXISTING chat tables'
-- ===========================================================================
select public.c_expect_as('C1 support lists conversations (support.read allowed)', 'c_supp',
  $q$select (count(*) > 0)::text from public.admin_list_support_conversations()$q$, 'true');

select public.c_expect_as('C1 readonly (the auditor) can list them too', 'c_ro',
  $q$select (count(*) > 0)::text from public.admin_list_support_conversations()$q$, 'true');

select public.c_expect_as('C1 support reads one thread with both visitor messages', 'c_supp',
  $q$select jsonb_array_length(public.admin_get_support_conversation('cccccccc-cccc-cccc-cccc-cccccccc0001', null)->'messages')::text$q$,
  '2');

select public.c_expect_as('C1 the thread reports its status', 'c_supp',
  $q$select public.admin_get_support_conversation('cccccccc-cccc-cccc-cccc-cccccccc0001', null)->>'status'$q$,
  'open');

select public.c_expect('C1 reading a thread is audited with a real actor',
  $q$select count(*)::text from public.security_audit_log
        where action = 'admin.support.conversation_read'
          and actor_id = (select id from public.c_op where username = 'c_supp')$q$, '2');

select public.c_expect('C1 listing conversations is audited with a real actor',
  $q$select count(*)::text from public.security_audit_log
        where action = 'admin.support.conversations_listed' and actor_id is not null$q$, '2');

select public.c_expect_error_as('C1 an unknown conversation is refused', 'c_supp',
  $q$select public.admin_get_support_conversation('cccccccc-cccc-cccc-cccc-ccccccccdead', null)::text$q$,
  'unknown conversation');

select public.c_expect_error_as('C1 readonly may NOT write to a conversation (support.write denied)', 'c_ro',
  $q$select public.admin_support_reply('cccccccc-cccc-cccc-cccc-cccccccc0001','nope',null)::text$q$,
  'not permitted to perform support.write');

select public.c_expect_error('C1 anon cannot call the operator support RPC at all',
  $q$select count(*)::text from public.admin_list_support_conversations()$q$,
  'permission denied for function', 'anon');

select public.c_expect('C1 the user-side chat RLS is UNCHANGED: anon still reads the conversation',
  $q$select count(*)::text from public.chat_messages where conversation_id = 'cccccccc-cccc-cccc-cccc-cccccccc0001'$q$,
  '2', 'anon');

select public.c_expect('C1 ... and the original chat policies are untouched (3 + 2)',
  $q$select (select count(*) from pg_policies where schemaname='public' and tablename='chat_conversations')::text
        || '/' || (select count(*) from pg_policies where schemaname='public' and tablename='chat_messages')::text$q$,
  '3/2');

-- ===========================================================================
\echo '=== C2. operator reply: stored as agent, visible to the visitor, audited'
-- ===========================================================================
select public.c_expect_as('C2 support posts an operator reply', 'c_supp',
  $q$select (public.admin_support_reply('cccccccc-cccc-cccc-cccc-cccccccc0001',
        'Thanks — an operator is looking into this.', null) is not null)::text$q$, 'true');

select public.c_expect('C2 the reply is a chat_messages row with sender = agent',
  $q$select count(*)::text from public.chat_messages
        where conversation_id = 'cccccccc-cccc-cccc-cccc-cccccccc0001' and sender = 'agent'$q$, '1');

select public.c_expect('C2 ... carrying exactly the operator text',
  $q$select content from public.chat_messages
        where conversation_id = 'cccccccc-cccc-cccc-cccc-cccccccc0001' and sender = 'agent'$q$,
  'Thanks — an operator is looking into this.');

select public.c_expect('C2 the visitor (anon, unchanged RLS) can read the operator reply',
  $q$select count(*)::text from public.chat_messages
        where conversation_id = 'cccccccc-cccc-cccc-cccc-cccccccc0001' and sender = 'agent'$q$,
  '1', 'anon');

select public.c_expect('C2 the reply is audited with a real actor and the message id',
  $q$select count(*)::text from public.security_audit_log a
        where a.action = 'admin.support.replied'
          and a.actor_id = (select id from public.c_op where username = 'c_supp')
          and a.entity_id = (select id from public.chat_messages
                              where conversation_id = 'cccccccc-cccc-cccc-cccc-cccccccc0001' and sender = 'agent')$q$,
  '1');

select public.c_expect_error_as('C2 an empty reply is refused', 'c_supp',
  $q$select public.admin_support_reply('cccccccc-cccc-cccc-cccc-cccccccc0001','   ',null)::text$q$,
  'between 1 and 4000 characters');

-- ===========================================================================
\echo '=== C3. close / reopen — audited, no-op refused, replying blocked while closed'
-- ===========================================================================
select public.c_expect_as('C3 support closes the conversation', 'c_supp',
  $q$select public.admin_support_set_status('cccccccc-cccc-cccc-cccc-cccccccc0001','closed',null)->>'status_after'$q$,
  'closed');

select public.c_expect('C3 closing is audited with before/after and a real actor',
  $q$select count(*)::text from public.security_audit_log
        where action = 'admin.support.status_changed'
          and actor_id = (select id from public.c_op where username = 'c_supp')
          and details ? 'before' and details ? 'after'$q$, '1');

select public.c_expect_error_as('C3 closing twice is refused', 'c_supp',
  $q$select public.admin_support_set_status('cccccccc-cccc-cccc-cccc-cccccccc0001','closed',null)::text$q$,
  'is already closed');

select public.c_expect_error_as('C3 a closed conversation cannot be replied to', 'c_supp',
  $q$select public.admin_support_reply('cccccccc-cccc-cccc-cccc-cccccccc0001','after close',null)::text$q$,
  'is closed: reopen it before replying');

select public.c_expect_as('C3 compliance can reopen it (support.write allowed)', 'c_comp',
  $q$select public.admin_support_set_status('cccccccc-cccc-cccc-cccc-cccccccc0001','open',null)->>'status_after'$q$,
  'open');

select public.c_expect('C3 reopening is audited too (2 status changes, 2 actors)',
  $q$select count(*)::text from public.security_audit_log
        where action = 'admin.support.status_changed' and actor_id is not null$q$, '2');

select public.c_expect_error_as('C3 an unknown status is refused', 'c_supp',
  $q$select public.admin_support_set_status('cccccccc-cccc-cccc-cccc-cccccccc0001','pending',null)::text$q$,
  'unknown conversation status');

select public.c_expect_as('C3 the status filter works (the conversation is listed as open)', 'c_supp',
  $q$select count(*)::text from public.admin_list_support_conversations('open')$q$, '1');

-- ===========================================================================
\echo '=== C4. notifications: per-role authz and audit'
-- ===========================================================================
select public.c_expect_as('C4 support sends a notification to one user (notifications.send allowed)', 'c_supp',
  $q$select (public.admin_send_notification('99999999-9999-9999-9999-999999990001','support',
        'Deposit under review','Your deposit is being checked by support.', null) is not null)::text$q$, 'true');

select public.c_expect_as('C4 compliance can send one too', 'c_comp',
  $q$select (public.admin_send_notification('99999999-9999-9999-9999-999999990002','kyc',
        'KYC note','Your KYC submission needs a clearer document.', null) is not null)::text$q$, 'true');

select public.c_expect_error_as('C4 readonly may NOT send (notifications.send denied)', 'c_ro',
  $q$select public.admin_send_notification('99999999-9999-9999-9999-999999990001','x','y','z',null)::text$q$,
  'not permitted to perform notifications.send');

select public.c_expect_error_as('C4 support may NOT broadcast (notifications.broadcast is superadmin only)', 'c_supp',
  $q$select public.admin_broadcast_notification('news','Broadcast','Everyone should read this',null)::text$q$,
  'not permitted to perform notifications.broadcast');

select public.c_expect_as('C4 superadmin broadcasts to everyone', 'c_super',
  $q$select (public.admin_broadcast_notification('maintenance',
        'Scheduled maintenance','The exchange will be in maintenance mode tonight.', null) is not null)::text$q$,
  'true');

select public.c_expect('C4 the broadcast row is the ONLY broadcast (user_id NULL) and names its author',
  $q$select count(*)::text from public.notifications where user_id is null and created_by is not null$q$, '1');

select public.c_expect('C4 both sends and the broadcast are audited with real actors',
  $q$select (select count(*) from public.security_audit_log where action='admin.notification.sent' and actor_id is not null)::text
        || '/' || (select count(*) from public.security_audit_log where action='admin.notification.broadcast' and actor_id is not null)::text$q$,
  '2/1');

select public.c_expect_error_as('C4 a notification to an unknown user is refused', 'c_supp',
  $q$select public.admin_send_notification('99999999-9999-9999-9999-99999999dead','x','title','body',null)::text$q$,
  'unknown user');

select public.c_expect_error_as('C4 a notification without a title is refused', 'c_supp',
  $q$select public.admin_send_notification('99999999-9999-9999-9999-999999990001','kyc','  ','body',null)::text$q$,
  'needs a title');

-- ===========================================================================
\echo '=== C5. notifications: user-side RLS, no client write path, mark-read'
-- ===========================================================================
select public.c_run('C5 record the notification ids for the cross-user checks',
  $q$insert into public.c_ids (name, id)
     select case when user_id is null then 'n_broadcast'
                 when user_id = '99999999-9999-9999-9999-999999990001' then 'n_u1'
                 else 'n_u2' end, id
       from public.notifications$q$);

select public.c_expect('C5 user 1 sees exactly their own notification + the broadcast',
  $q$select count(*)::text from public.notifications$q$, '2',
  'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect('C5 user 1 cannot see user 2''s notification',
  $q$select count(*)::text from public.notifications
        where id = (select id from public.notifications where user_id = '99999999-9999-9999-9999-999999990002')$q$,
  '0', 'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect('C5 user 2 sees their own + the broadcast as well',
  $q$select count(*)::text from public.notifications$q$, '2',
  'authenticated', '99999999-9999-9999-9999-999999990002');

select public.c_expect_error('C5 anon cannot read the notifications table at all',
  $q$select count(*)::text from public.notifications$q$,
  'permission denied for table notifications', 'anon');

select public.c_expect_error('C5 a signed-in user has NO write path (INSERT is denied)',
  $q$insert into public.notifications (user_id, type, title, body)
     values ('99999999-9999-9999-9999-999999990001','self','self','self')$q$,
  'permission denied for table notifications', 'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect_error('C5 ... and cannot rewrite read_at directly (UPDATE is denied)',
  $q$update public.notifications set read_at = now()$q$,
  'permission denied for table notifications', 'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect('C5 a user marks their own notification read',
  $q$select (public.user_mark_notification_read(
        (select id from public.notifications where user_id = '99999999-9999-9999-9999-999999990001'))
        ->> 'already_read')$q$, 'false',
  'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect('C5 ... and it is stored',
  $q$select (read_at is not null)::text from public.notifications
        where user_id = '99999999-9999-9999-9999-999999990001'$q$, 'true');

select public.c_expect('C5 marking it read again is idempotent',
  $q$select (public.user_mark_notification_read(
        (select id from public.notifications where user_id = '99999999-9999-9999-9999-999999990001'))
        ->> 'already_read')$q$, 'true',
  'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect_error('C5 a user cannot mark somebody else''s notification read',
  $q$select public.user_mark_notification_read(
        (select id from public.c_ids where name = 'n_u2'))::text$q$,
  'does not belong to the calling user', 'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect_error('C5 a broadcast cannot be marked read (it would lie for everyone)',
  $q$select public.user_mark_notification_read(
        (select id from public.c_ids where name = 'n_broadcast'))::text$q$,
  'is a broadcast', 'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect_error('C5 anon cannot call the mark-read RPC',
  $q$select public.user_mark_notification_read(gen_random_uuid())::text$q$,
  'permission denied for function', 'anon');

select public.c_expect('C5 user 2''s read state is untouched by user 1''s action',
  $q$select count(*)::text from public.notifications
        where user_id = '99999999-9999-9999-9999-999999990002' and read_at is not null$q$, '0');

select public.c_expect('C5 the broadcast row was never marked read',
  $q$select count(*)::text from public.notifications where user_id is null and read_at is not null$q$, '0');

-- ===========================================================================
\echo '=== C6. announcements: window logic, public read path, deactivation'
-- ===========================================================================
select public.c_expect_error_as('C6 support may NOT create an announcement (superadmin only)', 'c_supp',
  $q$select public.admin_create_announcement('Title','Body text here',null,null,null)::text$q$,
  'not permitted to perform announcements.write');

select public.c_expect_as('C6 superadmin publishes an announcement that is active now', 'c_super',
  $q$select (public.admin_create_announcement('Trading hours update',
        'Paper trading is available around the clock.', now() - interval '1 minute', null, null) is not null)::text$q$,
  'true');

select public.c_expect('C6 the public feed shows it to anon',
  $q$select count(*)::text from public.v_public_announcements where title = 'Trading hours update'$q$, '1', 'anon');

select public.c_expect_as('C6 superadmin schedules one in the future', 'c_super',
  $q$select (public.admin_create_announcement('Future notice','Not visible yet.',
        now() + interval '1 day', now() + interval '2 days', null) is not null)::text$q$, 'true');

select public.c_expect('C6 a future announcement is NOT in the public feed',
  $q$select count(*)::text from public.v_public_announcements where title = 'Future notice'$q$, '0', 'anon');

select public.c_expect_as('C6 superadmin publishes an already-expired window', 'c_super',
  $q$select (public.admin_create_announcement('Old notice','Already over.',
        now() - interval '2 days', now() - interval '1 day', null) is not null)::text$q$, 'true');

select public.c_expect('C6 an expired announcement is NOT in the public feed',
  $q$select count(*)::text from public.v_public_announcements where title = 'Old notice'$q$, '0', 'anon');

select public.c_expect('C6 exactly one announcement is publicly visible',
  $q$select count(*)::text from public.v_public_announcements$q$, '1', 'anon');

select public.c_expect('C6 every announcement creation is audited with a real actor',
  $q$select count(*)::text from public.security_audit_log
        where action = 'admin.announcement.created'
          and actor_id = (select id from public.c_op where username = 'c_super')$q$, '3');

select public.c_expect_as('C6 superadmin deactivates the live announcement', 'c_super',
  $q$select (public.admin_deactivate_announcement(
        (select id from public.announcements where title = 'Trading hours update'), null) is not null)::text$q$,
  'true');

select public.c_expect('C6 the public feed is now empty (honest zero state)',
  $q$select count(*)::text from public.v_public_announcements$q$, '0', 'anon');

select public.c_expect('C6 the row is kept, not deleted (append-only history)',
  $q$select (count(*) = 3 and count(*) filter (where not active) = 1)::text from public.announcements$q$,
  'true');

select public.c_expect('C6 deactivation is audited with a real actor',
  $q$select count(*)::text from public.security_audit_log
        where action = 'admin.announcement.deactivated'
          and actor_id = (select id from public.c_op where username = 'c_super')$q$, '1');

select public.c_expect_error_as('C6 deactivating twice is refused', 'c_super',
  $q$select public.admin_deactivate_announcement(
        (select id from public.announcements where title = 'Trading hours update'), null)::text$q$,
  'was already deactivated');

select public.c_expect_error_as('C6 an empty active window is refused', 'c_super',
  $q$select public.admin_create_announcement('Bad window','Body text here', now(), now() - interval '1 hour', null)::text$q$,
  'the active window is empty');

select public.c_expect('C6 the announcements table is RLS-on with no client policy',
  $q$select c.relrowsecurity::text || ':' ||
          (select count(*) from pg_policies p where p.schemaname='public' and p.tablename='announcements')::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname='announcements'$q$, 'true:0');

select public.c_expect_error('C6 anon cannot read the announcements table (only the view)',
  $q$select count(*)::text from public.announcements$q$,
  'permission denied for table announcements', 'anon');

-- ===========================================================================
\echo '=== C7. v_admin_custody — ledger-derived, and honest about connectivity'
-- ===========================================================================
select public.c_expect_as('C7 superadmin sees the system accounts', 'c_super',
  $q$select (count(*) > 0)::text from public.v_admin_custody$q$, 'true');

select public.c_expect_as('C7 connectivity is not_connected on every single row', 'c_super',
  $q$select string_agg(distinct connectivity, ',') from public.v_admin_custody$q$, 'not_connected');

select public.c_expect_as('C7 ... and no row claims anything else', 'c_super',
  $q$select count(*)::text from public.v_admin_custody where connectivity <> 'not_connected'$q$, '0');

select public.c_expect_as('C7 the cached balance equals the ledger sum on every system account', 'c_super',
  $q$select count(*)::text from public.v_admin_custody where balance_units <> ledger_units$q$, '0');

select public.c_expect_as('C7 the view agrees with an independent aggregate over ledger_entries', 'c_super',
  $q$select count(*)::text from public.v_admin_custody c
        where c.ledger_units <> COALESCE((select sum(e.amount_units) from public.ledger_entries e
                                           where e.account_id = c.account_id), 0)$q$, '0');

select public.c_expect_as('C7 the expected system accounts are all present', 'c_super',
  $q$select (count(*) filter (where account_code = 'FEE_INCOME') > 0
          and count(*) filter (where account_code = 'PAPER_FAUCET') > 0)::text
        from public.v_admin_custody$q$, 'true');

select public.c_expect_as('C7 the deposit/withdrawal clearing accounts exist too', 'c_super',
  $q$select (count(*) filter (where account_code = 'EXTERNAL_DEPOSIT') > 0
          and count(*) filter (where account_code = 'WITHDRAWAL_CLEARING') > 0)::text
        from public.v_admin_custody$q$, 'true');

select public.c_expect_as('C7 every custody row is a SYSTEM account (never a customer account)', 'c_super',
  $q$select count(*)::text from public.v_admin_custody c
        join public.accounts a on a.id = c.account_id
        where a.account_type <> 'system' or a.user_id is not null$q$, '0');

select public.c_expect_as('C7 readonly (the auditor) sees custody too', 'c_ro',
  $q$select (count(*) > 0)::text from public.v_admin_custody$q$, 'true');

select public.c_expect('C7 a signed-in NON-operator sees ZERO rows',
  $q$select count(*)::text from public.v_admin_custody$q$, '0',
  'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect_error('C7 anon cannot read the custody view at all',
  $q$select count(*)::text from public.v_admin_custody$q$,
  'permission denied for view', 'anon');

-- ===========================================================================
\echo '=== C8. v_admin_liquidity — honest empty state, then real aggregates'
-- ===========================================================================
-- a brand new market has no orders, and the view must say exactly that
select public.c_expect_as('C8 superadmin creates a market that has never traded', 'c_super',
  $q$select (public.admin_upsert_market('ETH/BTC','ETH','BTC', 8::smallint, 1::numeric, 1::numeric, 2, 5, 'trading', true, 'paper', null) is not null)::text$q$,
  'true');

select public.c_expect_as('C8 an empty book shows ZERO orders, NULL best bid/ask, NULL spread, 0 depth', 'c_super',
  $q$select open_order_count::text || '/' || COALESCE(best_bid_units::text,'NULL') || '/'
          || COALESCE(best_ask_units::text,'NULL') || '/' || COALESCE(spread_units::text,'NULL') || '/'
          || bid_depth_units_5::text || '/' || ask_depth_units_5::text
        from public.v_admin_liquidity where market_symbol = 'ETH/BTC' and environment = 'paper'$q$,
  '0/NULL/NULL/NULL/0/0');

select public.c_expect_as('C8 no depth is fabricated: the empty market contributes nothing anywhere', 'c_super',
  $q$select count(*)::text from public.v_admin_liquidity
        where market_symbol = 'ETH/BTC'
          and (bid_depth_units_all <> 0 or ask_depth_units_all <> 0 or bid_level_count <> 0 or ask_level_count <> 0)$q$,
  '0');

-- real orders through the existing public entry point (place_order), not fixtures
select public.c_run('C8 a real resting BUY is placed at 100 (qty 1e15 base units)',
  $q$select public.place_order('ETH/BTC','buy','limit', 1000000000000000, 10000000000, 'gtc', null,
        '99999999-9999-9999-9999-999999990001')$q$);

select public.c_run('C8 a real resting SELL is placed at 110',
  $q$select public.place_order('ETH/BTC','sell','limit', 1000000000000000, 11000000000, 'gtc', null,
        '99999999-9999-9999-9999-999999990001')$q$);

select public.c_expect_as('C8 the view now reports 2 open orders, best bid 100, best ask 110, spread 10', 'c_super',
  $q$select open_order_count::text || '/' || best_bid_units::text || '/' || best_ask_units::text
          || '/' || spread_units::text
        from public.v_admin_liquidity where market_symbol = 'ETH/BTC' and environment = 'paper'$q$,
  '2/10000000000/11000000000/1000000000');

select public.c_expect_as('C8 depth inside 5 levels equals the resting quantity on each side', 'c_super',
  $q$select bid_depth_units_5::text || '/' || ask_depth_units_5::text
        from public.v_admin_liquidity where market_symbol = 'ETH/BTC' and environment = 'paper'$q$,
  '1000000000000000/1000000000000000');

select public.c_expect_as('C8 the spread is exactly ask - bid on every market with both sides', 'c_super',
  $q$select count(*)::text from public.v_admin_liquidity
        where best_bid_units is not null and best_ask_units is not null
          and spread_units <> best_ask_units - best_bid_units$q$, '0');

select public.c_expect_as('C8 depth inside 5 levels never exceeds the full depth', 'c_super',
  $q$select count(*)::text from public.v_admin_liquidity
        where bid_depth_units_5 > bid_depth_units_all or ask_depth_units_5 > ask_depth_units_all$q$, '0');

select public.c_expect_as('C8 the aggregates agree with the raw orders table on EVERY market', 'c_super',
  $q$select count(*)::text from public.v_admin_liquidity l
        where l.open_order_count <> (select count(*) from public.orders o
                                      where o.market_id = l.market_id
                                        and o.status in ('new','partially_filled')
                                        and o.price_units is not null
                                        and o.qty_units > o.filled_qty_units)
           or l.best_bid_units is distinct from (select max(o.price_units) from public.orders o
                                      where o.market_id = l.market_id and o.side = 'buy'
                                        and o.status in ('new','partially_filled')
                                        and o.qty_units > o.filled_qty_units)
           or l.best_ask_units is distinct from (select min(o.price_units) from public.orders o
                                      where o.market_id = l.market_id and o.side = 'sell'
                                        and o.status in ('new','partially_filled')
                                        and o.qty_units > o.filled_qty_units)$q$, '0');

select public.c_expect_as('C8 every market has exactly one row (no market is invented or dropped)', 'c_super',
  $q$select (count(*) = (select count(*) from public.markets))::text from public.v_admin_liquidity$q$, 'true');

select public.c_expect_as('C8 support sees liquidity (money.read)', 'c_supp',
  $q$select (count(*) > 0)::text from public.v_admin_liquidity$q$, 'true');

select public.c_expect('C8 a signed-in NON-operator sees ZERO rows',
  $q$select count(*)::text from public.v_admin_liquidity$q$, '0',
  'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect_error('C8 anon cannot read the liquidity view',
  $q$select count(*)::text from public.v_admin_liquidity$q$,
  'permission denied for view', 'anon');

-- ===========================================================================
\echo '=== C9. v_admin_alerts — real sources, role-scoped, a view not an engine'
-- ===========================================================================
select public.c_expect_as('C9 compliance restricts a user (a real alert source)', 'c_comp',
  $q$select (public.admin_set_restriction('99999999-9999-9999-9999-999999990002','trading',
        'C9 fixture: trading restriction', null) is not null)::text$q$, 'true');

select public.c_expect_as('C9 compliance raises a risk flag', 'c_comp',
  $q$select (public.admin_add_risk_flag('99999999-9999-9999-9999-999999990002','manual_review','high',
        'C9 fixture: manual review flag', null) is not null)::text$q$, 'true');

select public.c_expect_as('C9 the active restriction appears as an alert', 'c_super',
  $q$select count(*)::text from public.v_admin_alerts
        where user_id = '99999999-9999-9999-9999-999999990002' and alert_type = 'account_restriction'$q$,
  '1');

select public.c_expect_as('C9 the unresolved risk flag appears with its severity', 'c_super',
  $q$select severity from public.v_admin_alerts
        where user_id = '99999999-9999-9999-9999-999999990002' and alert_type = 'risk_flag'$q$, 'high');

select public.c_expect_as('C9 recent sensitive security events for that user appear', 'c_super',
  $q$select (count(*) > 0)::text from public.v_admin_alerts
        where user_id = '99999999-9999-9999-9999-999999990002' and alert_type = 'security_event'$q$, 'true');

select public.c_expect_as('C9 every alert carries a known severity and a raised_at timestamp', 'c_super',
  $q$select count(*)::text from public.v_admin_alerts
        where severity not in ('low','medium','high','critical') or raised_at is null$q$, '0');

select public.c_expect_as('C9 resolving the flag removes it from the feed', 'c_comp',
  $q$select (public.admin_resolve_risk_flag(
        (select id from public.risk_flags where user_id = '99999999-9999-9999-9999-999999990002'
           and resolved_at is null), 'C9 resolved', null) is not null)::text$q$, 'true');

select public.c_expect_as('C9 ... and the feed no longer lists it', 'c_super',
  $q$select count(*)::text from public.v_admin_alerts
        where user_id = '99999999-9999-9999-9999-999999990002' and alert_type = 'risk_flag'$q$, '0');

select public.c_expect_as('C9 support sees ZERO alerts (security.read denied)', 'c_supp',
  $q$select count(*)::text from public.v_admin_alerts$q$, '0');

select public.c_expect_as('C9 readonly (the auditor) sees them', 'c_ro',
  $q$select (count(*) > 0)::text from public.v_admin_alerts$q$, 'true');

select public.c_expect('C9 a signed-in NON-operator sees ZERO rows',
  $q$select count(*)::text from public.v_admin_alerts$q$, '0',
  'authenticated', '99999999-9999-9999-9999-999999990001');

select public.c_expect_error('C9 anon cannot read the alerts view',
  $q$select count(*)::text from public.v_admin_alerts$q$,
  'permission denied for view', 'anon');

-- ===========================================================================
\echo '=== C10. ACL surface and the "no money creation" probe'
-- ===========================================================================
select public.c_expect('C10 no new admin function is executable by anon or authenticated',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('admin_list_support_conversations','admin_get_support_conversation',
                            'admin_support_reply','admin_support_set_status',
                            'admin_send_notification','admin_broadcast_notification',
                            'admin_create_announcement','admin_deactivate_announcement')
          and (has_function_privilege('anon', p.oid, 'EXECUTE')
            or has_function_privilege('authenticated', p.oid, 'EXECUTE'))$q$, '0');

select public.c_expect('C10 every new admin function is executable by service_role (the operator call path)',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('admin_list_support_conversations','admin_get_support_conversation',
                            'admin_support_reply','admin_support_set_status',
                            'admin_send_notification','admin_broadcast_notification',
                            'admin_create_announcement','admin_deactivate_announcement')
          and not has_function_privilege('service_role', p.oid, 'EXECUTE')$q$, '0');

select public.c_expect('C10 the one user-facing function is callable by authenticated and not by anon',
  $q$select has_function_privilege('authenticated','public.user_mark_notification_read(uuid)','EXECUTE')::text
        || '/' || has_function_privilege('anon','public.user_mark_notification_read(uuid)','EXECUTE')::text$q$,
  'true/false');

select public.c_expect('C10 no function in this migration can create or move money',
  $q$select coalesce(string_agg(p.proname, ','), '(none)') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('admin_list_support_conversations','admin_get_support_conversation',
                            'admin_support_reply','admin_support_set_status',
                            'admin_send_notification','admin_broadcast_notification',
                            'admin_create_announcement','admin_deactivate_announcement',
                            'user_mark_notification_read')
          and (p.prosrc ilike '%insert into public.balances%' or p.prosrc ilike '%update public.balances%'
            or p.prosrc ilike '%insert into public.accounts%' or p.prosrc ilike '%update public.accounts%'
            or p.prosrc ilike '%insert into public.ledger_transactions%'
            or p.prosrc ilike '%insert into public.ledger_entries%'
            or p.prosrc ilike '%post_entry(%' or p.prosrc ilike '%settle_fill(%'
            or p.prosrc ilike '%system_account_id(%' or p.prosrc ilike '%ensure_user_account(%')$q$,
  '(none)');

select public.c_expect('C10 notifications has RLS on with exactly one (own-or-broadcast SELECT) policy',
  $q$select c.relrowsecurity::text || ':' ||
          (select count(*) from pg_policies p where p.schemaname='public' and p.tablename='notifications')::text
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname='public' and c.relname='notifications'$q$, 'true:1');

select public.c_expect('C10 ... and that policy only grants SELECT',
  $q$select string_agg(distinct cmd, ',') from pg_policies
        where schemaname='public' and tablename='notifications'$q$, 'SELECT');

select public.c_expect('C10 the public announcement view is the only anon-readable new surface',
  $q$select has_table_privilege('anon','public.v_public_announcements','SELECT')::text
        || '/' || has_table_privilege('anon','public.v_admin_custody','SELECT')::text
        || '/' || has_table_privilege('anon','public.notifications','SELECT')::text$q$,
  'true/false/false');

-- ===========================================================================
\echo '=== C11. the safety gate is untouched by this suite'
-- ===========================================================================
select public.c_expect('C11 app_settings is byte-identical to the snapshot taken before this suite',
  $q$select count(*)::text from (
        select mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled,
               paper_deposits_enabled, paper_withdrawals_enabled, kyc_required_for_trading, maintenance_mode
          from public.app_settings
        except
        select * from public.c_settings_snapshot
      ) x$q$, '0');

select public.c_expect('C11 every LIVE_* flag is still false and the mode is still paper',
  $q$select mode || '/' || live_trading_enabled::text from public.app_settings$q$, 'paper/false');

select public.c_expect('C11 the ledger is still balanced after this suite',
  $q$select count(*)::text from (
        select t.id from public.ledger_transactions t
          join public.ledger_entries e on e.transaction_id = t.id
         group by t.id having sum(e.amount_units) <> 0) x$q$, '0');

select public.c_expect('C11 every balance still equals its ledger sum',
  $q$select count(*)::text from public.balances b
        where COALESCE(b.available_units,0) + COALESCE(b.locked_units,0)
              <> COALESCE((select sum(e.amount_units) from public.ledger_entries e
                            where e.account_id = b.account_id), 0)$q$, '0');

select public.c_expect('C11 every operator audit row this suite wrote names an existing operator',
  $q$select count(*)::text from public.security_audit_log a
        where (a.action like 'admin.support.%' or a.action like 'admin.notification.%'
               or a.action like 'admin.announcement.%')
          and (a.actor_id is null or not exists (select 1 from public.admin_users u where u.id = a.actor_id))$q$,
  '0');

select public.c_expect('C11 no notification, announcement or alert was seeded by the migration itself',
  $q$select (select count(*) from public.notifications)::text || '/'
        || (select count(*) from public.announcements)::text$q$, '3/3');

\echo '=== SUMMARY'
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from public.c_res;
select count(*) filter (where not ok) as failures from public.c_res;
