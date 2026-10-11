/*
# Migration: release the unused hold when an order becomes filled
Defect (found in verification, measured on scratch PostgreSQL after migrations
20261005100060 + ...080): an order that reaches `filled` keeps whatever part of
its hold the fills did not consume locked for ever, because `close_order()`
refuses to do anything once the status is terminal:

    IF v_order.status NOT IN ('new', 'partially_filled') THEN
      RETURN;  -- already terminal, nothing to release
    END IF;

`settle_fill()` releases exactly the cost of each fill
(`hold_released_units += notional + buyer fee`), while the hold placed at order
time is `notional + trunc(notional * max_fee_bps / 10000)`. When the fills come
in at or below the price the hold was based on, the difference stays in the
account's `locked_units`. Measured, user 2:

    buy limit qty 25000: hold 15,057,525, hold_released 15,037,515
    3 fills: quote 15,030,000 + taker fee 7,515 = 15,037,515
    locked USDT left behind: 20,010           (= the unreleased fee cap)
    public.t_lk(user2,'USDT') = 20010 instead of 0

so a fully filled order silently strands user funds. Fix: a new
`release_order_remainder(order, reason)` posts one `order_release` transaction
for `hold_amount_units - hold_released_units` back to the available account and
records it on the order (`hold_released` event). `settle_fill()` calls it
whenever a side becomes `filled`. Semantics of every existing invariant are
unchanged: `hold_amount_units - hold_released_units` stays exactly what is still
locked, it merely reaches zero when the order is done.
*/
CREATE OR REPLACE FUNCTION public.release_order_remainder(
  p_order_id uuid,
  p_reason   text DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order  public.orders;
  v_left   numeric;
  v_avail  uuid;
  v_locked uuid;
  v_tx     uuid;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  v_left := COALESCE(v_order.hold_amount_units, 0) - COALESCE(v_order.hold_released_units, 0);
  IF v_left <= 0 THEN
    RETURN 0;
  END IF;
  v_locked := v_order.hold_account_id;
  v_avail  := public.ensure_user_account(v_order.user_id, v_order.hold_asset_id, 'available', v_order.environment);
  INSERT INTO public.ledger_transactions (type, environment, reference_type, reference_id, description, metadata)
  VALUES ('order_release', v_order.environment, 'order', v_order.id,
          format('release %s units of the unused hold on order %s (%s)', v_left, v_order.id, COALESCE(p_reason, 'terminal')),
          jsonb_build_object('order_id', v_order.id, 'asset_id', v_order.hold_asset_id,
                             'released_units', v_left, 'reason', p_reason))
  RETURNING id INTO v_tx;
  PERFORM public.post_entry(v_tx, v_locked, -v_left, 'hold remainder released');
  PERFORM public.post_entry(v_tx, v_avail,   v_left, 'hold remainder released back to available');
  UPDATE public.orders
     SET hold_released_units = hold_released_units + v_left
   WHERE id = p_order_id;
  INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
  VALUES (p_order_id, 'hold_released',
          jsonb_build_object('released_units', v_left, 'reason', p_reason),
          'engine', v_order.user_id);
  RETURN v_left;
END $$;
COMMENT ON FUNCTION public.release_order_remainder(uuid, text) IS
  'Returns the unused part of an order hold (hold_amount_units - hold_released_units) to the available account and records it. Internal to the engine; called when an order becomes filled.';
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'release_order_remainder'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f.sig);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f.sig);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
    END IF;
  END LOOP;
END $$;
CREATE OR REPLACE FUNCTION public.settle_fill(
  p_taker_order_id uuid,
  p_maker_order_id uuid,
  p_qty_units      numeric,
  p_price_units    numeric
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_taker  public.orders;
  v_maker  public.orders;
  v_market public.markets;
  v_ns     integer;
  v_notional    numeric;
  v_taker_fee   numeric;
  v_maker_fee   numeric;
  v_buyer  public.orders;
  v_seller public.orders;
  v_taker_is_buyer boolean;
  v_buyer_fee       numeric;
  v_seller_fee      numeric;
  v_buyer_debit     numeric;
  v_seller_credit   numeric;
  v_buy_locked_quote  uuid;
  v_buy_avail_base    uuid;
  v_sell_locked_base  uuid;
  v_sell_avail_quote  uuid;
  v_fee_account       uuid;
  v_tx        uuid;
  v_trade_id  uuid;
  v_t_side    text;
  v_m_side    text;
  v_t_filled  numeric;
  v_m_filled  numeric;
BEGIN
  PERFORM public.assert_trading_enabled();

  IF p_qty_units IS NULL OR p_qty_units <= 0 OR p_qty_units <> trunc(p_qty_units) THEN
    RAISE EXCEPTION 'settle_fill: bad quantity %', p_qty_units USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_taker FROM public.orders WHERE id = p_taker_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settle_fill: unknown taker order %', p_taker_order_id USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_maker FROM public.orders WHERE id = p_maker_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'settle_fill: unknown maker order %', p_maker_order_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_maker.user_id = v_taker.user_id THEN
    RAISE EXCEPTION 'settle_fill: order % may not trade with order % of the same user (self-match prevented)',
      p_taker_order_id, p_maker_order_id USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_market FROM public.markets WHERE id = v_taker.market_id;
  v_ns := v_market.notional_scale;

  IF p_price_units IS NULL OR p_price_units <= 0 THEN
    RAISE EXCEPTION 'settle_fill: a resting order with no price cannot be matched (market % order %)', v_market.symbol, p_maker_order_id
      USING ERRCODE = 'check_violation';
  END IF;

  v_notional := public.notional_units(p_qty_units, p_price_units, v_ns);
  IF v_notional IS NULL OR v_notional <= 0 THEN
    RAISE EXCEPTION 'fill of % base units at price % rounds to zero % : increase the size, the engine will not move base for no quote',
      p_qty_units, p_price_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  -- Fees in the quote asset, truncated toward zero (exchange's favour).
  v_taker_fee := trunc(v_notional * v_market.taker_fee_bps / 10000);
  v_maker_fee := trunc(v_notional * v_market.maker_fee_bps / 10000);

  v_taker_is_buyer := v_taker.side = 'buy';
  IF v_taker_is_buyer THEN
    v_buyer := v_taker; v_seller := v_maker;
  ELSE
    v_buyer := v_maker; v_seller := v_taker;
  END IF;

  v_buyer_fee    := CASE WHEN v_taker_is_buyer THEN v_taker_fee ELSE v_maker_fee END;
  v_seller_fee   := CASE WHEN v_taker_is_buyer THEN v_maker_fee ELSE v_taker_fee END;
  v_buyer_debit  := v_notional + v_buyer_fee;
  v_seller_credit := v_notional - v_seller_fee;

  v_buy_locked_quote := public.ensure_user_account(v_buyer.user_id,  v_market.quote_asset_id, 'locked',    v_taker.environment);
  v_buy_avail_base   := public.ensure_user_account(v_buyer.user_id,  v_market.base_asset_id,  'available', v_taker.environment);
  v_sell_locked_base := public.ensure_user_account(v_seller.user_id, v_market.base_asset_id,  'locked',    v_taker.environment);
  v_sell_avail_quote := public.ensure_user_account(v_seller.user_id, v_market.quote_asset_id, 'available', v_taker.environment);
  v_fee_account      := public.system_account_id('FEE_INCOME', v_market.quote_asset_id, v_taker.environment);

  -- Lock the balance rows in a deterministic order so two fills touching the
  -- same accounts cannot deadlock.
  PERFORM 1
     FROM public.balances
    WHERE account_id IN (v_buy_locked_quote, v_buy_avail_base, v_sell_locked_base, v_sell_avail_quote, v_fee_account)
    ORDER BY account_id
      FOR UPDATE;

  INSERT INTO public.ledger_transactions (type, environment, reference_type, reference_id, description, metadata)
  VALUES ('trade_fill', v_taker.environment, 'order', v_taker.id,
          format('fill %s %s at %s', p_qty_units, v_market.symbol, p_price_units),
          jsonb_build_object(
            'market_id', v_market.id,
            'taker_order_id', v_taker.id,
            'maker_order_id', v_maker.id,
            'taker_side', v_taker.side,
            'qty_units', p_qty_units,
            'price_units', p_price_units,
            'quote_units', v_notional,
            'taker_fee_units', v_taker_fee,
            'maker_fee_units', v_maker_fee))
  RETURNING id INTO v_tx;

  PERFORM public.post_entry(v_tx, v_buy_locked_quote, -v_buyer_debit,  'buy leg: hold consumed (notional + buyer fee)');
  PERFORM public.post_entry(v_tx, v_sell_locked_base, -p_qty_units,   'sell leg: hold consumed (base)');
  PERFORM public.post_entry(v_tx, v_buy_avail_base,   p_qty_units,    'base bought');
  IF v_seller_credit <> 0 THEN
    PERFORM public.post_entry(v_tx, v_sell_avail_quote, v_seller_credit, 'sale proceeds net of seller fee');
  END IF;
  IF (v_buyer_fee + v_seller_fee) <> 0 THEN
    PERFORM public.post_entry(v_tx, v_fee_account, v_buyer_fee + v_seller_fee, 'trading fees');
  END IF;

  INSERT INTO public.trades (
    market_id, price_units, qty_units, quote_units, taker_side,
    taker_order_id, maker_order_id, taker_user_id, maker_user_id,
    taker_fee_units, maker_fee_units, fee_asset_id, ledger_transaction_id, environment)
  VALUES (v_market.id, p_price_units, p_qty_units, v_notional, v_taker.side,
          v_taker.id, v_maker.id, v_taker.user_id, v_maker.user_id,
          v_taker_fee, v_maker_fee, v_market.quote_asset_id, v_tx, v_taker.environment)
  RETURNING id INTO v_trade_id;

  -- taker side
  v_t_filled := v_taker.filled_qty_units + p_qty_units;
  v_t_side := CASE WHEN v_t_filled >= v_taker.qty_units THEN 'filled' ELSE 'partially_filled' END;

  UPDATE public.orders
     SET filled_qty_units = v_t_filled,
         filled_quote_units = v_taker.filled_quote_units + v_notional,
         avg_price_units = public.price_units_from_notional(v_taker.filled_quote_units + v_notional, v_t_filled, v_ns),
         hold_released_units = v_taker.hold_released_units
                               + (CASE WHEN v_taker_is_buyer THEN v_buyer_debit ELSE p_qty_units END),
         status = v_t_side,
         closed_at = CASE WHEN v_t_side = 'filled' THEN now() ELSE NULL END
   WHERE id = v_taker.id;

  INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
  VALUES (v_taker.id, v_t_side,
          jsonb_build_object('trade_id', v_trade_id, 'counterparty_order_id', v_maker.id,
                             'qty_units', p_qty_units, 'price_units', p_price_units,
                             'quote_units', v_notional, 'fee_units', v_taker_fee,
                             'fee_asset', v_market.quote_asset_id),
          'engine', v_taker.user_id);
  -- a filled order may still hold an unused remainder (the buy-side fee cap and
  -- any price improvement); it must go back to available, not stay locked
  IF v_t_side = 'filled' THEN
    PERFORM public.release_order_remainder(v_taker.id, 'fully filled');
  END IF;

  -- maker side
  v_m_filled := v_maker.filled_qty_units + p_qty_units;
  v_m_side := CASE WHEN v_m_filled >= v_maker.qty_units THEN 'filled' ELSE 'partially_filled' END;

  UPDATE public.orders
     SET filled_qty_units = v_m_filled,
         filled_quote_units = v_maker.filled_quote_units + v_notional,
         avg_price_units = public.price_units_from_notional(v_maker.filled_quote_units + v_notional, v_m_filled, v_ns),
         hold_released_units = v_maker.hold_released_units
                               + (CASE WHEN v_taker_is_buyer THEN p_qty_units ELSE v_buyer_debit END),
         status = v_m_side,
         closed_at = CASE WHEN v_m_side = 'filled' THEN now() ELSE NULL END
   WHERE id = v_maker.id;

  INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
  VALUES (v_maker.id, v_m_side,
          jsonb_build_object('trade_id', v_trade_id, 'counterparty_order_id', v_taker.id,
                             'qty_units', p_qty_units, 'price_units', p_price_units,
                             'quote_units', v_notional, 'fee_units', v_maker_fee,
                             'fee_asset', v_market.quote_asset_id),
          'engine', v_maker.user_id);
  IF v_m_side = 'filled' THEN
    PERFORM public.release_order_remainder(v_maker.id, 'fully filled');
  END IF;

  RETURN v_trade_id;
END $$;
