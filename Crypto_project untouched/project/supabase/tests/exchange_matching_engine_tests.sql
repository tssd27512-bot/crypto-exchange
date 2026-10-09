-- Matching engine / order book / settlement tests.
-- Scratch PostgreSQL only (see tests/README.md). Never run against the live project.
-- PASS/FAIL lines are printed; the last line is a SUMMARY with the counts.

create temp table t_res(seq serial, label text, ok boolean);

create or replace function public.tc(p_label text, p_ok boolean) returns void
language plpgsql as $$
begin
  insert into t_res(label, ok) values (p_label, coalesce(p_ok, false));
end $$;

create or replace function public.t_av(p_user uuid, p_symbol text) returns numeric
language sql stable as $$
  select coalesce(b.available_units, 0)
    from public.accounts a
    join public.assets s on s.id = a.asset_id
    left join public.balances b on b.account_id = a.id
   where a.user_id = p_user and s.symbol = p_symbol and a.kind = 'available' and a.environment = 'paper'
$$;

create or replace function public.t_lk(p_user uuid, p_symbol text) returns numeric
language sql stable as $$
  select coalesce(b.locked_units, 0)
    from public.accounts a
    join public.assets s on s.id = a.asset_id
    left join public.balances b on b.account_id = a.id
   where a.user_id = p_user and s.symbol = p_symbol and a.kind = 'locked' and a.environment = 'paper'
$$;

create or replace function public.t_sys(p_code text, p_symbol text) returns numeric
language sql stable as $$
  select coalesce(b.available_units, 0)
    from public.accounts a
    join public.assets s on s.id = a.asset_id
    left join public.balances b on b.account_id = a.id
   where a.code = p_code and s.symbol = p_symbol and a.environment = 'paper'
$$;

-- paper funding, exactly as the faucet path will: a real zero-sum transaction
create or replace function public.t_fund(p_user uuid, p_symbol text, p_amount numeric) returns void
language plpgsql as $$
declare
  v_asset uuid;
  v_faucet uuid;
  v_account uuid;
  v_tx uuid;
begin
  select id into v_asset from public.assets where symbol = p_symbol;
  v_faucet := public.system_account_id('PAPER_FAUCET', v_asset, 'paper');
  v_account := public.ensure_user_account(p_user, v_asset, 'available', 'paper');
  insert into public.ledger_transactions (type, environment, reference_type, reference_id, description)
  values ('paper_funding', 'paper', 'user', p_user, format('scratch test funding %s %s', p_amount, p_symbol))
  returning id into v_tx;
  perform public.post_entry(v_tx, v_faucet, -p_amount, 'scratch test funding');
  perform public.post_entry(v_tx, v_account, p_amount, 'scratch test funding');
end $$;

-- ---------------------------------------------------------------------------
-- fixtures
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'u1@scratch.test'),
  ('00000000-0000-0000-0000-000000000002', 'u2@scratch.test'),
  ('00000000-0000-0000-0000-000000000003', 'u3@scratch.test');

-- make the seeded BTC/USDT paper market strict enough to prove tick/step/min validation
update public.markets
   set price_tick_units = 1000000, qty_step_units = 1000,
       min_qty_units = 1000, min_notional_units = 1000000
 where symbol = 'BTC/USDT' and environment = 'paper';

select public.t_fund('00000000-0000-0000-0000-000000000001', 'USDT', 1000000000);
select public.t_fund('00000000-0000-0000-0000-000000000001', 'BTC',  100000000);
select public.t_fund('00000000-0000-0000-0000-000000000002', 'USDT', 1000000000);
select public.t_fund('00000000-0000-0000-0000-000000000003', 'USDT', 1000000000);
select public.t_fund('00000000-0000-0000-0000-000000000003', 'BTC',  100000000);

select public.tc('T0.1 fixtures are a coherent ledger (no drift)',
  not exists (select 1 from public.v_account_reconciliation where drift_units <> 0));

-- ---------------------------------------------------------------------------
-- T1 full match: maker sell vs taker buy, fees, holds
-- ---------------------------------------------------------------------------
create temp table r1 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 100000, p_price_units := 6000000000000,
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
select public.tc('T1.1 maker sell rests open and its hold is locked',
  (select r->>'status' from r1) = 'new'
  and public.t_lk('00000000-0000-0000-0000-000000000001','BTC') = 100000
  and public.t_av('00000000-0000-0000-0000-000000000001','BTC') = 100000000);

create temp table r2 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
  p_qty_units := 100000, p_price_units := 6000000000000,
  p_user_id := '00000000-0000-0000-0000-000000000002') r;

select public.tc('T1.2 taker buy is fully filled', (select r->>'status' from r2) = 'filled');
select public.tc('T1.3 one fill, at the maker price', jsonb_array_length((select r->'fills' from r2)) = 1
  and (select r->'fills'->0->>'price_units' from r2) = '6000000000000');
select public.tc('T1.4 maker order is filled too',
  (select status from public.orders where id = (select (r->>'order_id')::uuid from r1)) = 'filled');
select public.tc('T1.5 trade row carries qty/quote/both fees',
  (select qty_units = 100000 and quote_units = 60000000
          and taker_fee_units = 30000 and maker_fee_units = 12000
          and fee_asset_id = (select id from public.assets where symbol = 'USDT')
     from public.trades where taker_order_id = (select (r->>'order_id')::uuid from r2)));
select public.tc('T1.6 buyer holds base, paid quote + taker fee',
  public.t_av('00000000-0000-0000-0000-000000000002','BTC') = 100000
  and public.t_av('00000000-0000-0000-0000-000000000002','USDT') = 1000000000 - (60000000 + 30000));
select public.tc('T1.7 seller received proceeds net of maker fee, hold consumed',
  public.t_av('00000000-0000-0000-0000-000000000001','USDT') = 1000000000 + (60000000 - 12000)
  and public.t_lk('00000000-0000-0000-0000-000000000001','BTC') = 0
  and public.t_av('00000000-0000-0000-0000-000000000001','BTC') = 100000000);
select public.tc('T1.8 fee income account collected both fees',
  public.t_sys('FEE_INCOME','USDT') = 42000);
select public.tc('T1.9 both orders released their whole hold',
  (select count(*) = 2 from public.orders
    where id in ((select (r->>'order_id')::uuid from r1), (select (r->>'order_id')::uuid from r2))
      and hold_amount_units = hold_released_units));
select public.tc('T1.10 order_events recorded created/hold/fill for the taker',
  (select count(*) from public.order_events
    where order_id = (select (r->>'order_id')::uuid from r2)
      and event in ('created','hold_placed','filled')) = 3);

-- ---------------------------------------------------------------------------
-- T2 partial fill, then the resting remainder is cancelled
-- ---------------------------------------------------------------------------
create temp table r3 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 50000, p_price_units := 6000000000000,
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
create temp table r4 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
  p_qty_units := 20000, p_price_units := 6000000000000,
  p_user_id := '00000000-0000-0000-0000-000000000002') r;

select public.tc('T2.1 maker partially filled, remainder stays locked',
  (select status from public.orders where id = (select (r->>'order_id')::uuid from r3)) = 'partially_filled'
  and (select filled_qty_units from public.orders where id = (select (r->>'order_id')::uuid from r3)) = 20000
  and (select qty_units - filled_qty_units from public.orders where id = (select (r->>'order_id')::uuid from r3)) = 30000
  and public.t_lk('00000000-0000-0000-0000-000000000001','BTC') = 30000);
select public.tc('T2.2 the fill is one 20000 trade with a proportional notional',
  (select qty_units = 20000 and quote_units = 12000000 and taker_fee_units = 6000 and maker_fee_units = 2400
     from public.trades where taker_order_id = (select (r->>'order_id')::uuid from r4)));

create temp table r5 as select public.cancel_order(
  p_order_id := (select (r->>'order_id')::uuid from r3),
  p_reason := 'test cleanup of the resting remainder',
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
select public.tc('T2.3 cancelling the remainder releases exactly what was locked',
  (select r->>'status' from r5) = 'canceled'
  and public.t_lk('00000000-0000-0000-0000-000000000001','BTC') = 0
  and public.t_av('00000000-0000-0000-0000-000000000001','BTC') = 100000000 - 100000 - 20000);

-- ---------------------------------------------------------------------------
-- T3 price-time priority
-- ---------------------------------------------------------------------------
create temp table r6 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6020000000000,
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
create temp table r7 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6010000000000,
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
create temp table r8 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6010000000000,
  p_user_id := '00000000-0000-0000-0000-000000000003') r;

update public.orders set created_at = now() - interval '3 minutes' where id = (select (r->>'order_id')::uuid from r6);
update public.orders set created_at = now() - interval '2 minutes' where id = (select (r->>'order_id')::uuid from r7);
update public.orders set created_at = now() - interval '1 minute'  where id = (select (r->>'order_id')::uuid from r8);

create temp table r9 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
  p_qty_units := 25000, p_price_units := 6020000000000,
  p_user_id := '00000000-0000-0000-0000-000000000002') r;

select public.tc('T3.1 best price first, then earliest order at that price',
  jsonb_array_length((select r->'fills' from r9)) = 3
  and (select r->'fills'->0->>'maker_order_id' from r9) = (select r->>'order_id' from r7)
  and (select r->'fills'->1->>'maker_order_id' from r9) = (select r->>'order_id' from r8)
  and (select r->'fills'->2->>'maker_order_id' from r9) = (select r->>'order_id' from r6)
  and (select r->'fills'->0->>'price_units' from r9) = '6010000000000'
  and (select r->'fills'->1->>'price_units' from r9) = '6010000000000'
  and (select r->'fills'->2->>'price_units' from r9) = '6020000000000');
select public.tc('T3.2 the 6.02e12 order only gave up its last 5000',
  (select filled_qty_units = 5000 and status = 'partially_filled'
     from public.orders where id = (select (r->>'order_id')::uuid from r6)));
select public.tc('T3.3 the two 6.01e12 orders are both filled',
  (select count(*) = 2 from public.orders
    where id in ((select (r->>'order_id')::uuid from r7), (select (r->>'order_id')::uuid from r8))
      and status = 'filled'));

-- ---------------------------------------------------------------------------
-- T4 a hold the buyer cannot afford is rejected, and moves nothing
-- ---------------------------------------------------------------------------
do $$
declare
  v_n bigint := (select count(*) from public.ledger_transactions);
begin
  perform public.cancel_order(p_order_id := (select (r->>'order_id')::uuid from r6),
                              p_reason := 'test cleanup', p_user_id := '00000000-0000-0000-0000-000000000001');
  v_n := (select count(*) from public.ledger_transactions);
  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 100000000, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T4.1 overspending hold is rejected', false);
  exception when others then
    perform public.tc('T4.1 overspending hold is rejected: ' || sqlerrm,
                      sqlerrm like '%insufficient available balance%');
  end;
  perform public.tc('T4.2 the rejected order wrote no ledger transaction',
    (select count(*) from public.ledger_transactions) = v_n);
end $$;

-- ---------------------------------------------------------------------------
-- T5 market order: best price first, fills what is there, cancels the rest
-- ---------------------------------------------------------------------------
create temp table r10 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6030000000000,
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
create temp table r11 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6050000000000,
  p_user_id := '00000000-0000-0000-0000-000000000003') r;

create temp table r12 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'market',
  p_qty_units := 25000,
  p_user_id := '00000000-0000-0000-0000-000000000002') r;

select public.tc('T5.1 market buy takes the best ask first',
  jsonb_array_length((select r->'fills' from r12)) = 2
  and (select r->'fills'->0->>'price_units' from r12) = '6030000000000'
  and (select r->'fills'->1->>'price_units' from r12) = '6050000000000');
select public.tc('T5.2 unfilled market remainder is cancelled, deterministically',
  (select r->>'status' from r12) = 'canceled'
  and (select r->>'cancel_reason' from r12) = 'insufficient_liquidity'
  and (select (r->>'filled_qty_units')::numeric from r12) = 20000
  and (select (r->>'hold_units')::numeric from r12) = 0);
select public.tc('T5.3 both maker sells are fully filled',
  (select count(*) = 2 from public.orders
    where id in ((select (r->>'order_id')::uuid from r10), (select (r->>'order_id')::uuid from r11))
      and status = 'filled'));
select public.tc('T5.4 the market buy paid no maker hold for the unfilled part (nothing left locked)',
  public.t_lk('00000000-0000-0000-0000-000000000002','USDT') = 0);

create temp table r13 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
  p_qty_units := 5000, p_price_units := 6000000000000,
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
create temp table r14 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'market',
  p_qty_units := 5000,
  p_user_id := '00000000-0000-0000-0000-000000000003') r;
select public.tc('T5.5 market sell fills completely against the best bid',
  (select r->>'status' from r14) = 'filled'
  and (select (r->>'filled_qty_units')::numeric from r14) = 5000
  and (select r->'fills'->0->>'price_units' from r14) = '6000000000000'
  and (select r->'fills'->0->>'qty_units' from r14) = '5000');

-- ---------------------------------------------------------------------------
-- T6 cancel releases the hold; a terminal order cannot be cancelled again
-- ---------------------------------------------------------------------------
create temp table r15 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6100000000000,
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
select public.tc('T6.1 an order with no counterparty rests, holding its base',
  (select r->>'status' from r15) = 'new'
  and public.t_lk('00000000-0000-0000-0000-000000000001','BTC') = 10000);

create temp table r16 as select public.cancel_order(
  p_order_id := (select (r->>'order_id')::uuid from r15),
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
select public.tc('T6.2 cancel releases the hold back to available',
  (select r->>'status' from r16) = 'canceled'
  and (select r->>'cancel_reason' from r16) = 'user_request'
  and public.t_lk('00000000-0000-0000-0000-000000000001','BTC') = 0
  and (select hold_amount_units = hold_released_units from public.orders
        where id = (select (r->>'order_id')::uuid from r15)));
select public.tc('T6.3 the release is a zero-sum order_release transaction with two events',
  (select count(*) = 1 from public.ledger_transactions
    where type = 'order_release' and reference_id = (select (r->>'order_id')::uuid from r15))
  and (select count(*) = 2 from public.order_events
        where order_id = (select (r->>'order_id')::uuid from r15)
          and event in ('canceled','hold_released')));

do $$
begin
  begin
    perform public.cancel_order(p_order_id := (select (r->>'order_id')::uuid from r15),
                                p_user_id := '00000000-0000-0000-0000-000000000001');
    perform public.tc('T6.4 an already terminal order cannot be cancelled twice', false);
  exception when others then
    perform public.tc('T6.4 an already terminal order cannot be cancelled twice: ' || sqlerrm,
                      sqlerrm like '%cannot be cancelled%');
  end;
end $$;

-- ---------------------------------------------------------------------------
-- T7 fees
-- ---------------------------------------------------------------------------
select public.tc('T7.1 fee income equals the sum of every trade''s fees (maker+taker)',
  public.t_sys('FEE_INCOME','USDT')
  = (select coalesce(sum(taker_fee_units + maker_fee_units), 0) from public.trades));
select public.tc('T7.2 every fee is exactly bps of the notional, truncated in the exchange''s favour',
  not exists (select 1 from public.trades t
               where t.taker_fee_units <> trunc(t.quote_units * 5 / 10000)
                  or t.maker_fee_units <> trunc(t.quote_units * 2 / 10000)));
select public.tc('T7.3 every trade has a fee asset and a ledger transaction',
  not exists (select 1 from public.trades where fee_asset_id is null or ledger_transaction_id is null));

-- ---------------------------------------------------------------------------
-- T8 ledger integrity over every fill that happened above
-- ---------------------------------------------------------------------------
select public.tc('T8.1 trades exist to check', (select count(*) from public.trades) >= 6);
select public.tc('T8.2 every ledger transaction is zero-sum per asset',
  not exists (select 1 from (select transaction_id, asset_id, sum(amount_units) net
                               from public.ledger_entries group by 1,2
                              having sum(amount_units) <> 0) x));
select public.tc('T8.3 every ledger transaction has >= 2 distinct accounts',
  not exists (select 1 from (select transaction_id from public.ledger_entries
                              group by 1 having count(distinct account_id) < 2) x));
select public.tc('T8.4 global sum of the ledger is zero per asset',
  not exists (select 1 from (select asset_id, sum(amount_units) net
                               from public.ledger_entries group by 1
                              having sum(amount_units) <> 0) x));
select public.tc('T8.5 each fill''s ledger transaction nets to zero on the base asset',
  not exists (select 1 from public.trades t
                join public.ledger_entries e on e.transaction_id = t.ledger_transaction_id
                join public.markets m on m.id = t.market_id
               where e.asset_id = m.base_asset_id
               group by t.id having sum(e.amount_units) <> 0));
select public.tc('T8.6 each fill''s ledger transaction nets to zero on the quote asset',
  not exists (select 1 from public.trades t
                join public.ledger_entries e on e.transaction_id = t.ledger_transaction_id
                join public.markets m on m.id = t.market_id
               where e.asset_id = m.quote_asset_id
               group by t.id having sum(e.amount_units) <> 0));
select public.tc('T8.7 no order over-released its hold',
  not exists (select 1 from public.orders where hold_released_units > hold_amount_units
                 or hold_released_units < 0));
select public.tc('T8.8 cached balances still equal the ledger (drift 0 everywhere)',
  not exists (select 1 from public.v_account_reconciliation where drift_units <> 0));
select public.tc('T8.9 every symbol''s ledger sums to zero',
  not exists (select 1 from (select s.symbol, sum(e.amount_units) net
                               from public.ledger_entries e join public.assets s on s.id = e.asset_id
                              group by 1 having sum(e.amount_units) <> 0) x));

-- ---------------------------------------------------------------------------
-- T9 mode gate
-- ---------------------------------------------------------------------------
do $$
begin
  update public.app_settings set paper_trading_enabled = false where id;
  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 10000, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T9.1 trading disabled blocks place_order', false);
  exception when others then
    perform public.tc('T9.1 trading disabled blocks place_order: ' || sqlerrm,
                      sqlerrm like '%trading is disabled%');
  end;
  begin
    perform public.cancel_order(p_order_id := gen_random_uuid(),
                                p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T9.2 trading disabled blocks cancel_order', false);
  exception when others then
    perform public.tc('T9.2 trading disabled blocks cancel_order: ' || sqlerrm,
                      sqlerrm like '%trading is disabled%');
  end;
  update public.app_settings set paper_trading_enabled = true where id;

  -- live mode with no live market: orders are routed by app_settings.mode, so
  -- nothing can leak into the live environment while we are configured for paper
  update public.app_settings set mode = 'live', live_trading_enabled = true, live_enabled_at = now() where id;
  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 10000, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T9.3 live mode has no live market, so no live order is possible', false);
  exception when others then
    perform public.tc('T9.3 live mode routes to the live environment (' || sqlerrm || ')',
                      sqlerrm like '%unknown market%live%');
  end;
  update public.app_settings set mode = 'paper', live_trading_enabled = false, live_enabled_at = null where id;
  perform public.tc('T9.4 no live row was ever created',
    not exists (select 1 from public.orders where environment = 'live')
    and not exists (select 1 from public.trades where environment = 'live'));
end $$;

-- ---------------------------------------------------------------------------
-- T10 loud boundary rejection (never silently rounded)
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 1000.5, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T10.1 fractional quantity is rejected', false);
  exception when others then
    perform public.tc('T10.1 fractional quantity is rejected: ' || sqlerrm, sqlerrm like '%fractional%');
  end;

  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 1000, p_price_units := 6000000000000.5,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T10.2 fractional price is rejected', false);
  exception when others then
    perform public.tc('T10.2 fractional price is rejected: ' || sqlerrm, sqlerrm like '%fractional%');
  end;

  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 1000, p_price_units := 6000000000001,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T10.3 price off the tick is rejected', false);
  exception when others then
    perform public.tc('T10.3 price off the tick is rejected: ' || sqlerrm, sqlerrm like '%tick size%');
  end;

  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 1500, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T10.4 quantity off the step is rejected', false);
  exception when others then
    perform public.tc('T10.4 quantity off the step is rejected: ' || sqlerrm, sqlerrm like '%step size%');
  end;

  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 500, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T10.5 quantity below the market minimum is rejected', false);
  exception when others then
    perform public.tc('T10.5 quantity below the market minimum is rejected: ' || sqlerrm, sqlerrm like '%below the minimum%');
  end;

  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'market',
      p_qty_units := 10000, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T10.6 a market order with a price is rejected', false);
  exception when others then
    perform public.tc('T10.6 a market order with a price is rejected: ' || sqlerrm, sqlerrm like '%must not carry price_units%');
  end;

  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
      p_qty_units := 10000,
      p_user_id := '00000000-0000-0000-0000-000000000001');
    perform public.tc('T10.7 a limit order without a price is rejected', false);
  exception when others then
    perform public.tc('T10.7 a limit order without a price is rejected: ' || sqlerrm, sqlerrm like '%requires price_units%');
  end;

  begin
    perform public.place_order(p_market_symbol := 'NOPE/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 10000, p_price_units := 100,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T10.8 an unknown market is rejected', false);
  exception when others then
    perform public.tc('T10.8 an unknown market is rejected: ' || sqlerrm, sqlerrm like '%unknown market%');
  end;
end $$;

create temp table r17 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'market',
  p_tif := 'fok', p_qty_units := 100000,
  p_user_id := '00000000-0000-0000-0000-000000000002') r;
select public.tc('T10.9 a FOK the book cannot fill is rejected without touching money',
  (select r->>'status' from r17) = 'rejected'
  and (select r->>'reject_reason' from r17) = 'fok_not_fillable'
  and (select count(*) = 0 from public.trades where taker_order_id = (select (r->>'order_id')::uuid from r17))
  and (select hold_amount_units = 0 from public.orders where id = (select (r->>'order_id')::uuid from r17)));

-- ---------------------------------------------------------------------------
-- T11 self-match prevention, client idempotency, identity
-- ---------------------------------------------------------------------------
create temp table r18 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6200000000000,
  p_client_order_id := 'scratch-self-match-1',
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
create temp table r19 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6300000000000,
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
select public.tc('T11.1 an order does not trade with its own user''s book',
  (select r->>'status' from r19) = 'new'
  and jsonb_array_length((select r->'fills' from r19)) = 0
  and (select filled_qty_units = 0 from public.orders where id = (select (r->>'order_id')::uuid from r18)));

create temp table r20 as select public.place_order(
  p_market_symbol := 'BTC/USDT', p_side := 'sell', p_type := 'limit',
  p_qty_units := 10000, p_price_units := 6200000000000,
  p_client_order_id := 'scratch-self-match-1',
  p_user_id := '00000000-0000-0000-0000-000000000001') r;
select public.tc('T11.2 a repeated client_order_id returns the original order (no double hold)',
  (select r->>'order_id' from r20) = (select r->>'order_id' from r18)
  and (select count(*) = 1 from public.orders
        where user_id = '00000000-0000-0000-0000-000000000001'
          and client_order_id = 'scratch-self-match-1'));

do $$
begin
  perform set_config('request.jwt.claims.sub', '00000000-0000-0000-0000-000000000001', true);
  begin
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 10000, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    perform public.tc('T11.3 a JWT caller cannot trade for another user', false);
  exception when others then
    perform public.tc('T11.3 a JWT caller cannot trade for another user: ' || sqlerrm,
                      sqlerrm like '%own orders%');
  end;
  perform set_config('request.jwt.claims.sub', '', true);
  perform set_config('request.jwt.claims.sub', '', false);
end $$;

-- ---------------------------------------------------------------------------
-- T12 order book / market data read models
-- ---------------------------------------------------------------------------
select public.tc('T12.1 best bid/ask, spread and depth levels are published',
  (select best_bid_units = 6300000000000 and best_ask_units = 6200000000000
          and best_bid_qty_units = 10000 and best_ask_qty_units = 10000
     from public.v_order_book_best where market_symbol = 'BTC/USDT')
  and (select count(*) = 2 from public.v_order_book_depth where market_symbol = 'BTC/USDT')
  and (select qty_units = 10000 and order_count = 1 and cumulative_qty_units = 10000
     from public.v_order_book_depth where market_symbol = 'BTC/USDT' and side = 'sell'));
select public.tc('T12.2 last price and 24h stats come from the trade tape',
  (select trade_count = (select count(*) from public.trades t join public.markets m on m.id = t.market_id
                          where m.symbol = 'BTC/USDT')
      and last_price_units is not null
      and volume_qty_units = (select sum(t.qty_units) from public.trades t join public.markets m on m.id = t.market_id
                               where m.symbol = 'BTC/USDT')
     from public.v_market_stats_24h where market_symbol = 'BTC/USDT'));
select public.tc('T12.3 v_markets exposes the config a client needs',
  (select taker_fee_bps = 5 and maker_fee_bps = 2 and price_tick_units = 1000000
          and base_symbol = 'BTC' and quote_symbol = 'USDT' and notional_scale = 10
     from public.v_markets where market_symbol = 'BTC/USDT'));
select public.tc('T12.4 the book views expose no user or account identity',
  not exists (select 1 from information_schema.columns
               where table_name in ('v_order_book_depth','v_order_book_best','v_market_stats_24h')
                 and column_name in ('user_id','taker_user_id','maker_user_id','account_id','code')));

do $$
declare
  v_n bigint;
begin
  EXECUTE 'set local role authenticated';
  begin
    select count(*) into v_n from public.v_order_book_depth;
    EXECUTE 'reset role';
    perform public.tc('T12.5 authenticated can read the aggregated book', v_n = 2);
  exception when others then
    EXECUTE 'reset role';
    perform public.tc('T12.5 authenticated can read the aggregated book: ' || sqlerrm, false);
  end;

  begin
    EXECUTE 'set local role anon';
    perform count(*) from public.v_order_book_depth;
    EXECUTE 'reset role';
    perform public.tc('T12.6 anon is denied the book', false);
  exception when others then
    EXECUTE 'reset role';
    perform public.tc('T12.6 anon is denied the book: ' || sqlerrm, sqlerrm like '%permission denied%');
  end;

  begin
    EXECUTE 'set local role anon';
    perform public.place_order(p_market_symbol := 'BTC/USDT', p_side := 'buy', p_type := 'limit',
      p_qty_units := 10000, p_price_units := 6000000000000,
      p_user_id := '00000000-0000-0000-0000-000000000002');
    EXECUTE 'reset role';
    perform public.tc('T12.7 anon cannot call place_order', false);
  exception when others then
    EXECUTE 'reset role';
    perform public.tc('T12.7 anon cannot call place_order: ' || sqlerrm, sqlerrm like '%permission denied%');
  end;
end $$;

-- ---------------------------------------------------------------------------
-- results
-- ---------------------------------------------------------------------------
select 'PASS ' || label from t_res where ok order by seq;
select 'FAIL ' || label from t_res where not ok order by seq;
select 'SUMMARY total=' || count(*) || ' pass=' || count(*) filter (where ok)
       || ' fail=' || count(*) filter (where not ok) from t_res;
