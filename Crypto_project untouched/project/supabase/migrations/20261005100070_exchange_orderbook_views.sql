/*
# Migration 8/8 — order book and market data read models

What the frontend reads from (all of it `authenticated` / `service_role` only —
`anon` is revoked, exactly like the rest of the exchange surface):

| View | What it is |
|---|---|
| `v_markets` | trading pairs with asset symbols, decimals, tick/step/min sizes and fees |
| `v_order_book_depth` | aggregated depth per price level (remaining qty, order count, cumulative qty) |
| `v_order_book_best` | best bid/ask + quantities + spread + last trade price per market |
| `v_market_stats_24h` | rolling 24h trade count, high/low, volume (base and quote), last price |

These four views are deliberately **owner-run** (no `security_invoker`), unlike
`v_my_balances`: they aggregate the whole book and tape, and under
`security_invoker` the RLS policies on `orders`/`trades` would hide every other
user's rows, so the depth would silently be "my orders only" — wrong, and wrong
in a way nobody would notice. The safety property that matters is preserved by
construction: **the views expose no user id and no account id** — only prices,
aggregated quantities and counts. (A trade's counterparty identity must never
reach a client; see SCHEMA.md.)
*/

CREATE OR REPLACE VIEW public.v_markets AS
SELECT
  m.id             AS market_id,
  m.symbol         AS market_symbol,
  m.environment,
  m.status         AS market_status,
  m.is_active,
  b.symbol         AS base_symbol,
  b.base_decimals  AS base_decimals,
  q.symbol         AS quote_symbol,
  q.base_decimals  AS quote_decimals,
  m.price_scale,
  m.notional_scale,
  m.price_tick_units,
  m.qty_step_units,
  m.min_qty_units,
  m.min_notional_units,
  m.maker_fee_bps,
  m.taker_fee_bps
FROM public.markets m
JOIN public.assets b ON b.id = m.base_asset_id
JOIN public.assets q ON q.id = m.quote_asset_id;

CREATE OR REPLACE VIEW public.v_order_book_depth AS
SELECT
  d.market_id,
  d.market_symbol,
  d.environment,
  d.side,
  d.price_units,
  d.qty_units,
  d.order_count,
  d.oldest_order_at,
  sum(d.qty_units) OVER (
    PARTITION BY d.market_id, d.environment, d.side
    ORDER BY (CASE WHEN d.side = 'buy'  THEN d.price_units ELSE NULL END) ASC,
             (CASE WHEN d.side = 'sell' THEN d.price_units ELSE NULL END) DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
  ) AS cumulative_qty_units
FROM (
  SELECT
    o.market_id,
    m.symbol AS market_symbol,
    o.environment,
    o.side,
    o.price_units,
    sum(o.qty_units - o.filled_qty_units) AS qty_units,
    count(*) AS order_count,
    min(o.created_at) AS oldest_order_at
  FROM public.orders o
  JOIN public.markets m ON m.id = o.market_id
  WHERE o.status IN ('new', 'partially_filled')
    AND o.price_units IS NOT NULL
    AND o.qty_units > o.filled_qty_units
  GROUP BY o.market_id, m.symbol, o.environment, o.side, o.price_units
) d;

CREATE OR REPLACE VIEW public.v_order_book_best AS
SELECT
  m.id AS market_id,
  m.symbol AS market_symbol,
  m.environment,
  m.status AS market_status,
  bid.price_units AS best_bid_units,
  bid.qty_units   AS best_bid_qty_units,
  ask.price_units AS best_ask_units,
  ask.qty_units   AS best_ask_qty_units,
  CASE WHEN bid.price_units IS NOT NULL AND ask.price_units IS NOT NULL
       THEN ask.price_units - bid.price_units END AS spread_units,
  last_t.price_units AS last_price_units,
  last_t.created_at  AS last_trade_at
FROM public.markets m
LEFT JOIN LATERAL (
  SELECT d.price_units, d.qty_units FROM public.v_order_book_depth d
   WHERE d.market_id = m.id AND d.side = 'buy'
   ORDER BY d.price_units DESC LIMIT 1
) bid ON true
LEFT JOIN LATERAL (
  SELECT d.price_units, d.qty_units FROM public.v_order_book_depth d
   WHERE d.market_id = m.id AND d.side = 'sell'
   ORDER BY d.price_units ASC LIMIT 1
) ask ON true
LEFT JOIN LATERAL (
  SELECT t.price_units, t.created_at FROM public.trades t
   WHERE t.market_id = m.id
   ORDER BY t.created_at DESC, t.id DESC LIMIT 1
) last_t ON true;

CREATE OR REPLACE VIEW public.v_market_stats_24h AS
SELECT
  m.id AS market_id,
  m.symbol AS market_symbol,
  m.environment,
  COALESCE(s.trade_count, 0) AS trade_count,
  s.open_price_units,
  s.last_price_units,
  s.low_price_units,
  s.high_price_units,
  s.volume_qty_units,
  s.volume_quote_units,
  s.last_trade_at
FROM public.markets m
LEFT JOIN LATERAL (
  SELECT
    count(*) AS trade_count,
    (array_agg(t.price_units ORDER BY t.created_at ASC,  t.id ASC))[1]  AS open_price_units,
    (array_agg(t.price_units ORDER BY t.created_at DESC, t.id DESC))[1] AS last_price_units,
    min(t.price_units) AS low_price_units,
    max(t.price_units) AS high_price_units,
    sum(t.qty_units)   AS volume_qty_units,
    sum(t.quote_units) AS volume_quote_units,
    max(t.created_at)  AS last_trade_at
  FROM public.trades t
  WHERE t.market_id = m.id
    AND t.created_at >= now() - interval '24 hours'
) s ON true;

COMMENT ON VIEW public.v_order_book_depth IS
  'Aggregated order book depth per price level (remaining qty, order count, cumulative qty). Owner-run on purpose so the whole book is visible; contains no user or account ids.';
COMMENT ON VIEW public.v_order_book_best IS
  'Best bid/ask, their quantities, the spread and the last trade price per market. No counterparty identity.';
COMMENT ON VIEW public.v_market_stats_24h IS
  'Rolling 24h market statistics: trade count, open/last/low/high price, volume in base and quote units.';
COMMENT ON VIEW public.v_markets IS
  'Trading pairs with base/quote symbols, decimals, price/quantity increments and maker/taker fees — the configuration a client needs to build a valid order.';

REVOKE ALL ON public.v_markets, public.v_order_book_depth, public.v_order_book_best, public.v_market_stats_24h FROM PUBLIC;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON public.v_markets, public.v_order_book_depth, public.v_order_book_best, public.v_market_stats_24h FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT SELECT ON public.v_markets, public.v_order_book_depth, public.v_order_book_best, public.v_market_stats_24h TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT SELECT ON public.v_markets, public.v_order_book_depth, public.v_order_book_best, public.v_market_stats_24h TO service_role;
  END IF;
END $$;
