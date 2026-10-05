/*
# Migration 4/6 — orders, order events, trades (fills)

Purpose
-------
Storage for the order lifecycle and the trade tape. Deliberately contains no
matching logic: the engine (a future SECURITY DEFINER function called in one
transaction, or an edge function using the service role) is the only writer.

`orders`
--------
- `side` buy|sell, `type` limit|market, `time_in_force` gtc|ioc|fok (the current
  UI is limit-only; market orders are in the model because the plan requires
  them).
- Amounts are integer base units:
    * `qty_units`    — quantity in base-asset base units
    * `price_units`  — limit price of one whole base asset in quote base units,
                       scaled by 10^markets.price_scale. NULL = market order.
    * `quote_qty_units`   — the notional the buy reserved when the order was placed
    * `filled_qty_units` / `filled_quote_units` / `avg_price_units` — running fill state
    * `hold_amount_units` / `hold_released_units` — the balance hold this order
                       placed and how much of it has been released, plus the
                       `hold_asset_id` / `hold_account_id` / `hold_transaction_id`
                       it refers to. Kept on the order (one hold per order) rather
                       than in a separate `order_holds` table so there is exactly
                       one place that can disagree with the ledger.
- `client_order_id` is the client's idempotency key; unique per user+market when
  supplied.
- `status` new|partially_filled|filled|canceled|rejected|expired, with
  `closed_at` required once the order reaches a terminal status.
- A BEFORE INSERT trigger validates the order against its market (same
  environment, not disabled, price required for limit orders, respects
  `price_tick_units` / `qty_step_units` / `min_qty_units`) and the shared
  paper/live gate rejects `environment='live'` while the exchange is in paper
  mode.

`order_events`
--------------
Append-only audit of every state transition. Same immutability treatment as the
ledger (no UPDATE/DELETE by privilege or trigger).

`trades`
--------
One row per match: taker order, maker order, both users, price, quantity, quote
value, both fees, fee asset and the `ledger_transaction_id` that moved the funds.
Immutable like the ledger. Indexed for the public tape (`market_id, created_at`)
and for "my trade history" on either side. The public tape must be served
sanitised (no user ids) — that is a later read model, not this table.
*/

-- ---------------------------------------------------------------------------
-- orders
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  market_id uuid NOT NULL REFERENCES public.markets(id) ON DELETE RESTRICT,
  client_order_id text,
  side text NOT NULL,
  type text NOT NULL DEFAULT 'limit',
  time_in_force text NOT NULL DEFAULT 'gtc',
  price_units numeric(38, 0),
  qty_units numeric(38, 0) NOT NULL,
  quote_qty_units numeric(38, 0),
  filled_qty_units numeric(38, 0) NOT NULL DEFAULT 0,
  filled_quote_units numeric(38, 0) NOT NULL DEFAULT 0,
  avg_price_units numeric(38, 0),
  hold_amount_units numeric(38, 0) NOT NULL DEFAULT 0,
  hold_released_units numeric(38, 0) NOT NULL DEFAULT 0,
  hold_asset_id uuid REFERENCES public.assets(id) ON DELETE RESTRICT,
  hold_account_id uuid REFERENCES public.accounts(id) ON DELETE RESTRICT,
  hold_transaction_id uuid REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'new',
  reject_reason text,
  cancel_reason text,
  environment text NOT NULL DEFAULT 'paper',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz,
  CONSTRAINT orders_side_check CHECK (side IN ('buy', 'sell')),
  CONSTRAINT orders_type_check CHECK (type IN ('limit', 'market')),
  CONSTRAINT orders_tif_check CHECK (time_in_force IN ('gtc', 'ioc', 'fok')),
  CONSTRAINT orders_status_check CHECK (
    status IN ('new', 'partially_filled', 'filled', 'canceled', 'rejected', 'expired')
  ),
  CONSTRAINT orders_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT orders_client_order_id_check CHECK (
    client_order_id IS NULL OR length(client_order_id) BETWEEN 1 AND 100
  ),
  CONSTRAINT orders_qty_check CHECK (qty_units > 0),
  CONSTRAINT orders_price_check CHECK (price_units IS NULL OR price_units > 0),
  CONSTRAINT orders_limit_needs_price CHECK (type <> 'limit' OR price_units IS NOT NULL),
  CONSTRAINT orders_quote_qty_check CHECK (quote_qty_units IS NULL OR quote_qty_units >= 0),
  CONSTRAINT orders_filled_fits CHECK (
    filled_qty_units >= 0 AND filled_qty_units <= qty_units
    AND filled_quote_units >= 0
    AND (avg_price_units IS NULL OR avg_price_units > 0)
  ),
  CONSTRAINT orders_holds_non_negative CHECK (
    hold_amount_units >= 0 AND hold_released_units >= 0
    AND hold_released_units <= hold_amount_units
  ),
  CONSTRAINT orders_status_amounts_check CHECK (
    (status <> 'new' OR filled_qty_units = 0)
    AND (status <> 'filled' OR filled_qty_units = qty_units)
  ),
  CONSTRAINT orders_closed_at_check CHECK (
    status NOT IN ('filled', 'canceled', 'rejected', 'expired') OR closed_at IS NOT NULL
  )
);

-- client idempotency key
CREATE UNIQUE INDEX IF NOT EXISTS orders_client_order_id_key
  ON public.orders (user_id, market_id, client_order_id)
  WHERE client_order_id IS NOT NULL;

-- resting orders of a book: partial index keeps it small
CREATE INDEX IF NOT EXISTS orders_book_idx
  ON public.orders (market_id, side, price_units, created_at)
  WHERE status IN ('new', 'partially_filled');

CREATE INDEX IF NOT EXISTS orders_user_idx ON public.orders (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_user_open_idx
  ON public.orders (user_id, market_id)
  WHERE status IN ('new', 'partially_filled');

DROP TRIGGER IF EXISTS orders_environment_gate ON public.orders;
CREATE TRIGGER orders_environment_gate
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.enforce_environment_gate();

DROP TRIGGER IF EXISTS orders_set_updated_at ON public.orders;
CREATE TRIGGER orders_set_updated_at
  BEFORE UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- validate an order against its market before it exists
CREATE OR REPLACE FUNCTION public.orders_before_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_market public.markets;
BEGIN
  SELECT * INTO v_market FROM public.markets WHERE id = NEW.market_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'order references unknown market %', NEW.market_id
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  IF v_market.environment <> NEW.environment THEN
    RAISE EXCEPTION 'order environment % does not match market % environment %',
      NEW.environment, v_market.symbol, v_market.environment
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.status = 'disabled' THEN
    RAISE EXCEPTION 'market % is disabled', v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.type = 'limit' AND NEW.price_units IS NULL THEN
    RAISE EXCEPTION 'limit order on % requires price_units', v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.price_units IS NOT NULL
     AND v_market.price_tick_units > 0
     AND mod(NEW.price_units, v_market.price_tick_units) <> 0 THEN
    RAISE EXCEPTION 'price_units % does not respect tick size % on %',
      NEW.price_units, v_market.price_tick_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.qty_step_units > 0 AND mod(NEW.qty_units, v_market.qty_step_units) <> 0 THEN
    RAISE EXCEPTION 'qty_units % does not respect step size % on %',
      NEW.qty_units, v_market.qty_step_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.min_qty_units IS NOT NULL AND NEW.qty_units < v_market.min_qty_units THEN
    RAISE EXCEPTION 'qty_units % is below the minimum % on %',
      NEW.qty_units, v_market.min_qty_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- (orders_before_insert is a trigger function: see the note in migration 1 about
-- not revoking EXECUTE on trigger functions.)

DROP TRIGGER IF EXISTS orders_validate ON public.orders;
CREATE TRIGGER orders_validate
  BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.orders_before_insert();

COMMENT ON TABLE public.orders IS
  'Order lifecycle. Amounts in integer base units (qty_units in base asset units, price_units = price of one whole base asset in quote base units scaled by 10^markets.price_scale). Only the matching service writes here.';
COMMENT ON COLUMN public.orders.hold_amount_units IS
  'Balance hold placed by the engine for this order (one hold per order); hold_account_id/hold_asset_id identify the locked or available account, hold_transaction_id the ledger transaction that created it.';

-- ---------------------------------------------------------------------------
-- order_events — append-only audit of state transitions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.order_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  event text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  actor text NOT NULL DEFAULT 'engine',
  actor_user_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_events_event_check CHECK (event IN (
    'created', 'accepted', 'hold_placed', 'partially_filled', 'filled',
    'hold_released', 'canceled', 'rejected', 'expired'
  )),
  CONSTRAINT order_events_actor_check CHECK (actor IN ('engine', 'user', 'admin', 'system'))
);

CREATE INDEX IF NOT EXISTS order_events_order_idx ON public.order_events (order_id, created_at);
CREATE INDEX IF NOT EXISTS order_events_created_idx ON public.order_events (created_at DESC);

DROP TRIGGER IF EXISTS order_events_immutable ON public.order_events;
CREATE TRIGGER order_events_immutable
  BEFORE UPDATE OR DELETE ON public.order_events
  FOR EACH ROW EXECUTE FUNCTION public.reject_mutation();

COMMENT ON TABLE public.order_events IS
  'Append-only order audit trail (one row per state transition). No UPDATE/DELETE by privilege or trigger.';

-- ---------------------------------------------------------------------------
-- trades — one row per match, immutable
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.trades (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  market_id uuid NOT NULL REFERENCES public.markets(id) ON DELETE RESTRICT,
  price_units numeric(38, 0) NOT NULL,
  qty_units numeric(38, 0) NOT NULL,
  quote_units numeric(38, 0) NOT NULL,
  taker_side text NOT NULL,
  taker_order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  maker_order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE RESTRICT,
  taker_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  maker_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  taker_fee_units numeric(38, 0) NOT NULL DEFAULT 0,
  maker_fee_units numeric(38, 0) NOT NULL DEFAULT 0,
  fee_asset_id uuid REFERENCES public.assets(id) ON DELETE RESTRICT,
  ledger_transaction_id uuid REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  environment text NOT NULL DEFAULT 'paper',
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT trades_taker_side_check CHECK (taker_side IN ('buy', 'sell')),
  CONSTRAINT trades_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT trades_amounts_check CHECK (
    price_units > 0 AND qty_units > 0 AND quote_units >= 0
    AND taker_fee_units >= 0 AND maker_fee_units >= 0
  ),
  CONSTRAINT trades_orders_differ CHECK (taker_order_id <> maker_order_id),
  CONSTRAINT trades_fee_asset_check CHECK (
    (taker_fee_units = 0 AND maker_fee_units = 0) OR fee_asset_id IS NOT NULL
  )
);

CREATE INDEX IF NOT EXISTS trades_tape_idx ON public.trades (market_id, created_at DESC);
CREATE INDEX IF NOT EXISTS trades_taker_user_idx ON public.trades (taker_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS trades_maker_user_idx ON public.trades (maker_user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS trades_ledger_idx ON public.trades (ledger_transaction_id);

DROP TRIGGER IF EXISTS trades_environment_gate ON public.trades;
CREATE TRIGGER trades_environment_gate
  BEFORE INSERT ON public.trades
  FOR EACH ROW EXECUTE FUNCTION public.enforce_environment_gate();

DROP TRIGGER IF EXISTS trades_immutable ON public.trades;
CREATE TRIGGER trades_immutable
  BEFORE UPDATE OR DELETE ON public.trades
  FOR EACH ROW EXECUTE FUNCTION public.reject_mutation();

COMMENT ON TABLE public.trades IS
  'One row per match (taker + maker side, both fees, the ledger transaction that settled it). Immutable. The public tape must be served without user ids.';

-- same privilege treatment as the ledger: no editing history
DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON public.order_events FROM %I', r);
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON public.trades FROM %I', r);
    END IF;
  END LOOP;
END $$;
