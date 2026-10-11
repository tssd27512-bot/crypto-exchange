-- =====================================================================
-- Ledger immutability + RLS access matrix probe (scratch PostgreSQL only)
-- Run in the SAME database as exchange_schema_tests.sql, after it and after
-- exchange_ledger_invariant_tests.sql: it re-uses that fixture data (auth user
-- 11111111-...-1111, its paper accounts/orders/ledger rows) and helper t.expect.
-- Never point this at the live Supabase project ctrazoqbudsfkpawpomv.
-- Every line prints PASS or FAIL; the last line is a SUMMARY.
-- =====================================================================
\set ON_ERROR_STOP on
do $g$
begin
  if to_regprocedure('t.expect(text,text,text,text,uuid)') is null then
    raise exception 'exchange_immutability_rls_probe.sql must run in the same database, after exchange_schema_tests.sql (helper t.expect is missing).';
  end if;
  if not exists (select 1 from public.ledger_entries) then
    raise exception 'exchange_immutability_rls_probe.sql needs the funded fixture rows created by exchange_schema_tests.sql.';
  end if;
end $g$;

create temp table p_res(seq serial, label text, ok boolean);
create or replace function public.pc(p_label text, p_ok boolean) returns void
language plpgsql as $pc$
begin
  insert into p_res(label, ok) values (p_label, coalesce(p_ok, false));
end $pc$;

-- run p_sql as p_role (with JWT subject p_sub) and return the single text value it yields,
-- or 'ERR:<sqlstate> <message>' when the statement is refused. Always resets the role.
create or replace function public.p_as(p_role text, p_sub uuid, p_sql text) returns text
language plpgsql as $pas$
declare v text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v;
    v := coalesce(v, 'NULL');
  exception when others then
    v := 'ERR:' || sqlstate || ' ' || sqlerrm;
  end;
  execute 'reset role';
  return v;
end $pas$;

-- attempt a mutation as p_role, reporting how many rows it changed or the refusal.
-- Callers pass a CTE statement whose outer SELECT returns the changed row count as text.
create or replace function public.p_write(p_role text, p_sql text) returns text
language plpgsql as $pw$
declare v text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    execute p_sql into v;
    v := coalesce(v, '0');
  exception when others then
    v := 'ERR:' || sqlstate || ' ' || sqlerrm;
  end;
  execute 'reset role';
  return v;
end $pw$;

-- ---------------------------------------------------------------------
-- (a) ledger immutability
-- ---------------------------------------------------------------------
do $a$
declare
  v_entry uuid; v_tx uuid; v_amt numeric; v_entries bigint; v_txs bigint; v_msg text;
  v_u1 uuid := '11111111-1111-1111-1111-111111111111';
begin
  select e.id, e.amount_units into v_entry, v_amt from public.ledger_entries e order by e.id limit 1;
  select t.id into v_tx from public.ledger_transactions t order by t.id limit 1;
  select count(*) into v_entries from public.ledger_entries;
  select count(*) into v_txs from public.ledger_transactions;
  perform public.pc('probe has ledger rows to attack [' || v_entries || ' entries / ' || v_txs || ' transactions]',
                    v_entry is not null and v_tx is not null);

  -- as postgres (superuser AND table owner): only the append-only trigger can stop this
  v_msg := public.p_write(null, format('with u as (update public.ledger_entries set amount_units = 0 where id = %L returning 1) select count(*)::text from u', v_entry));
  perform public.pc('postgres UPDATE ledger_entries refused by append-only trigger [' || v_msg || ']', v_msg like 'ERR:%append-only%');
  v_msg := public.p_write(null, format('with d as (delete from public.ledger_entries where id = %L returning 1) select count(*)::text from d', v_entry));
  perform public.pc('postgres DELETE ledger_entries refused by append-only trigger [' || v_msg || ']', v_msg like 'ERR:%append-only%');
  v_msg := public.p_write(null, format('with u as (update public.ledger_transactions set description = ''tampered'' where id = %L returning 1) select count(*)::text from u', v_tx));
  perform public.pc('postgres UPDATE ledger_transactions refused by append-only trigger [' || v_msg || ']', v_msg like 'ERR:%append-only%');
  v_msg := public.p_write(null, format('with d as (delete from public.ledger_transactions where id = %L returning 1) select count(*)::text from d', v_tx));
  perform public.pc('postgres DELETE ledger_transactions refused by append-only trigger [' || v_msg || ']', v_msg like 'ERR:%append-only%');

  -- as a signed-in user (authenticated) and as an unauthenticated client (anon)
  v_msg := public.p_write('authenticated', format('with u as (update public.ledger_entries set amount_units = 0 where id = %L returning 1) select count(*)::text from u', v_entry));
  perform public.pc('authenticated UPDATE ledger_entries denied [' || v_msg || ']', v_msg = '0' or v_msg like 'ERR:%');
  v_msg := public.p_write('authenticated', format('with d as (delete from public.ledger_entries where id = %L returning 1) select count(*)::text from d', v_entry));
  perform public.pc('authenticated DELETE ledger_entries denied [' || v_msg || ']', v_msg = '0' or v_msg like 'ERR:%');
  v_msg := public.p_write('authenticated', format('with u as (update public.ledger_transactions set description = ''tampered'' where id = %L returning 1) select count(*)::text from u', v_tx));
  perform public.pc('authenticated UPDATE ledger_transactions denied [' || v_msg || ']', v_msg = '0' or v_msg like 'ERR:%');
  v_msg := public.p_write('authenticated', format('with d as (delete from public.ledger_transactions where id = %L returning 1) select count(*)::text from d', v_tx));
  perform public.pc('authenticated DELETE ledger_transactions denied [' || v_msg || ']', v_msg = '0' or v_msg like 'ERR:%');
  v_msg := public.p_write('anon', format('with u as (update public.ledger_entries set amount_units = 0 where id = %L returning 1) select count(*)::text from u', v_entry));
  perform public.pc('anon UPDATE ledger_entries denied [' || v_msg || ']', v_msg = '0' or v_msg like 'ERR:%');
  v_msg := public.p_write('anon', format('with d as (delete from public.ledger_entries where id = %L returning 1) select count(*)::text from d', v_entry));
  perform public.pc('anon DELETE ledger_entries denied [' || v_msg || ']', v_msg = '0' or v_msg like 'ERR:%');
  v_msg := public.p_write('anon', format('with u as (update public.ledger_transactions set description = ''tampered'' where id = %L returning 1) select count(*)::text from u', v_tx));
  perform public.pc('anon UPDATE ledger_transactions denied [' || v_msg || ']', v_msg = '0' or v_msg like 'ERR:%');
  v_msg := public.p_write('anon', format('with d as (delete from public.ledger_transactions where id = %L returning 1) select count(*)::text from d', v_tx));
  perform public.pc('anon DELETE ledger_transactions denied [' || v_msg || ']', v_msg = '0' or v_msg like 'ERR:%');

  -- the attacked rows are provably still there, unchanged
  perform public.pc('ledger still holds the same rows [' || (select count(*) from public.ledger_entries) || ' entries / ' || (select count(*) from public.ledger_transactions) || ' transactions]',
                    (select count(*) from public.ledger_entries) = v_entries and (select count(*) from public.ledger_transactions) = v_txs);
  perform public.pc('the attacked ledger entry is unchanged [' || (select amount_units from public.ledger_entries where id = v_entry) || ']',
                    (select amount_units from public.ledger_entries where id = v_entry) = v_amt);
end $a$;

-- no stored routine can rewrite ledger history either (only triggers may touch the tables)
select t.expect('no function in public mutates ledger history',
  $q$select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public'
        and p.prosrc ~* '(update|delete[[:space:]]+from|truncate)[[:space:]]+(public\.)?ledger_(entries|transactions)'$q$,
  '0');

-- ---------------------------------------------------------------------
-- (b) RLS access matrix: anon / authenticated / service_role
-- ---------------------------------------------------------------------
do $b$
declare
  u1 uuid := '11111111-1111-1111-1111-111111111111';
  u2 uuid := '22222222-2222-2222-2222-222222222222';
  v_o2 uuid; v_o1 uuid; r text; v_total text; t text;
  v_osts text; v_osts0 text; n int := -1; txt text;
begin
  select string_agg(o.status || ':' || c, ',' order by o.status || ':' || c) into v_osts0
    from (select o.status, count(*) c from public.orders o group by o.status) o;

  -- anon: no read access to any exchange table
  foreach t in array array['orders','trades','ledger_entries','ledger_transactions','balances','accounts','order_events'] loop
    r := public.p_as('anon', null, 'select count(*)::text from public.' || t);
    perform public.pc('anon cannot read public.' || t || ' [' || r || ']', r = '0' or r like 'ERR:%');
  end loop;
  -- anon: no write access (mutation must change 0 rows, or be refused)
  foreach t in array array['orders','trades','balances','ledger_entries','ledger_transactions'] loop
    r := public.p_write('anon', format('with u as (update public.%I set environment = ''paper'' where true returning 1) select count(*)::text from u', t));
    perform public.pc('anon cannot UPDATE public.' || t || ' [' || r || ']', r = '0' or r like 'ERR:%');
    r := public.p_write('anon', format('with d as (delete from public.%I where true returning 1) select count(*)::text from d', t));
    perform public.pc('anon cannot DELETE from public.' || t || ' [' || r || ']', r = '0' or r like 'ERR:%');
  end loop;

  -- authenticated: reads only its own rows
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.orders where user_id <> ''' || u1 || '''');
  perform public.pc('authenticated sees no order of another user [' || r || ']', r = '0');
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.orders');
  perform public.pc('authenticated still sees its own orders [' || r || ']', r <> '0' and r not like 'ERR:%');
  r := public.p_as('authenticated', u2, 'select count(*)::text from public.orders where user_id <> ''' || u2 || '''');
  perform public.pc('the other user also sees no foreign order [' || r || ']', r = '0');
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.trades where maker_user_id <> ''' || u1 || ''' and taker_user_id <> ''' || u1 || '''');
  perform public.pc('authenticated sees no trade it is not a party to [' || r || ']', r = '0');
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.balances b join public.accounts a on a.id = b.account_id where a.user_id <> ''' || u1 || '''');
  perform public.pc('authenticated sees no balance of another user [' || r || ']', r = '0');
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.accounts where user_id <> ''' || u1 || '''');
  perform public.pc('authenticated sees no account of another user [' || r || ']', r = '0');
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.ledger_entries e join public.accounts a on a.id = e.account_id where a.user_id <> ''' || u1 || '''');
  perform public.pc('authenticated sees no ledger entry of another user [' || r || ']', r = '0');
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.ledger_transactions where coalesce(actor_user_id, ''' || u1 || ''') <> ''' || u1 || '''');
  perform public.pc('authenticated sees no ledger transaction of another user [' || r || ']', r = '0');
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.order_events e join public.orders o on o.id = e.order_id where o.user_id <> ''' || u1 || '''');
  perform public.pc('authenticated sees no order event of another user [' || r || ']', r = '0');

  -- concrete cross-user check on a real row id, when the fixture has one
  select o.id into v_o2 from public.orders o where o.user_id = u2 limit 1;
  if v_o2 is not null then
    r := public.p_as('authenticated', u1, format('select count(*)::text from public.orders where id = %L', v_o2));
    perform public.pc('authenticated cannot read a concrete other-user order [' || r || ']', r = '0');
  else
    perform public.pc('no second-user order in the fixture to probe (skipped)', true);
  end if;

  -- authenticated: no write path at all
  select o.id into v_o1 from public.orders o where o.user_id = u1 limit 1;
  r := public.p_write('authenticated', format('with u as (update public.orders set status = ''canceled'' where id = %L returning 1) select count(*)::text from u', v_o1));
  perform public.pc('authenticated cannot UPDATE its own order [' || r || ']', r = '0' or r like 'ERR:%');
  r := public.p_write('authenticated', format('with d as (delete from public.orders where id = %L returning 1) select count(*)::text from d', v_o1));
  perform public.pc('authenticated cannot DELETE its own order [' || r || ']', r = '0' or r like 'ERR:%');
  r := public.p_write('authenticated', format('with i as (insert into public.order_events (id, order_id, event) select gen_random_uuid(), e.order_id, e.event from public.order_events e join public.orders o on o.id = e.order_id where o.user_id = %L limit 1 returning 1) select count(*)::text from i', u1));
  perform public.pc('authenticated cannot INSERT an order event [' || r || ']', r = '0' or r like 'ERR:%');
  r := public.p_write('authenticated', format('with u as (update public.balances set available_units = available_units + 1 where account_id in (select id from public.accounts where user_id = %L) returning 1) select count(*)::text from u', u1));
  perform public.pc('authenticated cannot move its own balance [' || r || ']', r = '0' or r like 'ERR:%');

  -- service_role: full read and write (the write is rolled back inside the probe)
  r := public.p_as('service_role', null, 'select count(*)::text from public.orders');
  v_total := public.p_as(null, null, 'select count(*)::text from public.orders');
  perform public.pc('service_role reads every order [' || r || ' vs ' || v_total || ' for postgres]', r = v_total and v_total <> '0');
  r := public.p_as('service_role', null, 'select count(*)::text from public.balances');
  v_total := public.p_as(null, null, 'select count(*)::text from public.balances');
  perform public.pc('service_role reads every balance [' || r || ' vs ' || v_total || ' for postgres]', r = v_total and v_total <> '0');
  begin
    execute 'set local role service_role';
    update public.orders set status = status where true;
    get diagnostics n = row_count;
    raise exception 'ROLLBACK_PROBE';   -- force this subtransaction (and the write) to be undone
  exception when others then
    if sqlerrm <> 'ROLLBACK_PROBE' then n := -1; txt := sqlerrm; end if;
  end;
  execute 'reset role';
  perform public.pc('service_role can UPDATE orders [' || coalesce(txt, n::text || ' rows, probe write rolled back') || ']', n > 0);

  -- book/market views: public aggregated data, tested to carry no wallet detail
  r := public.p_as('service_role', null, 'select count(*)::text from public.v_order_book_best');
  perform public.pc('the book views serve aggregated data (best bid/ask rows) [' || r || ']', r not like 'ERR:%');
  r := public.p_as('service_role', null, 'select count(*)::text from public.v_order_book_depth');
  perform public.pc('the book views serve aggregated data (depth levels) [' || r || ']', r not like 'ERR:%');
  r := public.p_as('service_role', null, 'select count(*)::text from public.v_markets');
  perform public.pc('the markets view serves its reference data [' || r || ']', r not like 'ERR:%');
  -- in this implementation the book/market views are readable only with a privileged token
  -- (SELECT is not granted to anon/authenticated), so a client role must not reach them at all;
  -- either way, no client role may see per-order or wallet columns through them.
  r := public.p_as('anon', null, 'select count(*)::text from public.v_order_book_best');
  perform public.pc('anon cannot reach order data through the best bid/ask view [' || r || ']', r = '0' or r like 'ERR:%');
  r := public.p_as('anon', null, 'select count(*)::text from public.v_order_book_depth');
  perform public.pc('anon cannot reach order data through the depth view [' || r || ']', r = '0' or r like 'ERR:%');
  r := public.p_as('anon', null, 'select count(*)::text from public.v_markets');
  perform public.pc('anon cannot read the markets view [' || r || ']', r = '0' or r like 'ERR:%');
  -- authenticated IS granted SELECT on the book views (by design - the signed-in client shows the
  -- book); what matters is that what it gets back is aggregated levels only, never per-order or
  -- wallet columns, which the column assertion at the end of this file pins down.
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.v_order_book_depth');
  perform public.pc('authenticated reads aggregated depth levels only [' || r || ']', r <> '0' and r not like 'ERR:%');
  r := public.p_as('anon', null, 'select count(*)::text from public.v_my_balances');
  perform public.pc('anon sees no wallet through v_my_balances [' || r || ']', r = '0' or r like 'ERR:%');
  r := public.p_as('anon', null, 'select count(*)::text from public.v_account_reconciliation');
  perform public.pc('anon sees no wallet through v_account_reconciliation [' || r || ']', r = '0' or r like 'ERR:%');
  r := public.p_as('authenticated', u1, 'select count(*)::text from public.v_my_balances where user_id <> ''' || u1 || '''');
  perform public.pc('authenticated sees only its own wallet through v_my_balances [' || r || ']', r = '0');

  -- nothing in the probe wrote any data
  select string_agg(o.status || ':' || c, ',' order by o.status || ':' || c) into v_osts
    from (select o.status, count(*) c from public.orders o group by o.status) o;
  perform public.pc('no probe write landed on orders [' || v_osts || ' vs ' || coalesce(v_osts0,'-') || ' before]', v_osts is not distinct from v_osts0);
end $b$;

-- aggregated depth covers exactly the open orders and carries no per-order/wallet column
select t.expect('sum of depth order_count equals the open order count',
  $q$select (coalesce((select sum(order_count) from public.v_order_book_depth), 0)
             = coalesce((select count(*) from public.orders where status in ('new','partially_filled')), 0))::text$q$, 'true');
select t.expect('no orderbook/market view exposes a per-order or wallet column',
  $q$select count(*)::text from information_schema.columns
      where table_schema = 'public'
        and table_name in ('v_order_book_best','v_order_book_depth','v_markets','v_market_stats_24h')
        and column_name ~* '(balance|locked|available|hold|account|user_id|order_id|client_order|email)'$q$, '0');

-- ---------------------------------------------------------------------
-- summary
-- ---------------------------------------------------------------------
select 'FAIL ' || label from p_res where not ok order by seq;
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from p_res;
