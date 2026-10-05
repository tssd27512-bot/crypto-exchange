/*
# Migration 1/6 — exchange settings, assets, markets

Purpose
-------
Foundational reference data and the global paper/live switch for the GlobalTradeVX
exchange backend, plus the shared helper functions the money tables use.

New tables
----------
### app_settings  (exactly one row)
- `id` boolean PK default true, with CHECK (id) -> the table can physically only
  ever hold a single row.
- `mode` text NOT NULL default 'paper' CHECK in ('paper','live') — the durable
  server-side gate for real money.
- `paper_trading_enabled` / `live_trading_enabled` / `deposits_enabled` /
  `withdrawals_enabled` booleans, all defaulting to the conservative value
  (paper trading on, everything that touches real funds off).
- `live_enabled_at`, `updated_at`, `updated_by`, `note` for auditability.
- CHECK (mode <> 'live' OR (live_trading_enabled AND live_enabled_at IS NOT NULL))
  makes it impossible to flip the switch to live without also setting the live
  flag and recording when it happened.

### assets
One row per coin/token. `base_decimals` is the number of decimal places the
*ledger* works in, i.e. the amount column unit is 1e-base_decimals of the coin:
BTC 8 (satoshi), ETH 18 (wei), USDT 6, SOL 9 (lamport). All amounts anywhere in
this schema are integer multiples of that unit — never a float.
`chain`/`chain_id`/`contract_address` are placeholders for the deposits layer;
deposit/withdrawal limits and fees are nullable and left NULL on purpose (no
limit/fee policy has been ratified yet, and NULL means "not configured", which
the deposits layer must treat as "disabled").

### markets
Trading pairs. `environment` keeps paper and live books/rows apart.
Price/quantity are integers too:
- `qty_units` is always in base-asset base units (see `assets.base_decimals`).
- `price_units` is the price of ONE WHOLE base asset in quote-asset base units,
  scaled by 10^`price_scale` (default 8). Example, BTC/USDT (base_decimals 8,
  quote_decimals 6, price_scale 8): 60,000.00 USDT/BTC -> price_units =
  6,000,000,000,000.
- `notional_scale` is derived by trigger as
  `price_scale + base_decimals - quote_decimals` so that a quote amount is
  `trunc(qty_units * price_units / 10^notional_scale)` with no hand-maintained
  constant. Helper functions live in migration 6.
- `price_tick_units` / `qty_step_units` are the minimum increments; the order
  trigger in migration 4 enforces them.
- `maker_fee_bps` / `taker_fee_bps` are configuration, defaulting to 2/5 bps
  (0.02% / 0.05%) to match the fee copy already on the site.

Security
--------
RLS is enabled and policies are added in migration 5. Nothing here is writable
by `anon` or `authenticated`.

Notes
-----
`gen_random_uuid()` is core in PostgreSQL 13+; pgcrypto is still created because
the existing admin login migrations use `crypt()`/`gen_salt()`.
*/

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- shared helper: touch updated_at on UPDATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- app_settings — the one-row paper/live switch
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_settings (
  id boolean PRIMARY KEY DEFAULT true,
  mode text NOT NULL DEFAULT 'paper',
  paper_trading_enabled boolean NOT NULL DEFAULT true,
  live_trading_enabled boolean NOT NULL DEFAULT false,
  deposits_enabled boolean NOT NULL DEFAULT false,
  withdrawals_enabled boolean NOT NULL DEFAULT false,
  kyc_required_for_trading boolean NOT NULL DEFAULT false,
  live_enabled_at timestamptz,
  note text,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  CONSTRAINT app_settings_single_row CHECK (id),
  CONSTRAINT app_settings_mode_check CHECK (mode IN ('paper', 'live')),
  CONSTRAINT app_settings_live_gate_check CHECK (
    mode <> 'live' OR (live_trading_enabled AND live_enabled_at IS NOT NULL)
  )
);

-- exactly one row, paper mode, real money off
INSERT INTO public.app_settings (id)
VALUES (true)
ON CONFLICT (id) DO NOTHING;

DROP TRIGGER IF EXISTS app_settings_set_updated_at ON public.app_settings;
CREATE TRIGGER app_settings_set_updated_at
  BEFORE UPDATE ON public.app_settings
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.app_settings IS
  'Single-row global switch. mode=paper|live is the server-side gate for real money; flipping to live also requires live_trading_enabled and live_enabled_at.';

-- ---------------------------------------------------------------------------
-- helpers reading the switch
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.app_mode()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE((SELECT mode FROM public.app_settings WHERE id), 'paper')
$$;

CREATE OR REPLACE FUNCTION public.is_live_mode()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT public.app_mode() = 'live'
$$;

REVOKE ALL ON FUNCTION public.app_mode() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_live_mode() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.app_mode() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_live_mode() TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- the live-money gate used as a BEFORE INSERT trigger on every money table
--
-- Rows with environment='paper' always pass. Rows with environment='live' are
-- rejected unless the exchange is in live mode AND the relevant feature flag is
-- on. This is deliberately a database constraint, not an application check: a
-- frontend (or a leaked key) cannot create a live order/deposit/withdrawal while
-- the exchange is paper-only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_environment_gate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_settings public.app_settings;
  v_feature text;
  v_flag boolean;
BEGIN
  IF NEW.environment IS DISTINCT FROM 'live' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_settings FROM public.app_settings WHERE id;

  IF COALESCE(v_settings.mode, 'paper') <> 'live' THEN
    RAISE EXCEPTION
      'live row rejected on %.%: exchange mode is %, not live (app_settings.mode)',
      TG_TABLE_SCHEMA, TG_TABLE_NAME, COALESCE(v_settings.mode, 'paper')
      USING ERRCODE = 'check_violation';
  END IF;

  v_feature := CASE TG_TABLE_NAME
                 WHEN 'deposits' THEN 'deposits'
                 WHEN 'withdrawals' THEN 'withdrawals'
                 ELSE 'trading'
               END;

  IF v_feature = 'deposits' THEN
    v_flag := v_settings.deposits_enabled;
  ELSIF v_feature = 'withdrawals' THEN
    v_flag := v_settings.withdrawals_enabled;
  ELSE
    v_flag := v_settings.live_trading_enabled;
  END IF;

  IF NOT COALESCE(v_flag, false) THEN
    RAISE EXCEPTION
      'live row rejected on %.%: % is not enabled (app_settings.%)',
      TG_TABLE_SCHEMA, TG_TABLE_NAME, v_feature, v_feature || '_enabled'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$$;

-- NOTE: trigger functions keep the default EXECUTE grant to PUBLIC on purpose.
-- PostgreSQL checks EXECUTE on the trigger function with the *invoking* role's
-- privileges, so revoking it would break the very triggers that use it (and they
-- cannot be usefully called outside a trigger context anyway).

-- ---------------------------------------------------------------------------
-- assets
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.assets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol text NOT NULL,
  name text NOT NULL,
  kind text NOT NULL DEFAULT 'crypto',
  base_decimals smallint NOT NULL,
  display_decimals smallint,
  chain text,
  chain_id bigint,
  contract_address text,
  color text,
  is_active boolean NOT NULL DEFAULT false,
  deposit_enabled boolean NOT NULL DEFAULT false,
  withdrawal_enabled boolean NOT NULL DEFAULT false,
  min_deposit_units numeric(38, 0),
  min_withdrawal_units numeric(38, 0),
  withdrawal_fee_units numeric(38, 0),
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT assets_symbol_check CHECK (symbol ~ '^[A-Z0-9]{2,12}$'),
  CONSTRAINT assets_symbol_unique UNIQUE (symbol),
  CONSTRAINT assets_kind_check CHECK (kind IN ('crypto', 'stablecoin', 'fiat')),
  CONSTRAINT assets_base_decimals_check CHECK (base_decimals BETWEEN 0 AND 30),
  CONSTRAINT assets_display_decimals_check CHECK (
    display_decimals IS NULL OR (display_decimals BETWEEN 0 AND 30 AND display_decimals <= base_decimals)
  ),
  CONSTRAINT assets_amounts_check CHECK (
    (min_deposit_units IS NULL OR min_deposit_units >= 0)
    AND (min_withdrawal_units IS NULL OR min_withdrawal_units >= 0)
    AND (withdrawal_fee_units IS NULL OR withdrawal_fee_units >= 0)
  )
);

DROP TRIGGER IF EXISTS assets_set_updated_at ON public.assets;
CREATE TRIGGER assets_set_updated_at
  BEFORE UPDATE ON public.assets
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE UNIQUE INDEX IF NOT EXISTS assets_chain_contract_key
  ON public.assets (chain, contract_address)
  WHERE contract_address IS NOT NULL;

COMMENT ON TABLE public.assets IS
  'Tradable assets. base_decimals defines the integer ledger unit (BTC 8, ETH 18, USDT 6, SOL 9). All amounts in this schema are integer multiples of that unit.';
COMMENT ON COLUMN public.assets.base_decimals IS
  'Number of decimals of the integer ledger unit: amount_units * 10^-base_decimals = human amount.';

-- The four assets the product supports. Limits/fees deliberately left NULL
-- (not configured) and deposits/withdrawals disabled until the owner sets them.
INSERT INTO public.assets (symbol, name, kind, base_decimals, display_decimals, chain, color, is_active, sort_order)
VALUES
  ('BTC',  'Bitcoin',  'crypto',     8, 8, 'bitcoin',  '#F7931A', true, 10),
  ('ETH',  'Ethereum', 'crypto',    18, 8, 'ethereum', '#627EEA', true, 20),
  ('USDT', 'Tether USD', 'stablecoin', 6, 2, 'ethereum', '#26A17B', true, 30),
  ('SOL',  'Solana',   'crypto',     9, 4, 'solana',   '#9945FF', true, 40)
ON CONFLICT (symbol) DO NOTHING;

-- ---------------------------------------------------------------------------
-- markets
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.markets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  symbol text NOT NULL,
  base_asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  quote_asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  environment text NOT NULL DEFAULT 'paper',
  status text NOT NULL DEFAULT 'trading',
  price_scale smallint NOT NULL DEFAULT 8,
  notional_scale integer NOT NULL,
  price_tick_units numeric(38, 0) NOT NULL DEFAULT 1,
  qty_step_units numeric(38, 0) NOT NULL DEFAULT 1,
  min_qty_units numeric(38, 0),
  min_notional_units numeric(38, 0),
  maker_fee_bps integer NOT NULL DEFAULT 2,
  taker_fee_bps integer NOT NULL DEFAULT 5,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT markets_assets_differ CHECK (base_asset_id <> quote_asset_id),
  CONSTRAINT markets_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT markets_status_check CHECK (status IN ('trading', 'halted', 'post_only', 'disabled')),
  CONSTRAINT markets_price_scale_check CHECK (price_scale BETWEEN 0 AND 18),
  CONSTRAINT markets_notional_scale_check CHECK (notional_scale >= 0),
  CONSTRAINT markets_units_check CHECK (
    price_tick_units > 0
    AND qty_step_units > 0
    AND (min_qty_units IS NULL OR min_qty_units >= 0)
    AND (min_notional_units IS NULL OR min_notional_units >= 0)
  ),
  CONSTRAINT markets_fees_check CHECK (
    maker_fee_bps BETWEEN 0 AND 10000 AND taker_fee_bps BETWEEN 0 AND 10000
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS markets_symbol_environment_key
  ON public.markets (symbol, environment);
CREATE UNIQUE INDEX IF NOT EXISTS markets_assets_environment_key
  ON public.markets (base_asset_id, quote_asset_id, environment);
CREATE INDEX IF NOT EXISTS markets_active_idx
  ON public.markets (environment, status)
  WHERE is_active;

COMMENT ON TABLE public.markets IS
  'Trading pairs, separated by environment (paper|live). qty is in base-asset base units; price_units is the price of one whole base asset in quote base units scaled by 10^price_scale; quote amount = trunc(qty_units * price_units / 10^notional_scale).';
COMMENT ON COLUMN public.markets.notional_scale IS
  'Derived by trigger as price_scale + base_decimals - quote_decimals; the power of ten that converts qty_units * price_units into quote base units.';

-- keep notional_scale derived, never hand-written
CREATE OR REPLACE FUNCTION public.markets_set_notional_scale()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_base_decimals smallint;
  v_quote_decimals smallint;
  v_scale integer;
BEGIN
  SELECT base_decimals INTO v_base_decimals FROM public.assets WHERE id = NEW.base_asset_id;
  SELECT base_decimals INTO v_quote_decimals FROM public.assets WHERE id = NEW.quote_asset_id;

  IF v_base_decimals IS NULL OR v_quote_decimals IS NULL THEN
    RAISE EXCEPTION 'market %: base or quote asset does not exist', COALESCE(NEW.symbol, '<new>')
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  v_scale := NEW.price_scale + v_base_decimals - v_quote_decimals;

  IF v_scale < 0 THEN
    RAISE EXCEPTION
      'market %: notional_scale would be % (price_scale % + base_decimals % - quote_decimals %); the quote asset has too few decimals for this pair',
      NEW.symbol, v_scale, NEW.price_scale, v_base_decimals, v_quote_decimals
      USING ERRCODE = 'check_violation';
  END IF;

  NEW.notional_scale := v_scale;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS markets_set_notional_scale ON public.markets;
CREATE TRIGGER markets_set_notional_scale
  BEFORE INSERT OR UPDATE ON public.markets
  FOR EACH ROW EXECUTE FUNCTION public.markets_set_notional_scale();

-- paper markets for the three pairs the UI can render today (quote is USDT).
-- min_qty_units / min_notional_units stay NULL = no minimum configured yet.
INSERT INTO public.markets (
  symbol, base_asset_id, quote_asset_id, environment, status,
  price_scale, price_tick_units, qty_step_units, maker_fee_bps, taker_fee_bps, is_active
)
SELECT m.symbol, b.id, q.id, 'paper', 'trading', 8, 1, 1, 2, 5, true
FROM (
  VALUES ('BTC/USDT', 'BTC', 'USDT'), ('ETH/USDT', 'ETH', 'USDT'), ('SOL/USDT', 'SOL', 'USDT')
) AS m(symbol, base_symbol, quote_symbol)
JOIN public.assets b ON b.symbol = m.base_symbol
JOIN public.assets q ON q.symbol = m.quote_symbol
ON CONFLICT (symbol, environment) DO NOTHING;
