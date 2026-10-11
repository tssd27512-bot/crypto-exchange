/*
# Migration 7/8 — order book, matching engine and trade settlement (all in Postgres)

Purpose
-------
Turns the schema from migrations 1-6 into a working exchange: place an order,
match it price-time, settle the fills through the immutable double-entry ledger,
cancel an order and release its hold — all inside **one** transaction, all in
`SECURITY DEFINER` functions owned by the migration role (so RLS does not apply
to them, and a browser can never write a money row directly).

Entry points (granted to `authenticated` and `service_role` only)
----------------------------------------------------------------
- `place_order(  market_symbol, side, type, qty_units, price_units, tif,
                 client_order_id, user_id ) -> jsonb`
- `cancel_order( order_id, reason, user_id ) -> jsonb`

Identity: `auth.uid()` decides the actor. A caller with a JWT may only act for
themselves (`p_user_id` must be NULL or equal the JWT `sub`); a caller with no
JWT (a server-side / `service_role` call) must pass `p_user_id` explicitly.
Identity is never taken from the request body.

Amounts are **integer base units** everywhere (`numeric(38,0)`, see SCHEMA.md §2).
Fractional input is **rejected loudly** at this boundary, never rounded: a
client that sends 0.5 satoshi gets an error, not a silent 60001 (this is the
stronger guarantee the API layer needs; the table columns themselves still round,
so validation has to happen here).

Order lifecycle
---------------
`new` -> (`partially_filled`) -> `filled` | `canceled` | `rejected`
- a **limit GTC** order rests in the book (`new`, then `partially_filled`),
- a **market** order (or any IOC) fills what it can and the remainder is
  cancelled with `cancel_reason='insufficient_liquidity'` — deterministic, and
  documented rather than left implied,
- a **FOK** order is pre-checked against the book and, if the whole quantity is
  not fillable, is stored as `rejected` with `reject_reason='fok_not_fillable'`
  and moves no money at all.

Matching
--------
Price-time priority: best price first, then earliest `created_at` (ties by id).
The incoming order is the **taker**, resting orders are **makers**, and the fill
price is always the **maker's** price. Partial fills are the norm. An order never
trades with another order of the same user (self-match prevention), so a single
account cannot wash-trade its own book.

Holds and settlement
--------------------
Every order places a hold at placement time (debit the user's `available`
account, credit their `locked` account) and every fill consumes from that hold,
so a fill can never overdraw a user. `orders.hold_released_units` counts what is
no longer locked for the order (spent on fills **and** returned on close), so
`hold_amount_units - hold_released_units` is exactly what is still locked.

One fill = one `ledger_transactions` row of type `trade_fill`, carrying:
  buyer  locked <quote>  -(notional + buyer_fee)
  seller locked <base>   -qty
  buyer  available <base> +qty
  seller available <quote> +(notional - seller_fee)
  FEE_INCOME available <quote> +(buyer_fee + seller_fee)
which sums to zero per asset and moves the cached `balances` rows in the same
statement sequence (through `post_entry`, the only writer of ledger rows), so
the deferred invariants of migration 3 hold for every fill. Fees are charged in
the **quote** asset (maker/taker bps from `markets`), truncated toward zero in
the exchange's favour, and both fee columns of `trades` are in that same asset.

Mode gate
---------
`place_order`, `cancel_order` and `settle_fill` all call
`assert_trading_enabled()`, which reads the single `app_settings` row: in paper
mode (`mode='paper'`, the default) trading must be enabled by
`paper_trading_enabled`, in live mode by `live_trading_enabled`. Orders are
always written to the environment `app_settings.mode` says we are in, so while
the exchange is in paper mode no order, trade or ledger row can be created in
the `live` environment — the gate trigger from migration 1 enforces that
independently. Turning `paper_trading_enabled` off makes the engine inert.
(Fine-grained `LIVE_*` wiring is a later step; this is the single switch the
brief asked for.)

Paper mode is not a simulation: it is the same engine, the same ledger and the
same invariants, funded from the `PAPER_FAUCET` system account through
`paper_funding` / `admin_adjustment` transactions. Nothing here invents a
balance.
*/

-- ---------------------------------------------------------------------------
-- shared helpers
-- ---------------------------------------------------------------------------

-- The one place the paper/live switch is read by the engine. Returns the
-- environment the exchange is currently operating in, or raises.
CREATE OR REPLACE FUNCTION public.assert_trading_enabled()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_mode  text;
  v_paper boolean;
  v_live  boolean;
BEGIN
  SELECT mode, paper_trading_enabled, live_trading_enabled
    INTO v_mode, v_paper, v_live
    FROM public.app_settings
   WHERE id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'app_settings has no row: the paper/live mode gate cannot be evaluated'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_mode = 'live' THEN
    IF NOT COALESCE(v_live, false) THEN
      RAISE EXCEPTION 'live trading is disabled: app_settings.mode = live but live_trading_enabled = false; refusing to move funds'
        USING ERRCODE = 'check_violation';
    END IF;
  ELSE
    IF NOT COALESCE(v_paper, false) THEN
      RAISE EXCEPTION 'trading is disabled: paper_trading_enabled = false in app_settings (mode %); the engine is inert', v_mode
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN v_mode;
END $$;

COMMENT ON FUNCTION public.assert_trading_enabled() IS
  'Reads the single app_settings row and raises unless trading is enabled for the current mode. Returns the current environment (paper|live). Called by every money-moving entry point.';

-- Who is the order/actor for? auth.uid() if there is a JWT, otherwise the
-- explicitly supplied user id (server-side / service_role path only).
CREATE OR REPLACE FUNCTION public.resolve_order_actor(p_user_id uuid)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NOT NULL THEN
    IF p_user_id IS NOT NULL AND p_user_id <> v_caller THEN
      RAISE EXCEPTION 'a user may only act on their own orders (caller % requested %)', v_caller, p_user_id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_caller;
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'no authenticated caller and no explicit p_user_id: refusing to act on an unknown user'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %', p_user_id USING ERRCODE = 'no_data_found';
  END IF;

  RETURN p_user_id;
END $$;

COMMENT ON FUNCTION public.resolve_order_actor(uuid) IS
  'Resolves the acting user from auth.uid(), or from the explicit argument for server-side calls, and refuses to let a JWT-holding caller act for somebody else.';

-- A user's account for one asset/kind/environment, created on demand (with a
-- zero balance — never an invented amount).
CREATE OR REPLACE FUNCTION public.ensure_user_account(
  p_user_id     uuid,
  p_asset_id    uuid,
  p_kind        text,
  p_environment text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id
    FROM public.accounts
   WHERE user_id = p_user_id AND asset_id = p_asset_id
     AND kind = p_kind AND environment = p_environment;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO public.accounts (user_id, asset_id, kind, environment)
  VALUES (p_user_id, p_asset_id, p_kind, p_environment)
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_id
    FROM public.accounts
   WHERE user_id = p_user_id AND asset_id = p_asset_id
     AND kind = p_kind AND environment = p_environment;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'cannot provision a % % account for user % in %', p_kind, p_asset_id, p_user_id, p_environment
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN v_id;
END $$;

-- A system account (PAPER_FAUCET, FEE_INCOME, later EXTERNAL_*) for one asset.
CREATE OR REPLACE FUNCTION public.system_account_id(
  p_code        text,
  p_asset_id    uuid,
  p_environment text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  SELECT id INTO v_id
    FROM public.accounts
   WHERE code = p_code AND asset_id = p_asset_id
     AND kind = 'available' AND environment = p_environment;

  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  INSERT INTO public.accounts (account_type, code, asset_id, kind, environment)
  VALUES ('system', p_code, p_asset_id, 'available', p_environment)
  ON CONFLICT DO NOTHING;

  SELECT id INTO v_id
    FROM public.accounts
   WHERE code = p_code AND asset_id = p_asset_id
     AND kind = 'available' AND environment = p_environment;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'cannot provision system account % for asset % in %', p_code, p_asset_id, p_environment
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN v_id;
END $$;

-- The only writer of ledger rows in the engine: a posting and the matching
-- cache move happen together, always, so the deferred invariants of migration 3
-- cannot be broken by engine code. The account's `kind` decides whether the
-- amount lands in available_units or locked_units.
CREATE OR REPLACE FUNCTION public.post_entry(
  p_transaction_id uuid,
  p_account_id     uuid,
  p_amount_units   numeric,
  p_memo           text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account public.accounts;
BEGIN
  IF p_amount_units IS NULL OR p_amount_units = 0 THEN
    RAISE EXCEPTION 'refusing to post a zero/undefined amount to account % (transaction %)', p_account_id, p_transaction_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_amount_units <> trunc(p_amount_units) THEN
    RAISE EXCEPTION 'refusing to post a fractional amount (%) to account %', p_amount_units, p_account_id
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown account %', p_account_id USING ERRCODE = 'no_data_found';
  END IF;

  INSERT INTO public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units, memo)
  VALUES (p_transaction_id, p_account_id, v_account.asset_id, v_account.environment, p_amount_units, p_memo);

  -- relative increments (never absolute writes) so two concurrent fills on the
  -- same account serialise on the row lock instead of losing an update; the row
  -- is created if an account somehow has none.
  INSERT INTO public.balances (account_id, available_units, locked_units, last_entry_at)
  VALUES (p_account_id,
          CASE WHEN v_account.kind = 'locked' THEN 0 ELSE p_amount_units END,
          CASE WHEN v_account.kind = 'locked' THEN p_amount_units ELSE 0 END,
          now())
  ON CONFLICT (account_id) DO UPDATE
     SET available_units = public.balances.available_units
                           + CASE WHEN v_account.kind = 'locked' THEN 0 ELSE p_amount_units END,
         locked_units = public.balances.locked_units
                        + CASE WHEN v_account.kind = 'locked' THEN p_amount_units ELSE 0 END,
         last_entry_at = now();
END $$;

COMMENT ON FUNCTION public.post_entry(uuid, uuid, numeric, text) IS
  'Appends one signed ledger entry and moves the corresponding cached balance in the same statement, choosing available_units or locked_units from the account kind. Internal to the engine.';

-- How much of an order could trade right now, and for how much quote money.
-- Same ordering as the matcher (price-time), same price filters, same
-- self-match exclusion, so the pre-trade hold and the actual fills agree.
CREATE OR REPLACE FUNCTION public.book_fillable(
  p_market_id    uuid,
  p_side         text,
  p_price_units  numeric,
  p_max_qty      numeric,
  p_exclude_user uuid DEFAULT NULL
)
RETURNS TABLE (fillable_units numeric, gross_quote_units numeric)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_left  numeric := p_max_qty;
  v_fill  numeric;
  v_qty   numeric := 0;
  v_quote numeric := 0;
  v_ns    integer;
  r       record;
BEGIN
  SELECT notional_scale INTO v_ns FROM public.markets WHERE id = p_market_id;

  IF v_ns IS NULL OR p_max_qty IS NULL OR p_max_qty <= 0 THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric;
    RETURN;
  END IF;

  FOR r IN
    SELECT o.id,
           (o.qty_units - o.filled_qty_units) AS remaining,
           o.price_units
      FROM public.orders o
     WHERE o.market_id = p_market_id
       AND o.status IN ('new', 'partially_filled')
       AND o.side = CASE WHEN p_side = 'buy' THEN 'sell' ELSE 'buy' END
       AND o.price_units IS NOT NULL
       AND o.qty_units > o.filled_qty_units
       AND (p_exclude_user IS NULL OR o.user_id <> p_exclude_user)
       AND (p_price_units IS NULL
            OR (p_side = 'buy'  AND o.price_units <= p_price_units)
            OR (p_side = 'sell' AND o.price_units >= p_price_units))
     ORDER BY (CASE WHEN p_side = 'buy'  THEN o.price_units ELSE NULL END) ASC,
              (CASE WHEN p_side = 'sell' THEN o.price_units ELSE NULL END) DESC,
              o.created_at ASC,
              o.id ASC
  LOOP
    EXIT WHEN v_left <= 0;

    v_fill  := least(v_left, r.remaining);
    v_quote := v_quote + public.notional_units(v_fill, r.price_units, v_ns);
    v_qty   := v_qty + v_fill;
    v_left  := v_left - v_fill;
  END LOOP;

  RETURN QUERY SELECT v_qty, v_quote;
END $$;

-- ---------------------------------------------------------------------------
-- settlement of one fill (taker order x maker order)
-- ---------------------------------------------------------------------------
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

  RETURN v_trade_id;
END $$;

COMMENT ON FUNCTION public.settle_fill(uuid, uuid, numeric, numeric) IS
  'Settles one fill between a taker and a maker order: one trade_fill ledger transaction (buyer/seller/fee), the cached balance moves, the trade row, both order states and both order events — all in the caller''s transaction. Internal to the engine.';

-- ---------------------------------------------------------------------------
-- terminal state: release whatever is still locked for the order
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.close_order(
  p_order_id uuid,
  p_status   text,
  p_reason   text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order  public.orders;
  v_left   numeric;
  v_locked uuid;
  v_avail  uuid;
  v_tx     uuid;
  v_event  text;
BEGIN
  IF p_status NOT IN ('canceled', 'rejected', 'expired', 'filled') THEN
    RAISE EXCEPTION 'close_order: % is not a terminal status the engine sets', p_status
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'close_order: unknown order %', p_order_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_order.status NOT IN ('new', 'partially_filled') THEN
    RETURN;  -- already terminal, nothing to release
  END IF;

  v_left := v_order.hold_amount_units - v_order.hold_released_units;

  IF v_left > 0 THEN
    v_locked := v_order.hold_account_id;
    v_avail  := public.ensure_user_account(v_order.user_id, v_order.hold_asset_id, 'available', v_order.environment);

    INSERT INTO public.ledger_transactions (type, environment, reference_type, reference_id, description, metadata)
    VALUES ('order_release', v_order.environment, 'order', v_order.id,
            format('release %s units of the hold on order %s (%s)', v_left, v_order.id, COALESCE(p_reason, p_status)),
            jsonb_build_object('order_id', v_order.id, 'asset_id', v_order.hold_asset_id,
                               'released_units', v_left, 'reason', p_reason, 'status', p_status))
    RETURNING id INTO v_tx;

    PERFORM public.post_entry(v_tx, v_locked, -v_left, 'hold released');
    PERFORM public.post_entry(v_tx, v_avail,   v_left, 'hold released back to available');
  END IF;

  UPDATE public.orders
     SET status = p_status,
         closed_at = now(),
         cancel_reason = p_reason,
         reject_reason = CASE WHEN p_status = 'rejected' THEN p_reason ELSE reject_reason END,
         hold_released_units = hold_amount_units
   WHERE id = p_order_id;

  v_event := CASE p_status WHEN 'canceled' THEN 'canceled'
                           WHEN 'rejected' THEN 'rejected'
                           ELSE 'expired' END;

  INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
  VALUES (p_order_id, v_event,
          jsonb_build_object('reason', p_reason, 'status', p_status, 'released_units', v_left),
          'engine', v_order.user_id);

  IF v_left > 0 THEN
    INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
    VALUES (p_order_id, 'hold_released',
            jsonb_build_object('released_units', v_left, 'reason', p_reason),
            'engine', v_order.user_id);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- the matcher: price-time priority, partial fills, one tx per fill
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.match_order(
  p_order_id    uuid,
  p_should_rest boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_taker     public.orders;
  v_maker     public.orders;
  v_remaining numeric;
  v_fill      numeric;
  v_price     numeric;
  v_trade     uuid;
  v_fills     jsonb := '[]'::jsonb;
  v_reason    text;
BEGIN
  SELECT * INTO v_taker FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'match_order: unknown order %', p_order_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_taker.status NOT IN ('new', 'partially_filled') THEN
    RETURN v_fills;
  END IF;

  LOOP
    v_remaining := v_taker.qty_units - v_taker.filled_qty_units;
    EXIT WHEN v_remaining <= 0;

    -- best price first, then earliest; the book is the set of open orders of
    -- the opposite side that this order's price allows it to trade with.
    SELECT * INTO v_maker
      FROM public.orders o
     WHERE o.market_id = v_taker.market_id
       AND o.side <> v_taker.side
       AND o.status IN ('new', 'partially_filled')
       AND o.user_id <> v_taker.user_id
       AND o.price_units IS NOT NULL
       AND o.qty_units > o.filled_qty_units
       AND (v_taker.price_units IS NULL
            OR (v_taker.side = 'buy'  AND o.price_units <= v_taker.price_units)
            OR (v_taker.side = 'sell' AND o.price_units >= v_taker.price_units))
     ORDER BY (CASE WHEN v_taker.side = 'buy'  THEN o.price_units ELSE NULL END) ASC,
              (CASE WHEN v_taker.side = 'sell' THEN o.price_units ELSE NULL END) DESC,
              o.created_at ASC,
              o.id ASC
     LIMIT 1
       FOR UPDATE;

    EXIT WHEN NOT FOUND;

    v_fill  := least(v_remaining, v_maker.qty_units - v_maker.filled_qty_units);
    EXIT WHEN v_fill <= 0;

    v_price := v_maker.price_units;   -- the resting order's price is the trade price

    v_trade := public.settle_fill(v_taker.id, v_maker.id, v_fill, v_price);

    v_fills := v_fills || jsonb_build_object(
      'trade_id', v_trade,
      'maker_order_id', v_maker.id,
      'qty_units', v_fill,
      'price_units', v_price,
      'quote_units', public.notional_units(v_fill, v_price, (SELECT notional_scale FROM public.markets WHERE id = v_taker.market_id)));

    SELECT * INTO v_taker FROM public.orders WHERE id = p_order_id;
  END LOOP;

  SELECT * INTO v_taker FROM public.orders WHERE id = p_order_id;
  v_remaining := v_taker.qty_units - v_taker.filled_qty_units;

  IF v_remaining > 0 THEN
    IF p_should_rest THEN
      IF v_taker.filled_qty_units > 0 AND v_taker.status = 'new' THEN
        UPDATE public.orders SET status = 'partially_filled' WHERE id = p_order_id;
      END IF;
    ELSE
      v_reason := CASE WHEN v_taker.type = 'market' THEN 'insufficient_liquidity'
                       ELSE 'time_in_force' END;
      PERFORM public.close_order(p_order_id, 'canceled', v_reason);
    END IF;
  END IF;

  RETURN v_fills;
END $$;

COMMENT ON FUNCTION public.match_order(uuid, boolean) IS
  'Runs the price-time matcher for one order (best price, then earliest created_at). Returns the fills in execution order. A non-resting order (market / IOC) has its unfilled remainder cancelled with reason insufficient_liquidity or time_in_force. Internal to the engine.';

-- ---------------------------------------------------------------------------
-- entry point: place an order + hold + match
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.place_order(
  p_market_symbol   text,
  p_side            text,
  p_type            text,
  p_qty_units       numeric,
  p_price_units     numeric DEFAULT NULL,
  p_tif             text    DEFAULT 'gtc',
  p_client_order_id text    DEFAULT NULL,
  p_user_id         uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_env    text;
  v_user   uuid;
  v_market public.markets;
  v_side   text := lower(btrim(coalesce(p_side, '')));
  v_type   text := lower(btrim(coalesce(p_type, 'limit')));
  v_tif    text := lower(btrim(coalesce(p_tif, 'gtc')));
  v_qty    numeric;
  v_price  numeric;
  v_client text := nullif(btrim(coalesce(p_client_order_id, '')), '');
  v_order_id  uuid;
  v_existing  uuid;
  v_ns        integer;
  v_should_rest boolean;
  v_fillable  numeric;
  v_gross     numeric;
  v_hold      numeric := 0;
  v_fee_cap   numeric := 0;
  v_max_bps   integer;
  v_hold_asset       uuid;
  v_hold_account     uuid;
  v_available_account uuid;
  v_available  numeric;
  v_tx        uuid;
  v_fills     jsonb;
  v_order     public.orders;
BEGIN
  -- mode gate: throws unless trading is enabled for the current mode
  v_env  := public.assert_trading_enabled();
  -- identity: never from the request body
  v_user := public.resolve_order_actor(p_user_id);

  -- ---- boundary validation: integers only, rejected loudly, never rounded ----
  IF v_side NOT IN ('buy', 'sell') THEN
    RAISE EXCEPTION 'side must be buy or sell (got %)', coalesce(p_side, 'NULL')
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_type NOT IN ('limit', 'market') THEN
    RAISE EXCEPTION 'type must be limit or market (got %)', coalesce(p_type, 'NULL')
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_tif NOT IN ('gtc', 'ioc', 'fok') THEN
    RAISE EXCEPTION 'time_in_force must be gtc, ioc or fok (got %)', coalesce(p_tif, 'NULL')
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_qty_units IS NULL THEN
    RAISE EXCEPTION 'qty_units is required (integer base units)'
      USING ERRCODE = 'check_violation';
  END IF;

  v_qty := p_qty_units;
  IF v_qty <> trunc(v_qty) THEN
    RAISE EXCEPTION 'qty_units must be a whole number of base units, got %: fractional amounts are rejected, not rounded', p_qty_units
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_qty <= 0 THEN
    RAISE EXCEPTION 'qty_units must be > 0 (got %)', v_qty USING ERRCODE = 'check_violation';
  END IF;

  IF p_price_units IS NOT NULL THEN
    v_price := p_price_units;
    IF v_price <> trunc(v_price) THEN
      RAISE EXCEPTION 'price_units must be a whole number of quote base units, got %: fractional amounts are rejected, not rounded', p_price_units
        USING ERRCODE = 'check_violation';
    END IF;
    IF v_price <= 0 THEN
      RAISE EXCEPTION 'price_units must be > 0 (got %)', v_price USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF v_type = 'limit' AND v_price IS NULL THEN
    RAISE EXCEPTION 'a limit order requires price_units'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_type = 'market' AND v_price IS NOT NULL THEN
    RAISE EXCEPTION 'a market order must not carry price_units (got %); the fill price comes from the book', v_price
      USING ERRCODE = 'check_violation';
  END IF;

  -- ---- market configuration ----
  SELECT * INTO v_market
    FROM public.markets
   WHERE symbol = p_market_symbol AND environment = v_env;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown market % in the % environment (app_settings.mode)', coalesce(p_market_symbol, 'NULL'), v_env
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT v_market.is_active OR v_market.status <> 'trading' THEN
    RAISE EXCEPTION 'market % is not trading (status %, is_active %)', v_market.symbol, v_market.status, v_market.is_active
      USING ERRCODE = 'check_violation';
  END IF;

  v_ns := v_market.notional_scale;

  IF v_price IS NOT NULL AND v_market.price_tick_units > 0
     AND mod(v_price, v_market.price_tick_units) <> 0 THEN
    RAISE EXCEPTION 'price_units % does not respect the tick size % on %', v_price, v_market.price_tick_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.qty_step_units > 0 AND mod(v_qty, v_market.qty_step_units) <> 0 THEN
    RAISE EXCEPTION 'qty_units % does not respect the step size % on %', v_qty, v_market.qty_step_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.min_qty_units IS NOT NULL AND v_qty < v_market.min_qty_units THEN
    RAISE EXCEPTION 'qty_units % is below the minimum % on %', v_qty, v_market.min_qty_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.min_notional_units IS NOT NULL AND v_price IS NOT NULL
     AND public.notional_units(v_qty, v_price, v_ns) < v_market.min_notional_units THEN
    RAISE EXCEPTION 'order notional % is below the minimum % on %',
      public.notional_units(v_qty, v_price, v_ns), v_market.min_notional_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  -- ---- idempotency: a retried client_order_id returns the original order ----
  IF v_client IS NOT NULL THEN
    SELECT id INTO v_existing
      FROM public.orders
     WHERE user_id = v_user AND market_id = v_market.id AND client_order_id = v_client;

    IF v_existing IS NOT NULL THEN
      RETURN public.order_result(v_existing, '[]'::jsonb);
    END IF;
  END IF;

  v_should_rest := (v_type = 'limit' AND v_tif = 'gtc');

  -- ---- pre-trade plan: what could fill, and therefore what to hold ----
  IF v_type = 'market' OR v_tif = 'fok' THEN
    SELECT f.fillable_units, f.gross_quote_units
      INTO v_fillable, v_gross
      FROM public.book_fillable(v_market.id, v_side, v_price, v_qty, v_user) f;
  END IF;

  -- FOK that cannot fill completely never trades: no hold, no ledger rows.
  IF v_tif = 'fok' AND COALESCE(v_fillable, 0) < v_qty THEN
    INSERT INTO public.orders (user_id, market_id, client_order_id, side, type, time_in_force,
                               price_units, qty_units, status, reject_reason, environment, closed_at)
    VALUES (v_user, v_market.id, v_client, v_side, v_type, v_tif,
            v_price, v_qty, 'rejected', 'fok_not_fillable', v_env, now())
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
    VALUES (v_order_id, 'rejected',
            jsonb_build_object('reason', 'fok_not_fillable', 'qty_units', v_qty,
                               'fillable_units', COALESCE(v_fillable, 0)),
            'engine', v_user);

    RETURN public.order_result(v_order_id, '[]'::jsonb);
  END IF;

  v_max_bps := greatest(v_market.taker_fee_bps, v_market.maker_fee_bps);

  IF v_side = 'sell' THEN
    v_hold_asset := v_market.base_asset_id;
    v_hold := v_qty;
  ELSE
    v_hold_asset := v_market.quote_asset_id;
    IF v_type = 'market' THEN
      -- hold only what the visible book can actually take
      v_gross := COALESCE(v_gross, 0);
    ELSE
      v_gross := public.notional_units(v_qty, v_price, v_ns);
    END IF;
    v_fee_cap := trunc(v_gross * v_max_bps / 10000);
    v_hold := v_gross + v_fee_cap;
  END IF;

  v_available_account := public.ensure_user_account(v_user, v_hold_asset, 'available', v_env);
  v_hold_account      := public.ensure_user_account(v_user, v_hold_asset, 'locked',    v_env);

  IF v_hold > 0 THEN
    SELECT COALESCE(b.available_units, 0) INTO v_available
      FROM public.balances b WHERE b.account_id = v_available_account;

    IF COALESCE(v_available, 0) < v_hold THEN
      RAISE EXCEPTION 'insufficient available balance: order needs % base units to hold but only % are available on account %',
        v_hold, COALESCE(v_available, 0), v_available_account
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- ---- the order ----
  INSERT INTO public.orders (user_id, market_id, client_order_id, side, type, time_in_force,
                             price_units, qty_units, quote_qty_units,
                             hold_asset_id, hold_account_id, status, environment)
  VALUES (v_user, v_market.id, v_client, v_side, v_type, v_tif,
          v_price, v_qty, CASE WHEN v_side = 'buy' THEN v_gross ELSE NULL END,
          v_hold_asset, v_hold_account, 'new', v_env)
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
  VALUES (v_order_id, 'created',
          jsonb_build_object('side', v_side, 'type', v_type, 'time_in_force', v_tif,
                             'qty_units', v_qty, 'price_units', v_price,
                             'market', v_market.symbol, 'environment', v_env),
          'engine', v_user);

  -- ---- hold ----
  IF v_hold > 0 THEN
    INSERT INTO public.ledger_transactions (type, environment, reference_type, reference_id, description, metadata)
    VALUES ('order_hold', v_env, 'order', v_order_id,
            format('hold %s units for %s order', v_hold, v_side),
            jsonb_build_object('order_id', v_order_id, 'asset_id', v_hold_asset,
                               'amount_units', v_hold, 'side', v_side, 'market_id', v_market.id))
    RETURNING id INTO v_tx;

    PERFORM public.post_entry(v_tx, v_available_account, -v_hold, 'held for order');
    PERFORM public.post_entry(v_tx, v_hold_account,      v_hold, 'held for order');

    UPDATE public.orders
       SET hold_amount_units = v_hold, hold_transaction_id = v_tx
     WHERE id = v_order_id;

    INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
    VALUES (v_order_id, 'hold_placed',
            jsonb_build_object('hold_units', v_hold, 'asset_id', v_hold_asset,
                               'ledger_transaction_id', v_tx),
            'engine', v_user);
  END IF;

  -- ---- match ----
  v_fills := public.match_order(v_order_id, v_should_rest);

  RETURN public.order_result(v_order_id, v_fills);
END $$;

COMMENT ON FUNCTION public.place_order(text, text, text, numeric, numeric, text, text, uuid) IS
  'Places a limit or market order (integer base units only; fractional input is rejected), holds the right balance, matches it price-time in the same transaction and returns the order state plus the fills in execution order.';

-- The jsonb the API returns for an order (no counterparty identity).
CREATE OR REPLACE FUNCTION public.order_result(p_order_id uuid, p_fills jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_order public.orders;
  v_symbol text;
BEGIN
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'order_result: unknown order %', p_order_id USING ERRCODE = 'no_data_found';
  END IF;

  SELECT symbol INTO v_symbol FROM public.markets WHERE id = v_order.market_id;

  RETURN jsonb_build_object(
    'order_id', v_order.id,
    'market', v_symbol,
    'environment', v_order.environment,
    'side', v_order.side,
    'type', v_order.type,
    'time_in_force', v_order.time_in_force,
    'status', v_order.status,
    'price_units', v_order.price_units,
    'qty_units', v_order.qty_units,
    'filled_qty_units', v_order.filled_qty_units,
    'filled_quote_units', v_order.filled_quote_units,
    'avg_price_units', v_order.avg_price_units,
    'hold_units', v_order.hold_amount_units - v_order.hold_released_units,
    'hold_amount_units', v_order.hold_amount_units,
    'client_order_id', v_order.client_order_id,
    'reject_reason', v_order.reject_reason,
    'cancel_reason', v_order.cancel_reason,
    'created_at', v_order.created_at,
    'closed_at', v_order.closed_at,
    'fills', COALESCE(p_fills, '[]'::jsonb),
    'trades', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'trade_id', t.id,
               'maker_order_id', t.maker_order_id,
               'qty_units', t.qty_units,
               'price_units', t.price_units,
               'quote_units', t.quote_units,
               'taker_side', t.taker_side,
               'taker_fee_units', t.taker_fee_units,
               'maker_fee_units', t.maker_fee_units,
               'fee_asset_id', t.fee_asset_id,
               'ledger_transaction_id', t.ledger_transaction_id
             ) ORDER BY t.created_at, t.id)
        FROM public.trades t
       WHERE t.taker_order_id = p_order_id OR t.maker_order_id = p_order_id), '[]'::jsonb)
  );
END $$;

-- ---------------------------------------------------------------------------
-- entry point: cancel an open order and release its hold
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_reason   text DEFAULT NULL,
  p_user_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user  uuid;
  v_order public.orders;
BEGIN
  -- mode gate (see the header note: cancellation consults app_settings too, so
  -- the engine stays inert while trading is disabled)
  PERFORM public.assert_trading_enabled();

  v_user := public.resolve_order_actor(p_user_id);

  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown order %', p_order_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_order.user_id <> v_user THEN
    RAISE EXCEPTION 'order % does not belong to user %', p_order_id, v_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_order.status NOT IN ('new', 'partially_filled') THEN
    RAISE EXCEPTION 'order % is % and cannot be cancelled', p_order_id, v_order.status
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM public.close_order(p_order_id, 'canceled', COALESCE(nullif(btrim(coalesce(p_reason, '')), ''), 'user_request'));

  RETURN public.order_result(p_order_id, '[]'::jsonb);
END $$;

COMMENT ON FUNCTION public.cancel_order(uuid, text, uuid) IS
  'Cancels an open (new/partially_filled) order the caller owns, releases whatever is still locked, marks it canceled and appends order events. Idempotent in effect: an already terminal order is rejected.';

-- ---------------------------------------------------------------------------
-- grants: entry points for authenticated + service_role, internals for nobody
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.place_order(text, text, text, numeric, numeric, text, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_order(uuid, text, uuid) FROM PUBLIC;

DO $$
DECLARE
  r text;
  f text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      FOREACH f IN ARRAY ARRAY[
        'public.assert_trading_enabled()',
        'public.resolve_order_actor(uuid)',
        'public.ensure_user_account(uuid, uuid, text, text)',
        'public.system_account_id(text, uuid, text)',
        'public.post_entry(uuid, uuid, numeric, text)',
        'public.book_fillable(uuid, text, numeric, numeric, uuid)',
        'public.settle_fill(uuid, uuid, numeric, numeric)',
        'public.close_order(uuid, text, text)',
        'public.match_order(uuid, boolean)',
        'public.order_result(uuid, jsonb)'
      ] LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %I', f, r);
      END LOOP;
    END IF;
  END LOOP;
END $$;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.place_order(text, text, text, numeric, numeric, text, text, uuid) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, text, uuid) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION public.place_order(text, text, text, numeric, numeric, text, text, uuid) TO service_role;
    GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, text, uuid) TO service_role;
    -- the internals stay callable by the engine owner and by the server role only
    GRANT EXECUTE ON FUNCTION public.match_order(uuid, boolean) TO service_role;
    GRANT EXECUTE ON FUNCTION public.settle_fill(uuid, uuid, numeric, numeric) TO service_role;
    GRANT EXECUTE ON FUNCTION public.close_order(uuid, text, text) TO service_role;
    GRANT EXECUTE ON FUNCTION public.book_fillable(uuid, text, numeric, numeric, uuid) TO service_role;
    GRANT EXECUTE ON FUNCTION public.post_entry(uuid, uuid, numeric, text) TO service_role;
    GRANT EXECUTE ON FUNCTION public.order_result(uuid, jsonb) TO service_role;
  END IF;
END $$;

COMMENT ON FUNCTION public.place_order(text, text, text, numeric, numeric, text, text, uuid) IS
  'Entry point. auth.uid() decides the actor; a JWT-holding caller may only trade for themselves. REVOKEd from anon.';
COMMENT ON FUNCTION public.cancel_order(uuid, text, uuid) IS
  'Entry point. Releases the remaining hold of an open order the caller owns. REVOKEd from anon.';
