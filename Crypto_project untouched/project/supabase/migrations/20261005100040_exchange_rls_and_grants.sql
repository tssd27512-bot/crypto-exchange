/*
# Migration 5/6 — RLS and grants for the exchange tables

Model (deliberately different from the world-readable chat tables)
------------------------------------------------------------------
1. **Default deny.** RLS is enabled on every exchange table and there is no
   policy for `anon` at all: an anonymous visitor (the public anon key) can read
   nothing and write nothing here. Market/asset data for the public landing page
   is a later read model served by an edge function with the service role, never
   by exposing these tables.
2. **`service_role` bypasses RLS.** It is the server-side boundary (edge
   functions / migrations / the matching job). It gets SELECT + INSERT, and
   UPDATE/DELETE only where mutating a row is legitimate (`orders`, and
   `balances` through the same transaction as the ledger). The append-only tables
   (ledger, trades, order_events) get **no** UPDATE/DELETE (migration 3 and 4
   revoke them; this migration does not re-grant them).
3. **`authenticated` reads only its own rows.** A signed-in user may:
     * read reference data (`assets`, `markets`, `app_settings` — the last one so
       the UI can drive its "demo mode" labels from the real flag),
     * read their own `accounts`, `balances`, `ledger_entries`,
       `ledger_transactions`, `orders`, `order_events` and `trades`,
   and nothing else.
4. **No client write path.** `INSERT`/`UPDATE`/`DELETE` are revoked from `anon`
   and `authenticated` on every exchange table. Placing/cancelling an order,
   holding or releasing funds, crediting a deposit and settling a withdrawal all
   go through server-side functions: a `SECURITY DEFINER` function (owned by the
   migration role, so RLS does not apply) called over PostgREST RPC, or the
   service role from an edge function. `auth.uid()`-derived identity, price and
   balance checks therefore live server-side only.
5. Ownership is always `auth.users.id`, never a client-supplied field.

Supabase grants ALL on new tables in `public` to anon/authenticated/service_role
by default, so this migration explicitly revokes first and then grants back the
minimum.
*/

-- ---------------------------------------------------------------------------
-- enable RLS everywhere
-- ---------------------------------------------------------------------------
ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.assets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.markets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trades ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- privileges
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  t text;
  r text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'app_settings', 'assets', 'markets', 'accounts', 'balances',
    'ledger_transactions', 'ledger_entries', 'orders', 'order_events', 'trades'
  ] LOOP
    -- nothing at all for anonymous visitors
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
    END IF;

    -- signed-in users: read-only, and only what an RLS policy allows
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM authenticated', t);
      EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    END IF;

    -- server side
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT SELECT, INSERT ON public.%I TO service_role', t);
    END IF;
  END LOOP;

  -- legitimate mutations for the service role
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT UPDATE, DELETE ON public.orders TO service_role;
    GRANT UPDATE ON public.balances TO service_role;
    GRANT INSERT, UPDATE ON public.accounts TO service_role;
    GRANT INSERT, UPDATE ON public.assets TO service_role;
    GRANT INSERT, UPDATE, DELETE ON public.markets TO service_role;
    GRANT UPDATE ON public.app_settings TO service_role;
  END IF;
END $$;

-- NOTE: EXECUTE is deliberately NOT revoked on the trigger functions
-- (set_updated_at, accounts_create_balance, balances_before_update,
-- markets_set_notional_scale, orders_before_insert, enforce_environment_gate,
-- reject_mutation, assert_*). PostgreSQL checks EXECUTE on a trigger function
-- against the invoking role, so revoking it would break the triggers — and none
-- of them can be called outside a trigger context anyway.
-- The helpers that ARE ordinary callable functions (app_mode, is_live_mode,
-- notional_units, price_units_from_notional) are revoked from PUBLIC and then
-- granted to the roles that need them, in migrations 1 and 6.

-- ---------------------------------------------------------------------------
-- policies: reference data is readable by any signed-in user
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS app_settings_select_authenticated ON public.app_settings;
CREATE POLICY app_settings_select_authenticated ON public.app_settings
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS assets_select_authenticated ON public.assets;
CREATE POLICY assets_select_authenticated ON public.assets
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS markets_select_authenticated ON public.markets;
CREATE POLICY markets_select_authenticated ON public.markets
  FOR SELECT TO authenticated
  USING (true);

-- ---------------------------------------------------------------------------
-- policies: money and orders, own rows only
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS accounts_select_own ON public.accounts;
CREATE POLICY accounts_select_own ON public.accounts
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS balances_select_own ON public.balances;
CREATE POLICY balances_select_own ON public.balances
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.accounts a
     WHERE a.id = balances.account_id
       AND a.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS ledger_entries_select_own ON public.ledger_entries;
CREATE POLICY ledger_entries_select_own ON public.ledger_entries
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.accounts a
     WHERE a.id = ledger_entries.account_id
       AND a.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS ledger_transactions_select_own ON public.ledger_transactions;
CREATE POLICY ledger_transactions_select_own ON public.ledger_transactions
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1
      FROM public.ledger_entries e
      JOIN public.accounts a ON a.id = e.account_id
     WHERE e.transaction_id = ledger_transactions.id
       AND a.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS orders_select_own ON public.orders;
CREATE POLICY orders_select_own ON public.orders
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS order_events_select_own ON public.order_events;
CREATE POLICY order_events_select_own ON public.order_events
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM public.orders o
     WHERE o.id = order_events.order_id
       AND o.user_id = auth.uid()
  ));

DROP POLICY IF EXISTS trades_select_own ON public.trades;
CREATE POLICY trades_select_own ON public.trades
  FOR SELECT TO authenticated
  USING (taker_user_id = auth.uid() OR maker_user_id = auth.uid());

-- No INSERT/UPDATE/DELETE policy exists for anon or authenticated by design:
-- client writes are denied by RLS regardless of any future privilege grant.
