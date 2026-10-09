/*
# Migration 6/6 — money math helpers and read views

Kept in its own file because it is the only part of the exchange schema that
needs PostgreSQL 15+ (`WITH (security_invoker = true)` on views, which is what
Supabase runs). If a database ever turns out to be older, the first five
migrations still apply and only this one has to be adapted — the tables and their
invariants do not depend on it.
*/

-- ---------------------------------------------------------------------------
-- pure integer money math (immutable, no table access)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notional_units(
  p_qty_units numeric,
  p_price_units numeric,
  p_notional_scale integer
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT trunc(p_qty_units * p_price_units / power(10::numeric, p_notional_scale))
$$;

CREATE OR REPLACE FUNCTION public.price_units_from_notional(
  p_quote_units numeric,
  p_qty_units numeric,
  p_notional_scale integer
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN p_qty_units IS NULL OR p_qty_units = 0 THEN NULL
           ELSE trunc(p_quote_units * power(10::numeric, p_notional_scale) / p_qty_units)
         END
$$;

COMMENT ON FUNCTION public.notional_units(numeric, numeric, integer) IS
  'Quote-asset base units for qty_units * price_units on a market with this notional_scale, truncated toward zero. Use this instead of re-deriving the formula — divide only here, never on the amounts themselves.';
COMMENT ON FUNCTION public.price_units_from_notional(numeric, numeric, integer) IS
  'Inverse of notional_units: average price_units from a filled quote amount and quantity (truncated). Used for orders.avg_price_units.';

GRANT EXECUTE ON FUNCTION public.notional_units(numeric, numeric, integer) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.price_units_from_notional(numeric, numeric, integer) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- v_my_balances — exactly what the frontend needs, scoped by RLS
--
-- security_invoker = true means the view runs with the caller's privileges, so
-- the RLS policies on accounts/balances apply: an authenticated caller sees only
-- their own rows, and the service role sees everything.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_my_balances
WITH (security_invoker = true)
AS
SELECT
  a.user_id,
  a.id AS account_id,
  a.environment,
  a.kind,
  ast.id AS asset_id,
  ast.symbol,
  ast.name AS asset_name,
  ast.base_decimals,
  COALESCE(b.available_units, 0) AS available_units,
  COALESCE(b.locked_units, 0) AS locked_units,
  COALESCE(b.available_units, 0) + COALESCE(b.locked_units, 0) AS total_units,
  b.version AS balance_version,
  b.updated_at AS balance_updated_at
FROM public.accounts a
JOIN public.assets ast ON ast.id = a.asset_id
LEFT JOIN public.balances b ON b.account_id = a.id
WHERE a.user_id IS NOT NULL;

COMMENT ON VIEW public.v_my_balances IS
  'Per-asset balances for the signed-in user (available/locked/total in integer base units). RLS applies through security_invoker; values are decimal strings, the client divides by 10^base_decimals for display.';

REVOKE ALL ON public.v_my_balances FROM PUBLIC;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON public.v_my_balances FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT SELECT ON public.v_my_balances TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT SELECT ON public.v_my_balances TO service_role;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- v_account_reconciliation — cached balance vs ledger, per account
--
-- Server-side only (service_role). drift_units must always be 0; anything else
-- is a bug that must be investigated before real money is enabled.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_account_reconciliation
WITH (security_invoker = true)
AS
SELECT
  a.id AS account_id,
  a.user_id,
  a.account_type,
  a.code,
  a.kind,
  a.environment,
  ast.symbol,
  COALESCE(b.available_units, 0) AS available_units,
  COALESCE(b.locked_units, 0) AS locked_units,
  COALESCE(b.available_units, 0) + COALESCE(b.locked_units, 0) AS cached_total_units,
  COALESCE(e.ledger_units, 0) AS ledger_total_units,
  (COALESCE(b.available_units, 0) + COALESCE(b.locked_units, 0)) - COALESCE(e.ledger_units, 0) AS drift_units
FROM public.accounts a
JOIN public.assets ast ON ast.id = a.asset_id
LEFT JOIN public.balances b ON b.account_id = a.id
LEFT JOIN (
  SELECT account_id, sum(amount_units) AS ledger_units
    FROM public.ledger_entries
   GROUP BY account_id
) e ON e.account_id = a.id;

COMMENT ON VIEW public.v_account_reconciliation IS
  'Per-account comparison of the cached balances row against SUM(ledger_entries). drift_units <> 0 means the projection is wrong.';

REVOKE ALL ON public.v_account_reconciliation FROM PUBLIC;
GRANT SELECT ON public.v_account_reconciliation TO service_role;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON public.v_account_reconciliation FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON public.v_account_reconciliation FROM authenticated;
  END IF;
END $$;
