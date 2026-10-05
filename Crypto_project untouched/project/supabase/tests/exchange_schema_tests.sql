\set ON_ERROR_STOP on
-- =====================================================================
-- GlobalTradeVX exchange schema — verification suite (scratch PostgreSQL)
-- Run after the 6 migrations. Every line prints PASS or FAIL.
-- =====================================================================

create schema if not exists t;

create or replace function t.expect(p_label text, p_sql text, p_expected text, p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    if v_actual is not distinct from p_expected then
      raise notice 'PASS  % = %', p_label, coalesce(v_actual, 'NULL');
    else
      raise notice 'FAIL  % expected [%] got [%]', p_label, p_expected, coalesce(v_actual, 'NULL');
    end if;
  exception when others then
    raise notice 'FAIL  % raised % (%)', p_label, sqlerrm, sqlstate;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function t.expect_error(p_label text, p_sql text, p_fragment text, p_role text default null, p_sub uuid default null)
returns void language plpgsql as $fn$
declare v_actual text;
begin
  begin
    if p_role is not null then execute format('set local role %I', p_role); end if;
    if p_sub is not null then perform set_config('request.jwt.claims.sub', p_sub::text, true); end if;
    execute p_sql into v_actual;
    raise notice 'FAIL  % was ALLOWED (returned %)', p_label, coalesce(v_actual, 'NULL');
  exception when others then
    if p_fragment is null or p_fragment = '' or sqlerrm ilike '%' || p_fragment || '%' then
      raise notice 'PASS  % blocked [%] %', p_label, sqlstate, sqlerrm;
    else
      raise notice 'FAIL  % blocked by the WRONG error [%] % (wanted %)', p_label, sqlstate, sqlerrm, p_fragment;
    end if;
  end;
  execute 'reset role';
  perform set_config('request.jwt.claims.sub', '', true);
end;
$fn$;

create or replace function t.run(p_label text, p_sql text)
returns void language plpgsql as $fn$
declare v_rows bigint;
begin
  execute p_sql;
  get diagnostics v_rows = row_count;
  raise notice 'PASS  (ran) % [% row(s)]', p_label, v_rows;
exception when others then
  raise notice 'FAIL  (setup) % raised % (%)', p_label, sqlerrm, sqlstate;
end;
$fn$;

\echo '=== 1. reference data and derived precision'
select t.expect('app_settings is one row in paper mode', $q$select mode from public.app_settings$q$, 'paper');
select t.expect('assets seeded', $q$select count(*)::text from public.assets$q$, '4');
select t.expect('paper markets seeded', $q$select count(*)::text from public.markets where environment = 'paper'$q$, '3');
select t.expect('BTC/USDT notional_scale = price_scale + 8 - 6', $q$select notional_scale::text from public.markets where symbol = 'BTC/USDT'$q$, '10');
select t.expect('ETH/USDT notional_scale = 20', $q$select notional_scale::text from public.markets where symbol = 'ETH/USDT'$q$, '20');
select t.expect('SOL/USDT notional_scale = 11', $q$select notional_scale::text from public.markets where symbol = 'SOL/USDT'$q$, '11');
select t.expect('BTC base_decimals = 8', $q$select base_decimals::text from public.assets where symbol = 'BTC'$q$, '8');
select t.expect('ETH base_decimals = 18', $q$select base_decimals::text from public.assets where symbol = 'ETH'$q$, '18');
select t.expect('USDT base_decimals = 6', $q$select base_decimals::text from public.assets where symbol = 'USDT'$q$, '6');
select t.expect('SOL base_decimals = 9', $q$select base_decimals::text from public.assets where symbol = 'SOL'$q$, '9');
select t.expect('notional math is exact for 0.0006 BTC @ 60k', $q$select public.notional_units(60000, 6000000000000, 10)::text$q$, '36000000');
select t.expect('inverse price math round-trips', $q$select public.price_units_from_notional(36000000, 60000, 10)::text$q$, '6000000000000');
select t.expect('paper system accounts seeded (2 codes x 4 assets)', $q$select count(*)::text from public.accounts where account_type = 'system'$q$, '8');
select t.expect('markets are paper by default', $q$select count(*)::text from public.markets where environment = 'paper'$q$, '3');
select t.expect('maker/taker fees default to the advertised 2/5 bps', $q$select maker_fee_bps::text || '/' || taker_fee_bps::text from public.markets where symbol = 'BTC/USDT'$q$, '2/5');

\echo '=== 2. fixtures: two users, accounts, funding, hold, order, match'
select t.run('create two auth users', $q$
  insert into auth.users (id, email) values
    ('11111111-1111-1111-1111-111111111111', 'u1@example.test'),
    ('22222222-2222-2222-2222-222222222222', 'u2@example.test')
$q$);
select t.run('open user accounts (u1 available+locked, u2 available, BTC)', $q$
  insert into public.accounts (user_id, asset_id, kind, environment, label)
  select '11111111-1111-1111-1111-111111111111'::uuid, a.id, k.kind, 'paper', k.kind
    from public.assets a cross join (values ('available'), ('locked')) as k(kind)
   where a.symbol = 'BTC'
  union all
  select '22222222-2222-2222-2222-222222222222'::uuid, a.id, 'available', 'paper', 'u2'
    from public.assets a where a.symbol = 'BTC'
$q$);
select t.run('paper funding: faucet credits u1 1.00000000 BTC', $q$
  with tx as (
    insert into public.ledger_transactions (type, environment, idempotency_key, description)
    values ('paper_funding', 'paper', 'seed-funding-1', 'paper faucet funding')
    returning id
  ), postings as (
    insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units)
    select tx.id, v.account_id, v.asset_id, 'paper', v.amount_units
      from tx cross join (
        select a.id as account_id, a.asset_id, 100000000::numeric as amount_units
          from public.accounts a
         where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available'
        union all
        select a.id, a.asset_id, -100000000::numeric
          from public.accounts a
         where a.code = 'PAPER_FAUCET'
           and a.asset_id = (select id from public.assets where symbol = 'BTC')
      ) v
    returning account_id, amount_units
  )
  update public.balances b
     set available_units = b.available_units + p.amount_units
    from postings p
   where b.account_id = p.account_id
$q$);
select t.run('order hold: move 0.0006 BTC available -> locked', $q$
  with tx as (
    insert into public.ledger_transactions (type, environment, idempotency_key, description)
    values ('order_hold', 'paper', 'hold-1', 'hold for test order')
    returning id
  ), postings as (
    insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units)
    select tx.id, v.account_id, v.asset_id, 'paper', v.amount_units
      from tx cross join (
        select a.id as account_id, a.asset_id, -60000::numeric as amount_units
          from public.accounts a
         where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available'
        union all
        select a.id, a.asset_id, 60000::numeric
          from public.accounts a
         where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'locked'
      ) v
    returning account_id, amount_units
  )
  update public.balances b
     set available_units = b.available_units + case when a.kind = 'available' then p.amount_units else 0 end,
         locked_units    = b.locked_units    + case when a.kind = 'locked'    then p.amount_units else 0 end
    from postings p join public.accounts a on a.id = p.account_id
   where b.account_id = p.account_id
$q$);
select t.run('u1 places a resting limit buy (carrying its hold)', $q$
  insert into public.orders (
    user_id, market_id, client_order_id, side, type, price_units, qty_units, quote_qty_units,
    hold_amount_units, hold_asset_id, hold_account_id, hold_transaction_id, environment)
  select '11111111-1111-1111-1111-111111111111', m.id, 'client-1', 'buy', 'limit',
         6000000000000, 60000, 36000000, 60000, a.asset_id, a.id,
         (select id from public.ledger_transactions where idempotency_key = 'hold-1'), 'paper'
    from public.markets m, public.accounts a
   where m.symbol = 'BTC/USDT'
     and a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'locked'
$q$);
select t.run('u2 places the resting limit sell', $q$
  insert into public.orders (user_id, market_id, client_order_id, side, type, price_units, qty_units, environment)
  select '22222222-2222-2222-2222-222222222222', m.id, 'client-2', 'sell', 'limit', 6000000000000, 60000, 'paper'
    from public.markets m where m.symbol = 'BTC/USDT'
$q$);
select t.run('record the match in trades', $q$
  insert into public.trades (market_id, price_units, qty_units, quote_units, taker_side,
    taker_order_id, maker_order_id, taker_user_id, maker_user_id,
    taker_fee_units, maker_fee_units, fee_asset_id, environment)
  select m.id, 6000000000000, 60000, 36000000, 'buy',
    (select id from public.orders where client_order_id = 'client-1'),
    (select id from public.orders where client_order_id = 'client-2'),
    '11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222',
    18000, 7200, (select id from public.assets where symbol = 'USDT'), 'paper'
    from public.markets m where m.symbol = 'BTC/USDT'
$q$);
select t.run('append an order event', $q$
  insert into public.order_events (order_id, event, actor)
  select id, 'created', 'engine' from public.orders where client_order_id = 'client-1'
$q$);

\echo '=== 3. ledger and projection invariants'
select t.expect('u1 available after funding+hold = 99940000', $q$select b.available_units::text from public.balances b join public.accounts a on a.id = b.account_id where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available'$q$, '99940000');
select t.expect('u1 locked = 60000', $q$select b.locked_units::text from public.balances b join public.accounts a on a.id = b.account_id where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'locked'$q$, '60000');
select t.expect('system faucet carries the negative side (-100000000)', $q$select b.available_units::text from public.balances b join public.accounts a on a.id = b.account_id where a.code = 'PAPER_FAUCET' and a.asset_id = (select id from public.assets where symbol = 'BTC')$q$, '-100000000');
select t.expect('every entry is a multiple of the integer unit (no fractional amounts)', $q$select count(*)::text from public.ledger_entries where amount_units <> trunc(amount_units)$q$, '0');
select t.expect('global ledger sums to zero per asset', $q$select coalesce(sum(amount_units), 0)::text from public.ledger_entries$q$, '0');
select t.expect('ledger sums to zero per asset (grouped)', $q$select count(*)::text from (select asset_id, sum(amount_units) s from public.ledger_entries group by asset_id having sum(amount_units) <> 0) x$q$, '0');
select t.expect('4 ledger entries posted (funding + hold)', $q$select count(*)::text from public.ledger_entries$q$, '4');
select t.expect('v_account_reconciliation shows no drift', $q$select count(*)::text from public.v_account_reconciliation where drift_units <> 0$q$, '0');
select t.expect('balances.version bumped by the write guard', $q$select b.version::text from public.balances b join public.accounts a on a.id = b.account_id where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available'$q$, '2');
select t.expect('each account has a balances row (8 system + 3 user)', $q$select count(*)::text from public.balances$q$, '11');
select t.expect('idempotency key recorded once', $q$select count(*)::text from public.ledger_transactions where idempotency_key = 'seed-funding-1'$q$, '1');

\echo '=== 4. RLS: anon gets nothing at all'
select t.expect_error('anon cannot SELECT accounts', $q$select count(*)::text from public.accounts$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot SELECT balances', $q$select count(*)::text from public.balances$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot SELECT orders', $q$select count(*)::text from public.orders$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot SELECT ledger_entries', $q$select count(*)::text from public.ledger_entries$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot SELECT markets (no public read path)', $q$select count(*)::text from public.markets$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot SELECT app_settings', $q$select mode from public.app_settings$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot SELECT v_my_balances', $q$select count(*)::text from public.v_my_balances$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot INSERT orders', $q$insert into public.orders (user_id, market_id, side, type, price_units, qty_units) values ('11111111-1111-1111-1111-111111111111', gen_random_uuid(), 'buy','limit',1,1)$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot INSERT ledger_entries', $q$insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'paper', 1)$q$, 'permission denied', 'anon');
select t.expect_error('anon cannot INSERT accounts', $q$insert into public.accounts (user_id, asset_id, kind, environment) values ('11111111-1111-1111-1111-111111111111', gen_random_uuid(), 'available', 'paper')$q$, 'permission denied', 'anon');

\echo '=== 5. RLS: authenticated reads only its own rows'
select t.expect('u1 sees own 2 accounts only', $q$select count(*)::text from public.accounts$q$, '2', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u1 sees own 2 balances', $q$select count(*)::text from public.balances$q$, '2', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u2 sees own 1 balance only', $q$select count(*)::text from public.balances$q$, '1', 'authenticated', '22222222-2222-2222-2222-222222222222');
select t.expect('u1 sees own 3 ledger entries', $q$select count(*)::text from public.ledger_entries$q$, '3', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u2 sees none of u1''s ledger entries', $q$select count(*)::text from public.ledger_entries$q$, '0', 'authenticated', '22222222-2222-2222-2222-222222222222');
select t.expect('u1 sees own order, not the counterparty''s', $q$select count(*)::text from public.orders where client_order_id = 'client-2'$q$, '0', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u2 sees own order', $q$select count(*)::text from public.orders$q$, '1', 'authenticated', '22222222-2222-2222-2222-222222222222');
select t.expect('u1 sees own order', $q$select count(*)::text from public.orders$q$, '1', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u1 sees the trade they are part of', $q$select count(*)::text from public.trades$q$, '1', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u1 sees own order events', $q$select count(*)::text from public.order_events$q$, '1', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u1 sees only own ledger transactions', $q$select count(*)::text from public.ledger_transactions$q$, '2', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u2 sees no ledger transactions of its own yet', $q$select count(*)::text from public.ledger_transactions$q$, '0', 'authenticated', '22222222-2222-2222-2222-222222222222');
select t.expect('authenticated can read markets (reference data)', $q$select count(*)::text from public.markets$q$, '3', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('authenticated can read assets', $q$select count(*)::text from public.assets$q$, '4', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('authenticated can read the paper/live flag', $q$select mode from public.app_settings$q$, 'paper', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u1 v_my_balances returns own 2 rows', $q$select count(*)::text from public.v_my_balances$q$, '2', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u1 v_my_balances shows BTC amount, not u2''s', $q$select symbol from public.v_my_balances order by kind limit 1$q$, 'BTC', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect('u2 v_my_balances returns only own row', $q$select count(*)::text from public.v_my_balances$q$, '1', 'authenticated', '22222222-2222-2222-2222-222222222222');
select t.expect_error('authenticated cannot read the reconciliation view', $q$select count(*)::text from public.v_account_reconciliation$q$, 'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');

\echo '=== 6. RLS: no client write path'
select t.expect_error('authenticated cannot INSERT orders', $q$insert into public.orders (user_id, market_id, side, type, price_units, qty_units) values ('11111111-1111-1111-1111-111111111111', gen_random_uuid(), 'buy','limit',1,1)$q$, 'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect_error('authenticated cannot UPDATE balances', $q$update public.balances set available_units = 0$q$, 'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect_error('authenticated cannot INSERT ledger_entries', $q$insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'paper', 1)$q$, 'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect_error('authenticated cannot INSERT accounts', $q$insert into public.accounts (user_id, asset_id, kind, environment) values ('11111111-1111-1111-1111-111111111111', gen_random_uuid(), 'available', 'paper')$q$, 'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');
select t.expect_error('authenticated cannot INSERT trades', $q$insert into public.trades (market_id, price_units, qty_units, quote_units, taker_side, taker_order_id, maker_order_id, taker_user_id, maker_user_id) values (gen_random_uuid(),1,1,1,'buy',gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid())$q$, 'permission denied', 'authenticated', '11111111-1111-1111-1111-111111111111');

\echo '=== 7. append-only enforcement (privilege + trigger)'
select t.expect_error('service_role cannot UPDATE ledger_entries (privilege)', $q$update public.ledger_entries set amount_units = 1$q$, 'permission denied', 'service_role');
select t.expect_error('service_role cannot DELETE ledger_entries (privilege)', $q$delete from public.ledger_entries$q$, 'permission denied', 'service_role');
select t.expect_error('service_role cannot UPDATE ledger_transactions (privilege)', $q$update public.ledger_transactions set description = 'x'$q$, 'permission denied', 'service_role');
select t.expect_error('service_role cannot DELETE trades (privilege)', $q$delete from public.trades$q$, 'permission denied', 'service_role');
select t.expect_error('table owner cannot UPDATE ledger_entries (trigger)', $q$update public.ledger_entries set amount_units = 1$q$, 'append-only');
select t.expect_error('table owner cannot DELETE ledger_entries (trigger)', $q$delete from public.ledger_entries$q$, 'append-only');
select t.expect_error('table owner cannot UPDATE ledger_transactions (trigger)', $q$update public.ledger_transactions set description = 'x'$q$, 'append-only');
select t.expect_error('table owner cannot UPDATE trades (trigger)', $q$update public.trades set qty_units = 1$q$, 'append-only');
select t.expect_error('table owner cannot UPDATE order_events (trigger)', $q$update public.order_events set event = 'filled'$q$, 'append-only');

\echo '=== 8. paper/live gate'
select t.expect_error('live account rejected while mode = paper', $q$insert into public.accounts (user_id, asset_id, kind, environment) select '11111111-1111-1111-1111-111111111111', id, 'available', 'live' from public.assets where symbol = 'BTC'$q$, 'not live');
select t.expect_error('live order rejected while mode = paper', $q$insert into public.orders (user_id, market_id, side, type, price_units, qty_units, environment) select '11111111-1111-1111-1111-111111111111', id, 'buy', 'limit', 1, 1, 'live' from public.markets where symbol = 'BTC/USDT'$q$, 'not live');
select t.expect_error('live ledger transaction rejected while mode = paper', $q$insert into public.ledger_transactions (type, environment) values ('admin_adjustment', 'live')$q$, 'not live');
select t.expect('paper rows are unaffected by the gate', $q$select count(*)::text from public.accounts where environment = 'paper'$q$, '11');

\echo '=== 9. order validation'
select t.expect_error('limit order without a price is rejected', $q$insert into public.orders (user_id, market_id, side, type, qty_units) select '11111111-1111-1111-1111-111111111111', id, 'buy', 'limit', 60000 from public.markets where symbol = 'BTC/USDT'$q$, 'price');
select t.run('temporarily widen tick/step to 100 / 1000 for the precision tests', $q$update public.markets set price_tick_units = 100, qty_step_units = 1000 where symbol = 'BTC/USDT'$q$);
select t.expect_error('price off the tick (tick=100) is rejected', $q$insert into public.orders (user_id, market_id, side, type, price_units, qty_units) select '11111111-1111-1111-1111-111111111111', id, 'buy', 'limit', 6000000000001, 60000 from public.markets where symbol = 'BTC/USDT' returning 1$q$, 'tick');
select t.expect_error('quantity off the step (step=1000) is rejected', $q$insert into public.orders (user_id, market_id, side, type, price_units, qty_units) select '11111111-1111-1111-1111-111111111111', id, 'buy', 'limit', 6000000000000, 60001 from public.markets where symbol = 'BTC/USDT' returning 1$q$, 'step');
select t.run('restore tick/step to 1', $q$update public.markets set price_tick_units = 1, qty_step_units = 1 where symbol = 'BTC/USDT'$q$);
select t.expect('fractional input is rounded to the integer unit by the column type (documented boundary rule)', $q$insert into public.orders (user_id, market_id, client_order_id, side, type, price_units, qty_units) select '11111111-1111-1111-1111-111111111111', id, 'client-frac', 'buy', 'limit', 6000000000000.5, 60000.5 from public.markets where symbol = 'BTC/USDT' returning price_units::text$q$, '6000000000001');
select t.expect_error('zero/negative quantity is rejected', $q$insert into public.orders (user_id, market_id, side, type, price_units, qty_units) select '11111111-1111-1111-1111-111111111111', id, 'buy', 'limit', 6000000000000, -1 from public.markets where symbol = 'BTC/USDT'$q$, 'check constraint');
select t.expect_error('duplicate client_order_id is rejected', $q$insert into public.orders (user_id, market_id, client_order_id, side, type, price_units, qty_units) select '11111111-1111-1111-1111-111111111111', id, 'client-1', 'buy', 'limit', 6000000000000, 60000 from public.markets where symbol = 'BTC/USDT'$q$, 'duplicate key');
select t.expect_error('a market with a negative notional_scale is rejected', $q$insert into public.markets (symbol, base_asset_id, quote_asset_id, environment) select 'BTC/ETH', b.id, q.id, 'paper' from public.assets b, public.assets q where b.symbol = 'BTC' and q.symbol = 'ETH'$q$, 'notional_scale');
select t.expect_error('an entry whose asset disagrees with its account is rejected', $q$insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units) select (select id from public.ledger_transactions where idempotency_key = 'hold-1'), a.id, (select id from public.assets where symbol = 'ETH'), a.environment, 1 from public.accounts a where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available'$q$, 'foreign key');

\echo '=== 10. balance guards and optimistic locking'
select t.expect_error('a user balance cannot go negative', $q$update public.balances set available_units = -1 where account_id = (select id from public.accounts where user_id = '11111111-1111-1111-1111-111111111111' and kind = 'available')$q$, 'cannot go negative');
select t.expect_error('locked units cannot go negative', $q$update public.balances set locked_units = -1 where account_id = (select a.id from public.accounts a where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'locked')$q$, 'cannot be negative');
select t.expect_error('balances.account_id is immutable', $q$update public.balances set account_id = (select id from public.accounts where user_id = '22222222-2222-2222-2222-222222222222' and kind = 'available') where account_id = (select id from public.accounts where user_id = '11111111-1111-1111-1111-111111111111' and kind = 'locked')$q$, 'immutable');
select t.expect('stale version matches no row (optimistic lock)', $q$with u as (update public.balances set available_units = available_units where version = 999 returning account_id) select count(*)::text from u$q$, '0');
select t.expect_error('an overdraft of 2 BTC is refused (available is 0.9994)', $q$update public.balances set available_units = -100000000 where account_id = (select id from public.accounts where user_id = '11111111-1111-1111-1111-111111111111' and kind = 'available')$q$, 'cannot go negative');

\echo '=== 11. privileges and policy shape'
select t.expect('anon has no SELECT on accounts', $q$select has_table_privilege('anon','public.accounts','SELECT')::text$q$, 'false');
select t.expect('anon has no SELECT on markets', $q$select has_table_privilege('anon','public.markets','SELECT')::text$q$, 'false');
select t.expect('anon has no SELECT on v_my_balances', $q$select has_table_privilege('anon','public.v_my_balances','SELECT')::text$q$, 'false');
select t.expect('authenticated has SELECT on accounts', $q$select has_table_privilege('authenticated','public.accounts','SELECT')::text$q$, 'true');
select t.expect('authenticated has no INSERT on accounts', $q$select has_table_privilege('authenticated','public.accounts','INSERT')::text$q$, 'false');
select t.expect('authenticated has no UPDATE on balances', $q$select has_table_privilege('authenticated','public.balances','UPDATE')::text$q$, 'false');
select t.expect('authenticated has no DELETE on orders', $q$select has_table_privilege('authenticated','public.orders','DELETE')::text$q$, 'false');
select t.expect('service_role has UPDATE on orders', $q$select has_table_privilege('service_role','public.orders','UPDATE')::text$q$, 'true');
select t.expect('service_role has UPDATE on balances', $q$select has_table_privilege('service_role','public.balances','UPDATE')::text$q$, 'true');
select t.expect('service_role has no UPDATE on ledger_entries', $q$select has_table_privilege('service_role','public.ledger_entries','UPDATE')::text$q$, 'false');
select t.expect('service_role has no DELETE on ledger_transactions', $q$select has_table_privilege('service_role','public.ledger_transactions','DELETE')::text$q$, 'false');
select t.expect('service_role has no UPDATE on order_events', $q$select has_table_privilege('service_role','public.order_events','UPDATE')::text$q$, 'false');
select t.expect('RLS enabled on all 10 exchange tables', $q$select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relrowsecurity and c.relname in ('app_settings','assets','markets','accounts','balances','ledger_transactions','ledger_entries','orders','order_events','trades')$q$, '10');
select t.expect('no policy on exchange tables mentions anon', $q$select count(*)::text from pg_policies where schemaname = 'public' and 'anon' = any(roles) and tablename in ('app_settings','assets','markets','accounts','balances','ledger_transactions','ledger_entries','orders','order_events','trades')$q$, '0');
select t.expect('no write policy for authenticated on exchange tables', $q$select count(*)::text from pg_policies where schemaname = 'public' and 'authenticated' = any(roles) and cmd <> 'SELECT' and tablename in ('app_settings','assets','markets','accounts','balances','ledger_transactions','ledger_entries','orders','order_events','trades')$q$, '0');
select t.expect('existing chat tables are untouched (still no RLS on admin_users)', $q$select count(*)::text from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname in ('chat_conversations','chat_messages','admin_users')$q$, '0');
