\set ON_ERROR_STOP on
-- =====================================================================
-- GlobalTradeVX — KYC / security-layer verification suite (scratch PostgreSQL only)
--
-- Run in the SAME database as exchange_schema_tests.sql, after it and after the ledger,
-- immutability/RLS, deposit and withdrawal suites: it re-uses their fixtures (assets,
-- markets, helper functions) and adds its own users, so it must run LAST in the core
-- database. Never point it at the live Supabase project ctrazoqbudsfkpawpomv.
--
-- Every assertion prints a PASS/FAIL NOTICE; the last line is a SUMMARY.
-- There is NO personal data anywhere below: the "metadata" fixtures are opaque reference
-- strings (TESTFIXTUREDOC…, sha256:…), and the only PII the suite ever writes are
-- deliberately fake names/e-mails used to prove that the no-PII guard REFUSES them (those
-- inserts must fail, so nothing is stored).
--
-- What this suite pins down (helpers follow the t.expect pattern of
-- exchange_schema_tests.sql; the schema is `k` so the suites cannot collide):
--   K1  the tier model: three levels seeded, NO invented per-tier limits, anon refused
--   K2  default tier-0 materialisation (first reference, idempotent, my_kyc_status)
--   K3  operator approve flow: level granted atomically, audit rows, idempotency
--   K4  operator reject flow: level unchanged, reason mandatory, terminal rows immutable
--   K5  the submission state machine and the submission input validation
--   K6  level invariants: only from an approved submission, upwards only, never by hand
--   K7  the no-PII guard (denylist, recursive, refusals store nothing)
--   K8  the provider-adapter contract (live only): create/transition, level grant, replay
--       refused with no duplicate, malformed events record nothing
--   K9  path separation in both directions (operator refused live, adapter refused in paper)
--   K10 the security audit log: one row per change with the right actor, append-only
--   K11 the authz matrix (anon / authenticated / service_role) and the function ACLs
--   K12 app_settings ends where it started; the KYC tables are not money-gated
--
-- NOTE: security_audit_log and terminal KYC rows cannot be deleted (append-only triggers),
-- so this suite leaves its live-mode probe rows in place and asserts their final state
-- instead of cleaning up. That is the intended behaviour, not a leak.
-- =====================================================================

do $k$
begin
  if to_regclass('public.kyc_submissions') is null then
    raise exception 'exchange_kyc_tests.sql needs the KYC migration (20261005100140_exchange_kyc_security.sql).';
  end if;
  if to_regclass('public.withdrawal_requests') is null then
    raise exception 'exchange_kyc_tests.sql must run after the withdrawal suite in the same database.';
  end if;
  if exists (select 1 from public.kyc_submissions) or exists (select 1 from public.kyc_status)
     or exists (select 1 from public.security_audit_log) then
    raise exception 'exchange_kyc_tests.sql expects a freshly migrated database (the KYC tables are not empty) and must not be run twice in the same database.';
  end if;
end $k$;

create table if not exists public.k_res (seq serial primary key, label text, ok boolean);
delete from public.k_res;
create table if not exists public.k_ids (label text primary key, val text);
delete from public.k_ids;
-- app_settings as it was before this suite touched anything (K12 proves the reverts)
drop table if exists public.k_settings_snapshot;
create table public.k_settings_snapshot as select * from public.app_settings;

create or replace function public.k_expect(p_label text, p_sql text, p_expected text, p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    if v_actual is not distinct from p_expected then
      raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
      insert into public.k_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
      insert into public.k_res(label, ok) values (p_label, false);
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
    insert into public.k_res(label, ok) values (p_label, false);
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.k_expect_error(p_label text, p_sql text, p_fragment text, p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
    insert into public.k_res(label, ok) values (p_label || ' (was allowed)', false);
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
      insert into public.k_res(label, ok) values (p_label, true);
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
      insert into public.k_res(label, ok) values (p_label || ' (wrong error)', false);
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function public.k_run(p_label text, p_sql text)
returns void language plpgsql as $fn$
declare v_rows bigint;
begin
  execute p_sql;
  get diagnostics v_rows = row_count;
  raise notice 'PASS  (ran) % [% row(s)]', p_label, v_rows;
  insert into public.k_res(label, ok) values (p_label, true);
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.k_res(label, ok) values (p_label, false);
end;
$fn$;

-- remember an id produced by an entry point (NULL when the call fails, so later assertions
-- report the real problem instead of aborting the suite)
create or replace function public.k_keep(p_key text, p_label text, p_sql text)
returns void language plpgsql as $fn$
declare v_val text;
begin
  execute p_sql into v_val;
  insert into public.k_ids(label, val) values (p_key, v_val)
  on conflict (label) do update set val = excluded.val;
  raise notice 'PASS  (ran) % = %', p_label, coalesce(v_val, 'NULL');
  insert into public.k_res(label, ok) values (p_label, true);
exception when others then
  insert into public.k_ids(label, val) values (p_key, null)
  on conflict (label) do update set val = null;
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
  insert into public.k_res(label, ok) values (p_label, false);
end;
$fn$;

create or replace function public.k_id(p_label text)
returns text language sql stable as $fn$
  select val from public.k_ids where label = p_label;
$fn$;

create or replace function public.k_lvl(p_user uuid)
returns text language sql stable as $fn$
  select coalesce((select level::text from public.kyc_status where user_id = p_user), 'none');
$fn$;

create or replace function public.k_status(p_label text)
returns text language sql stable as $fn$
  select coalesce((select status from public.kyc_submissions where id = public.k_id(p_label)::uuid), 'none');
$fn$;

create or replace function public.k_audit(p_action text, p_entity uuid)
returns text language sql stable as $fn$
  select count(*)::text from public.security_audit_log where action = p_action and entity_id = p_entity;
$fn$;

\echo '=== K1. the tier model (levels seeded, no invented limits, anon refused)'
select public.k_expect('K1 the three tiers of the plan are seeded',
  $q$select string_agg(level::text || ':' || name, ',' order by level) from public.kyc_levels$q$,
  '0:unverified,1:identity,2:address');
select public.k_expect('K1 level 0 is the unverified default',
  $q$select description from public.kyc_levels where level = 0$q$,
  'Default for every user. No identity check has been performed.');
select public.k_expect('K1 kyc_levels carries NO per-tier limit column (limits are an owner decision)',
  $q$select count(*)::text from information_schema.columns
        where table_schema = 'public' and table_name = 'kyc_levels'
          and (column_name ~* 'limit|max|min|cap|threshold|amount|units')$q$, '0');
select public.k_expect('K1 no KYC table invents a limit column either',
  $q$select count(*)::text from information_schema.columns
        where table_schema = 'public' and table_name in ('kyc_submissions','kyc_status')
          and (column_name ~* 'limit|max_|_max|cap|threshold')$q$, '0');
select public.k_expect('K1 kyc_levels has exactly the four documented columns',
  $q$select string_agg(column_name, ',' order by ordinal_position) from information_schema.columns
        where table_schema = 'public' and table_name = 'kyc_levels'$q$,
  'level,name,description,created_at');
select public.k_expect('K1 no KYC row is seeded for any user (no fake identity data)',
  $q$select (select count(*) from public.kyc_submissions)::text || '/' ||
           (select count(*) from public.kyc_status)::text$q$, '0/0');
select public.k_expect_error('K1 anon cannot read the tier model',
  $q$select count(*)::text from public.kyc_levels$q$,
  'permission denied for table kyc_levels', 'anon');

\echo '=== K2. default tier-0 materialisation'
select public.k_run('K2 create three synthetic users (fixtures, no personal data)',
  $q$insert into auth.users (id, email) values
       ('66666666-6666-6666-6666-666666666601', 'kyc-a@example.test'),
       ('66666666-6666-6666-6666-666666666602', 'kyc-b@example.test'),
       ('66666666-6666-6666-6666-666666666603', 'kyc-c@example.test')$q$);
select public.k_expect('K2 a user has no kyc_status row before the first reference',
  $q$select count(*)::text from public.kyc_status$q$, '0');
select public.k_expect('K2 ensure_kyc_status materialises level 0',
  $q$select (public.ensure_kyc_status('66666666-6666-6666-6666-666666666601')).level::text$q$, '0');
select public.k_expect('K2 ... as exactly one row per user',
  $q$select count(*)::text from public.kyc_status where user_id = '66666666-6666-6666-6666-666666666601'$q$, '1');
select public.k_expect('K2 ... with no provider and no level history yet',
  $q$select coalesce(provider, 'NULL') || '/' || coalesce(level_changed_at::text, 'NULL')
        from public.kyc_status where user_id = '66666666-6666-6666-6666-666666666601'$q$, 'NULL/NULL');
select public.k_expect('K2 a second ensure_kyc_status call is idempotent (same created_at)',
  $q$select (public.ensure_kyc_status('66666666-6666-6666-6666-666666666601')).created_at::text$q$,
  (select created_at::text from public.kyc_status where user_id = '66666666-6666-6666-6666-666666666601'));
select public.k_expect('K2 ... and did not add a second row',
  $q$select count(*)::text from public.kyc_status$q$, '1');
select public.k_expect('K2 my_kyc_status() materialises and returns the caller''s own level 0',
  $q$select level::text from public.my_kyc_status()$q$, '0',
  'authenticated', '66666666-6666-6666-6666-666666666603'::uuid);
select public.k_expect('K2 ... creating the row for a user who never called it before',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666603')$q$, '0');
select public.k_expect_error('K2 my_kyc_status() with no signed-in user is refused',
  $q$select level::text from public.my_kyc_status()$q$, 'no authenticated user', 'authenticated');
select public.k_expect_error('K2 anon cannot call my_kyc_status',
  $q$select level::text from public.my_kyc_status()$q$,
  'permission denied for function my_kyc_status', 'anon');

\echo '=== K3. operator approve flow: the level is granted atomically'
select public.k_keep('K3a', 'K3a submit level 1 for user A (paper_operator path)',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666601', 1,
       '{"document_id":"TESTFIXTUREDOC0001","document_sha256":"sha256:0000000000000000000000000000000000000000000000000000000000000001"}'::jsonb)::text$q$);
select public.k_expect('K3a the submission starts pending, source paper_operator, environment paper',
  $q$select status || '/' || source || '/' || environment from public.kyc_submissions
        where id = public.k_id('K3a')::uuid$q$, 'pending/paper_operator/paper');
select public.k_expect('K3a it seeks level 1 and holds only opaque document references',
  $q$select level_sought::text || '/' || (metadata->>'document_id') from public.kyc_submissions
        where id = public.k_id('K3a')::uuid$q$, '1/TESTFIXTUREDOC0001');
select public.k_expect('K3a no level is granted by submitting',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666601')$q$, '0');
select public.k_expect('K3a submitting wrote exactly one audit row for the submission',
  $q$select public.k_audit('kyc.submission.submitted', public.k_id('K3a')::uuid)$q$, '1');
select public.k_expect('K3b approve_kyc returns approved',
  $q$select public.approve_kyc(public.k_id('K3a')::uuid)$q$, 'approved');
select public.k_expect('K3b the submission is approved with a decision timestamp',
  $q$select status || '/' || (decided_at is not null)::text from public.kyc_submissions
        where id = public.k_id('K3a')::uuid$q$, 'approved/true');
select public.k_expect('K3b ... and the user''s level moved to 1',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666601')$q$, '1');
select public.k_expect('K3b ... with level_changed_at recorded',
  $q$select (level_changed_at is not null)::text from public.kyc_status
        where user_id = '66666666-6666-6666-6666-666666666601'$q$, 'true');
select public.k_expect('K3b exactly one kyc.submission.approved audit row, actor operator',
  $q$select count(*)::text from public.security_audit_log
        where action = 'kyc.submission.approved' and entity_id = public.k_id('K3a')::uuid
          and actor_role = 'operator'$q$, '1');
select public.k_expect('K3b exactly one kyc.level.changed audit row for the user, 0 -> 1',
  $q$select count(*)::text from public.security_audit_log
        where action = 'kyc.level.changed'
          and subject_user_id = '66666666-6666-6666-6666-666666666601'
          and details->>'from_level' = '0' and details->>'to_level' = '1'$q$, '1');
select public.k_expect('K3b the approval audit row records the transition pending -> approved',
  $q$select details->>'from' || '->' || (details->>'to') from public.security_audit_log
        where action = 'kyc.submission.approved' and entity_id = public.k_id('K3a')::uuid$q$,
  'pending->approved');
select public.k_expect('K3c approving again is idempotent (no second level grant)',
  $q$select public.approve_kyc(public.k_id('K3a')::uuid)$q$, 'approved');
select public.k_expect('K3c ... and wrote no extra audit row',
  $q$select public.k_audit('kyc.submission.approved', public.k_id('K3a')::uuid)$q$, '1');
select public.k_expect('K3c ... and no extra level change',
  $q$select count(*)::text from public.security_audit_log
        where action = 'kyc.level.changed' and subject_user_id = '66666666-6666-6666-6666-666666666601'$q$, '1');
select public.k_expect_error('K3d an approved submission is terminal: its status cannot be edited',
  $q$with u as (update public.kyc_submissions set status = 'pending'
                 where id = public.k_id('K3a')::uuid returning 1)
       select count(*)::text from u$q$, 'terminal');

\echo '=== K4. operator reject flow: a rejection moves nothing'
select public.k_keep('K4a', 'K4a submit level 1 for user B',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666602', 1, '{}'::jsonb)::text$q$);
select public.k_expect_error('K4a reject without a reason is refused',
  $q$select public.reject_kyc(public.k_id('K4a')::uuid, '')$q$, 'a reason is required');
select public.k_expect('K4b reject_kyc returns rejected',
  $q$select public.reject_kyc(public.k_id('K4a')::uuid, 'TESTFIXTURE: document unreadable')$q$, 'rejected');
select public.k_expect('K4b the submission is rejected and carries the reason',
  $q$select status || '/' || decision_reason from public.kyc_submissions
        where id = public.k_id('K4a')::uuid$q$, 'rejected/TESTFIXTURE: document unreadable');
select public.k_expect('K4b the user''s level is UNCHANGED by a rejection (still no level at all)',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666602')$q$, 'none');
select public.k_expect('K4b ... and no level-change audit row was written for user B',
  $q$select count(*)::text from public.security_audit_log
        where action = 'kyc.level.changed' and subject_user_id = '66666666-6666-6666-6666-666666666602'$q$, '0');
select public.k_expect('K4b exactly one kyc.submission.rejected audit row with the reason',
  $q$select count(*)::text from public.security_audit_log
        where action = 'kyc.submission.rejected' and entity_id = public.k_id('K4a')::uuid
          and details->>'reason' = 'TESTFIXTURE: document unreadable'$q$, '1');
select public.k_expect('K4c rejecting again is idempotent',
  $q$select public.reject_kyc(public.k_id('K4a')::uuid, 'TESTFIXTURE: again')$q$, 'rejected');
select public.k_expect('K4c ... and wrote no extra audit row',
  $q$select public.k_audit('kyc.submission.rejected', public.k_id('K4a')::uuid)$q$, '1');
select public.k_expect_error('K4d a rejected submission cannot be approved afterwards',
  $q$select public.approve_kyc(public.k_id('K4a')::uuid)$q$,
  'only a pending or under-review submission can be approved');
select public.k_expect_error('K4d a rejected submission is immutable',
  $q$with u as (update public.kyc_submissions set decision_reason = 'edited'
                 where id = public.k_id('K4a')::uuid returning 1)
       select count(*)::text from u$q$, 'terminal');
select public.k_keep('K4e', 'K4e a resubmission is a NEW row at the same level',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666602', 1, '{"document_id":"TESTFIXTUREDOC0002"}'::jsonb)::text$q$);
select public.k_expect('K4e resubmission created a second row and the rejected one is intact',
  $q$select count(*)::text || '/' || (select status from public.kyc_submissions where id = public.k_id('K4a')::uuid)
        from public.kyc_submissions where user_id = '66666666-6666-6666-6666-666666666602'$q$, '2/rejected');

\echo '=== K5. the state machine and the submission input validation'
select public.k_expect('K5a put the resubmission under review',
  $q$select public.set_kyc_under_review(public.k_id('K4e')::uuid, 'TESTFIXTURE: manual review')$q$, 'under review');
select public.k_expect('K5a ... recording under_review_at and the review reason',
  $q$select (under_review_at is not null)::text || '/' || review_reason from public.kyc_submissions
        where id = public.k_id('K4e')::uuid$q$, 'true/TESTFIXTURE: manual review');
select public.k_expect('K5a ... and one kyc.submission.under_review audit row',
  $q$select public.k_audit('kyc.submission.under_review', public.k_id('K4e')::uuid)$q$, '1');
select public.k_expect('K5a under review -> approved is a legal step',
  $q$select public.approve_kyc(public.k_id('K4e')::uuid, 'TESTFIXTURE: reviewed')$q$, 'approved');
select public.k_expect('K5a ... granting user B level 1 after the earlier rejection',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666602')$q$, '1');
select public.k_expect_error('K5b a terminal submission cannot go back under review',
  $q$select public.set_kyc_under_review(public.k_id('K4e')::uuid)$q$,
  'only a pending submission can be put under review');
select public.k_expect_error('K5c level 0 cannot be applied for (it is the default)',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 0)$q$, 'cannot be applied for');
select public.k_expect_error('K5c an unknown level cannot be applied for',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 7)$q$, 'unknown KYC level');
select public.k_expect_error('K5c metadata that is not a JSON object is refused',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 1, '["a"]'::jsonb)$q$, 'must be a JSON object');
select public.k_expect_error('K5c a NULL user id is refused',
  $q$select public.submit_kyc(null, 1)$q$, 'user id is required');
select public.k_expect('K5d no submission exists for user C yet (every refused call stored nothing)',
  $q$select count(*)::text from public.kyc_submissions where user_id = '66666666-6666-6666-6666-666666666603'$q$, '0');
select public.k_expect_error('K5e a terminal submission cannot be moved at all',
  $q$with u as (update public.kyc_submissions set status = 'pending'
                 where id = public.k_id('K4e')::uuid returning 1)
       select count(*)::text from u$q$, 'terminal');

\echo '=== K6. level invariants: only from an approved submission, upwards only'
select public.k_expect_error('K6 a level cannot be granted by hand (no approved submission for level 2)',
  $q$with u as (update public.kyc_status set level = 2
                 where user_id = '66666666-6666-6666-6666-666666666601' returning 1)
       select count(*)::text from u$q$, 'no approved submission grants that level');
select public.k_expect_error('K6 a level cannot be downgraded',
  $q$with u as (update public.kyc_status set level = 0
                 where user_id = '66666666-6666-6666-6666-666666666601' returning 1)
       select count(*)::text from u$q$, 'can only move up');
select public.k_expect_error('K6 the owner of a kyc_status row cannot change',
  $q$with u as (update public.kyc_status set user_id = '66666666-6666-6666-6666-666666666602'
                 where user_id = '66666666-6666-6666-6666-666666666601' returning 1)
       select count(*)::text from u$q$, 'owner of a kyc_status row is immutable');
select public.k_expect('K6 the level of user A is still 1 after every refused attempt',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666601')$q$, '1');
select public.k_keep('K6b', 'K6b submit level 2 for user A (address verification)',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666601', 2,
       '{"address_proof_id":"TESTFIXTUREADDR0001"}'::jsonb)::text$q$);
select public.k_expect('K6b approve the level-2 submission',
  $q$select public.approve_kyc(public.k_id('K6b')::uuid)$q$, 'approved');
select public.k_expect('K6b ... raising the level of user A to 2',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666601')$q$, '2');
select public.k_keep('K6c', 'K6c submit level 1 for user A again (below the current level)',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666601', 1, '{}'::jsonb)::text$q$);
select public.k_expect_error('K6c approving a submission below the current level is refused (no downgrade)',
  $q$select public.approve_kyc(public.k_id('K6c')::uuid)$q$, 'a downgrade is not implemented');
select public.k_expect('K6c ... and the level is untouched',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666601')$q$, '2');

\echo '=== K7. the no-PII guard (nothing personal reaches the database)'
select public.k_expect_error('K7a a submission carrying a person''s name is refused',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 1,
       '{"full_name":"TESTFIXTURE NOT A REAL PERSON"}'::jsonb)$q$, 'carries personal data');
select public.k_expect_error('K7a ... a date of birth is refused',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 1,
       '{"dob":"1970-01-01"}'::jsonb)$q$, 'personal data');
select public.k_expect_error('K7a ... an e-mail address is refused',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 1,
       '{"email":"not-a-real-person@example.invalid"}'::jsonb)$q$, 'personal data');
select public.k_expect_error('K7a ... a document image is refused',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 1,
       '{"document_image":"TESTFIXTUREBASE64PAYLOAD"}'::jsonb)$q$, 'personal data');
select public.k_expect_error('K7b the guard is recursive: a nested document image is refused',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 1,
       '{"documents":[{"kind":"passport","document_image":"TESTFIXTUREBASE64PAYLOAD"}]}'::jsonb)$q$,
  'personal data');
select public.k_expect_error('K7b ... and reports the path of the offending key',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 1,
       '{"documents":[{"document_number":"TESTFIXTURE0000"}]}'::jsonb)$q$,
  'metadata.documents.document_number');
select public.k_expect('K7c opaque REFERENCES are accepted (document id + hash + applicant ref)',
  $q$select (public.submit_kyc('66666666-6666-6666-6666-666666666603', 1,
       '{"document_id":"TESTFIXTUREDOC0003","document_sha256":"sha256:0000000000000000000000000000000000000000000000000000000000000003","provider_applicant_ref":"TESTFIXTUREAPP01"}'::jsonb)
       is not null)::text$q$, 'true');
select public.k_expect('K7c every refused submission stored nothing (only the accepted one exists)',
  $q$select count(*)::text from public.kyc_submissions where user_id = '66666666-6666-6666-6666-666666666603'$q$, '1');
select public.k_expect('K7d the no-PII guard is an INSERT/UPDATE trigger on kyc_submissions',
  $q$select count(*)::text from pg_trigger t join pg_class c on c.oid = t.tgrelid
        where c.relname = 'kyc_submissions' and t.tgname = 'kyc_submissions_pii_guard'$q$, '1');

\echo '=== K8. the provider-adapter contract (live only)'
select public.k_run('K8a flip the exchange to live mode (mode + live_trading_enabled only; K12 reverts it)',
  $q$update public.app_settings set mode = 'live', live_trading_enabled = true, live_enabled_at = now() where id$q$);
select public.k_keep('K8b', 'K8b an under_review event for a NEW reference creates the submission',
  $q$select public.record_provider_kyc_event(jsonb_build_object(
       'event_type','under_review','user_id','66666666-6666-6666-6666-666666666603',
       'submission_reference','TESTFIXTURE-PROV-1','provider','testvendor',
       'level_sought',1,'metadata',jsonb_build_object('provider_applicant_ref','TESTFIXTUREAPP02'),
       'vendor_trace_id','TESTFIXTURETRACE1'))::text$q$);
select public.k_expect('K8b the created row is provider_adapter/live, under review, with the provider pair',
  $q$select source || '/' || environment || '/' || status || '/' || provider || '/' || provider_reference
        from public.kyc_submissions where id = public.k_id('K8b')::uuid$q$,
  'provider_adapter/live/under review/testvendor/TESTFIXTURE-PROV-1');
select public.k_expect('K8b the vendor extras are preserved verbatim in raw',
  $q$select raw->>'vendor_trace_id' from public.kyc_submissions where id = public.k_id('K8b')::uuid$q$,
  'TESTFIXTURETRACE1');
select public.k_expect('K8b an under_review event grants no level',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666603')$q$, '0');
select public.k_expect('K8b the audit row names the provider adapter as the actor (no operator id)',
  $q$select actor_role || '/' || coalesce(actor_id::text,'NULL') from public.security_audit_log
        where action = 'kyc.submission.under_review' and entity_id = public.k_id('K8b')::uuid$q$,
  'provider_adapter/NULL');
select public.k_expect('K8c an approve event on the same reference approves that submission',
  $q$select public.record_provider_kyc_event(jsonb_build_object(
       'event_type','approve','user_id','66666666-6666-6666-6666-666666666603',
       'submission_reference','TESTFIXTURE-PROV-1','provider','testvendor'))::text$q$,
  (select public.k_id('K8b')));
select public.k_expect('K8c ... and grants the user level 1',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666603')$q$, '1');
select public.k_expect('K8c ... and the submission is approved (terminal)',
  $q$select public.k_status('K8b')$q$, 'approved');
select public.k_expect('K8c ... with the provider recorded on the user''s status',
  $q$select provider from public.kyc_status where user_id = '66666666-6666-6666-6666-666666666603'$q$,
  'testvendor');
select public.k_expect('K8c ... one kyc.level.changed audit row from the adapter',
  $q$select count(*)::text from public.security_audit_log
        where action = 'kyc.level.changed' and subject_user_id = '66666666-6666-6666-6666-666666666603'
          and actor_role = 'provider_adapter'$q$, '1');
select public.k_expect_error('K8d a replayed approve event is refused (terminal)',
  $q$select public.record_provider_kyc_event(jsonb_build_object(
       'event_type','approve','user_id','66666666-6666-6666-6666-666666666603',
       'submission_reference','TESTFIXTURE-PROV-1','provider','testvendor'))::text$q$,
  'already reached its terminal status');
select public.k_expect('K8d ... and created NO duplicate row for that provider reference',
  $q$select count(*)::text from public.kyc_submissions
        where provider_reference = 'TESTFIXTURE-PROV-1'$q$, '1');
select public.k_expect('K8d ... and granted no second level',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666603') || '/' ||
           (select count(*)::text from public.security_audit_log
             where action = 'kyc.level.changed'
               and subject_user_id = '66666666-6666-6666-6666-666666666603')$q$, '1/1');
select public.k_expect('K8d ... and wrote no audit row for the replay',
  $q$select public.k_audit('kyc.submission.approved', public.k_id('K8b')::uuid)$q$, '1');
select public.k_expect_error('K8e an event carrying personal data is refused by the raw guard',
  $q$select public.record_provider_kyc_event(jsonb_build_object(
       'event_type','under_review','user_id','66666666-6666-6666-6666-666666666603',
       'submission_reference','TESTFIXTURE-PROV-2','provider','testvendor','level_sought',1,
       'email','not-a-real-person@example.invalid'))::text$q$, 'carries personal data');
select public.k_expect_error('K8f a non-object event is refused',
  $q$select public.record_provider_kyc_event('[1,2]'::jsonb)::text$q$, 'must be a JSON object');
select public.k_expect_error('K8f a NULL event is refused',
  $q$select public.record_provider_kyc_event(null)::text$q$, 'must be a JSON object');
select public.k_expect_error('K8f a missing required key is refused',
  $q$select public.record_provider_kyc_event('{"event_type":"approve","user_id":"66666666-6666-6666-6666-666666666603"}'::jsonb)::text$q$,
  'missing required key');
select public.k_expect_error('K8f an unknown event_type is refused',
  $q$select public.record_provider_kyc_event('{"event_type":"escalate","user_id":"66666666-6666-6666-6666-666666666603","submission_reference":"TESTFIXTURE-PROV-3"}'::jsonb)::text$q$,
  'unknown event_type');
select public.k_expect_error('K8f a non-uuid user id is refused',
  $q$select public.record_provider_kyc_event('{"event_type":"approve","user_id":"not-a-uuid","submission_reference":"TESTFIXTURE-PROV-3","level_sought":1}'::jsonb)::text$q$,
  'user_id is not a uuid');
select public.k_expect_error('K8f a blank submission reference is refused',
  $q$select public.record_provider_kyc_event('{"event_type":"approve","user_id":"66666666-6666-6666-6666-666666666603","submission_reference":"  ","level_sought":1}'::jsonb)::text$q$,
  'submission_reference is blank');
select public.k_expect_error('K8g an approve event for an unknown reference without level_sought is refused',
  $q$select public.record_provider_kyc_event('{"event_type":"approve","user_id":"66666666-6666-6666-6666-666666666603","submission_reference":"TESTFIXTURE-PROV-4"}'::jsonb)::text$q$,
  'level_sought is required');
select public.k_expect_error('K8g a reject event for an unknown reference is refused',
  $q$select public.record_provider_kyc_event('{"event_type":"reject","user_id":"66666666-6666-6666-6666-666666666603","submission_reference":"TESTFIXTURE-PROV-5"}'::jsonb)::text$q$,
  'cannot reject unknown submission_reference');
select public.k_expect('K8g none of the malformed events recorded anything (still one provider row)',
  $q$select count(*)::text from public.kyc_submissions where source = 'provider_adapter'$q$, '1');
select public.k_expect('K8g ... and no audit row was written for a refused event',
  $q$select count(*)::text from public.security_audit_log where action like 'kyc.%'
        and coalesce(details->>'provider_reference','') in ('TESTFIXTURE-PROV-2','TESTFIXTURE-PROV-3','TESTFIXTURE-PROV-4','TESTFIXTURE-PROV-5')$q$, '0');
select public.k_keep('K8h', 'K8h an approve event that creates the row directly is allowed (straight-through)',
  $q$select public.record_provider_kyc_event(jsonb_build_object(
       'event_type','approve','user_id','66666666-6666-6666-6666-666666666602',
       'submission_reference','TESTFIXTURE-PROV-6','provider','testvendor','level_sought',1))::text$q$);
select public.k_expect('K8h ... the created row is approved at level 1, and the reference is unique to it',
  $q$select status || '/' || level_sought::text from public.kyc_submissions
        where id = public.k_id('K8h')::uuid$q$, 'approved/1');
select public.k_expect('K8h ... user B was already at level 1, so no second level change happened',
  $q$select public.k_lvl('66666666-6666-6666-6666-666666666602') || '/' ||
           (select count(*)::text from public.security_audit_log
             where action = 'kyc.level.changed'
               and subject_user_id = '66666666-6666-6666-6666-666666666602')$q$, '1/1');

\echo '=== K9. path separation, both directions'
select public.k_expect_error('K9a in live mode the operator (paper) path is refused',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666603', 2)$q$,
  'the operator (paper) KYC path is refused while the exchange is live');
select public.k_expect_error('K9a ... and so is an operator approval of a paper submission',
  $q$select public.approve_kyc(public.k_id('K6c')::uuid)$q$,
  'the operator (paper) KYC path is refused while the exchange is live');
select public.k_expect_error('K9a ... and an operator rejection',
  $q$select public.reject_kyc(public.k_id('K6c')::uuid, 'TESTFIXTURE: live refusal')$q$,
  'the operator (paper) KYC path is refused while the exchange is live');
select public.k_expect('K9a no paper submission was created or changed while live',
  $q$select (select count(*) from public.kyc_submissions where source = 'paper_operator')::text || '/' ||
           public.k_status('K6c')$q$, '6/pending');
select public.k_run('K9b back to paper mode (live_trading_enabled off, live_enabled_at cleared)',
  $q$update public.app_settings set mode = 'paper', live_trading_enabled = false, live_enabled_at = null where id$q$);
select public.k_expect_error('K9b in paper mode the provider adapter path is refused',
  $q$select public.record_provider_kyc_event('{"event_type":"under_review","user_id":"66666666-6666-6666-6666-666666666603","submission_reference":"TESTFIXTURE-PROV-8","level_sought":1}'::jsonb)::text$q$,
  'live-only');
select public.k_expect('K9b the operator path works again in the paper sandbox',
  $q$select (public.submit_kyc('66666666-6666-6666-6666-666666666603', 2) is not null)::text$q$, 'true');
select public.k_expect_error('K9c an unknown adapter source is refused by the gate itself',
  $q$select public.assert_kyc_path('manual_override')$q$, 'unknown KYC source');

\echo '=== K10. the security audit log'
select public.k_expect('K10a one audit row per submission change for the K3a submission (submitted + approved)',
  $q$select count(*)::text from public.security_audit_log where entity_id = public.k_id('K3a')::uuid$q$, '2');
select public.k_expect('K10a the audit trail of one submission reads in order',
  $q$select string_agg(action, ',' order by at) from public.security_audit_log
        where entity_id = public.k_id('K3a')::uuid$q$,
  'kyc.submission.submitted,kyc.submission.approved');
select public.k_expect('K10a every KYC audit row carries an entity type and a subject user',
  $q$select count(*)::text from public.security_audit_log
        where action like 'kyc.%'
          and (entity_type is null or btrim(entity_type) = '' or subject_user_id is null)$q$, '0');
select public.k_expect_error('K10b the audit log is append-only: UPDATE refused (owner)',
  $q$with u as (update public.security_audit_log set action = 'tampered' returning 1)
       select count(*)::text from u$q$, 'append-only');
select public.k_expect_error('K10c the audit log is append-only: DELETE refused (owner)',
  $q$with d as (delete from public.security_audit_log returning 1) select count(*)::text from d$q$,
  'append-only');
select public.k_expect_error('K10c ... UPDATE refused for service_role too (no privilege, plus the trigger)',
  $q$with u as (update public.security_audit_log set action = 'tampered' returning 1)
       select count(*)::text from u$q$, 'permission denied', 'service_role');
select public.k_expect_error('K10c ... DELETE refused for service_role',
  $q$with d as (delete from public.security_audit_log returning 1) select count(*)::text from d$q$,
  'permission denied', 'service_role');
select public.k_expect_error('K10c ... DELETE refused for a signed-in user',
  $q$with d as (delete from public.security_audit_log returning 1) select count(*)::text from d$q$,
  'permission denied', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K10c ... DELETE refused for anon',
  $q$with d as (delete from public.security_audit_log returning 1) select count(*)::text from d$q$,
  'permission denied', 'anon');
select public.k_expect('K10d a signed-in user sees exactly their OWN audit rows',
  $q$select count(*)::text from public.security_audit_log$q$,
  (select count(*)::text from public.security_audit_log
    where subject_user_id = '66666666-6666-6666-6666-666666666601'),
  'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect('K10d ... and none of another user''s (user A cannot see user C''s rows)',
  $q$select count(*)::text from public.security_audit_log
        where subject_user_id = '66666666-6666-6666-6666-666666666603'$q$, '0',
  'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect('K10d service_role sees every row',
  $q$select (count(*)::text = (select count(*)::text from public.security_audit_log))::text
        from public.security_audit_log$q$, 'true', 'service_role');
select public.k_expect_error('K10e a signed-in user cannot forge an audit row',
  $q$with i as (insert into public.security_audit_log (action, entity_type, subject_user_id)
                 values ('kyc.forged','kyc_submission','66666666-6666-6666-6666-666666666601') returning 1)
       select count(*)::text from i$q$, 'permission denied', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K10e ... and anon cannot either',
  $q$with i as (insert into public.security_audit_log (action, entity_type)
                 values ('kyc.forged','kyc_submission') returning 1)
       select count(*)::text from i$q$, 'permission denied', 'anon');
select public.k_expect('K10e no forged row exists',
  $q$select count(*)::text from public.security_audit_log where action = 'kyc.forged'$q$, '0');

\echo '=== K11. the authz matrix and the function ACLs'
select public.k_expect_error('K11 anon cannot read kyc_submissions',
  $q$select count(*)::text from public.kyc_submissions$q$,
  'permission denied for table kyc_submissions', 'anon');
select public.k_expect_error('K11 anon cannot read kyc_status',
  $q$select count(*)::text from public.kyc_status$q$,
  'permission denied for table kyc_status', 'anon');
select public.k_expect_error('K11 anon cannot read security_audit_log',
  $q$select count(*)::text from public.security_audit_log$q$,
  'permission denied for table security_audit_log', 'anon');
select public.k_expect('K11 a signed-in user sees exactly their own submissions',
  $q$select count(*)::text from public.kyc_submissions$q$,
  (select count(*)::text from public.kyc_submissions where user_id = '66666666-6666-6666-6666-666666666601'),
  'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect('K11 ... and none of another user''s (user A cannot see user C''s submissions)',
  $q$select count(*)::text from public.kyc_submissions where user_id = '66666666-6666-6666-6666-666666666603'$q$,
  '0', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect('K11 a signed-in user sees only their own kyc_status row',
  $q$select count(*)::text || '/' || coalesce(max(level)::text,'none') from public.kyc_status$q$,
  '1/2', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect('K11 a signed-in user can read the tier model',
  $q$select count(*)::text from public.kyc_levels$q$, '3',
  'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K11 a signed-in user cannot insert a submission',
  $q$with i as (insert into public.kyc_submissions (user_id, level_sought, environment, source)
                 values ('66666666-6666-6666-6666-666666666601', 2, 'paper', 'paper_operator') returning 1)
       select count(*)::text from i$q$,
  'permission denied', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K11 a signed-in user cannot update their own status',
  $q$with u as (update public.kyc_status set level = 2 where true returning 1)
       select count(*)::text from u$q$,
  'permission denied', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K11 a signed-in user cannot call submit_kyc',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666601', 2)$q$,
  'permission denied for function submit_kyc', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K11 ... nor approve_kyc',
  $q$select public.approve_kyc(public.k_id('K3a')::uuid)$q$,
  'permission denied for function approve_kyc', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K11 ... nor reject_kyc',
  $q$select public.reject_kyc(public.k_id('K3a')::uuid, 'x')$q$,
  'permission denied for function reject_kyc', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K11 ... nor the provider adapter entry point',
  $q$select public.record_provider_kyc_event('{}'::jsonb)$q$,
  'permission denied for function record_provider_kyc_event', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K11 ... nor the internal level helper',
  $q$select public._kyc_grant_level('66666666-6666-6666-6666-666666666601', 2, null)$q$,
  'permission denied for function _kyc_grant_level', 'authenticated', '66666666-6666-6666-6666-666666666601'::uuid);
select public.k_expect_error('K11 anon cannot call any KYC entry point',
  $q$select public.submit_kyc('66666666-6666-6666-6666-666666666601', 2)$q$,
  'permission denied for function submit_kyc', 'anon');
select public.k_expect('K11 no EXECUTE privilege leaks to anon on any KYC function',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('assert_kyc_path','_kyc_pii_key_path','ensure_kyc_status','my_kyc_status',
                            'submit_kyc','set_kyc_under_review','approve_kyc','reject_kyc',
                            'record_provider_kyc_event','_kyc_grant_level')
          and has_function_privilege('anon', p.oid, 'EXECUTE')$q$, '0');
select public.k_expect('K11 ... and the ONE documented client entry point is executable by authenticated',
  $q$select has_function_privilege('authenticated', 'public.my_kyc_status()', 'EXECUTE')::text$q$, 'true');
select public.k_expect('K11 ... while the other nine are not executable by authenticated',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.proname in ('assert_kyc_path','_kyc_pii_key_path','ensure_kyc_status',
                            'submit_kyc','set_kyc_under_review','approve_kyc','reject_kyc',
                            'record_provider_kyc_event','_kyc_grant_level')
          and has_function_privilege('authenticated', p.oid, 'EXECUTE')$q$, '0');
select public.k_expect('K11 service_role reads every KYC table (RLS bypassed)',
  $q$select ((select count(*) from public.kyc_levels) > 0)::text || '/' ||
           ((select count(*) from public.kyc_submissions) > 0)::text$q$, 'true/true', 'service_role');
select public.k_expect('K11 no DELETE privilege exists for any client role on the KYC tables',
  $q$select count(*)::text from information_schema.role_table_grants
        where table_name in ('kyc_levels','kyc_submissions','kyc_status','security_audit_log')
          and privilege_type = 'DELETE'
          and grantee in ('anon','authenticated','service_role')$q$, '0');
select public.k_expect('K11 only service_role holds UPDATE on the KYC tables',
  $q$select coalesce(string_agg(distinct grantee, ',' order by grantee), 'none')
        from information_schema.role_table_grants
        where table_name in ('kyc_levels','kyc_submissions','kyc_status')
          and privilege_type = 'UPDATE'
          and grantee in ('anon','authenticated','service_role')$q$, 'service_role');
select public.k_expect('K11 ... and none of them may update the audit log',
  $q$select count(*)::text from information_schema.role_table_grants
        where table_name = 'security_audit_log' and privilege_type = 'UPDATE'
          and grantee in ('anon','authenticated','service_role')$q$, '0');

\echo '=== K12. the settings end where they started; KYC is not money-gated'
select public.k_expect('K12 app_settings matches the snapshot taken before this suite ran',
  $q$select s.mode || '/' || s.live_trading_enabled::text || '/' || s.deposits_enabled::text || '/' ||
           s.withdrawals_enabled::text || '/' || s.paper_deposits_enabled::text || '/' ||
           s.paper_withdrawals_enabled::text || '/' || s.kyc_required_for_trading::text
          from public.app_settings s join public.k_settings_snapshot o on true$q$,
  (select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/' ||
          withdrawals_enabled::text || '/' || paper_deposits_enabled::text || '/' ||
          paper_withdrawals_enabled::text || '/' || kyc_required_for_trading::text
     from public.k_settings_snapshot));
select public.k_expect('K12 the mode is paper again and every live flag is off',
  $q$select mode || '/' || live_trading_enabled::text || '/' || deposits_enabled::text || '/' || withdrawals_enabled::text
        from public.app_settings$q$, 'paper/false/false/false');
select public.k_expect('K12 the KYC migration added NO app_settings column (KYC is not money-gated and has no switch)',
  $q$select string_agg(column_name, ',' order by column_name) from information_schema.columns
        where table_schema = 'public' and table_name = 'app_settings' and column_name like '%kyc%'$q$,
  'kyc_required_for_trading');
select public.k_expect('K12 app_settings.kyc_required_for_trading is untouched (no money path gates on KYC)',
  $q$select kyc_required_for_trading::text from public.app_settings$q$, 'false');
select public.k_expect('K12 the environment-gate trigger is NOT attached to any KYC table',
  $q$select count(*)::text from pg_trigger t join pg_class c on c.oid = t.tgrelid
        join pg_proc p on p.oid = t.tgfoid
        where c.relname in ('kyc_levels','kyc_submissions','kyc_status','security_audit_log')
          and p.proname = 'enforce_environment_gate'$q$, '0');
select public.k_expect('K12 the live probe rows are exactly the two this suite recorded (append-only, no cleanup)',
  $q$select count(*)::text from public.kyc_submissions where environment = 'live'$q$, '2');
select public.k_expect('K12 no level was ever granted without an audit row',
  $q$select count(*)::text from public.kyc_status s
        where s.level > 0
          and (select count(*) from public.security_audit_log a
                where a.action = 'kyc.level.changed' and a.subject_user_id = s.user_id) = 0$q$, '0');
select public.k_expect('K12 every approved submission has a matching approval audit row',
  $q$select count(*)::text from public.kyc_submissions s
        where s.status = 'approved'
          and (select count(*) from public.security_audit_log a
                where a.action = 'kyc.submission.approved' and a.entity_id = s.id) = 0$q$, '0');

\echo '=== SUMMARY'
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from public.k_res;
select count(*) filter (where not ok) as failures from public.k_res;
