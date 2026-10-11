/*
# Migration: engine functions must not be callable by anon / PUBLIC
Defect (found in verification, reproduced on scratch PostgreSQL with the repo's
own `tests/00_supabase_stub.sql`, which mirrors Supabase's default privileges):
`alter default privileges in schema public grant all on functions to anon,
authenticated, service_role;` means every function created afterwards carries an
*explicit* `anon=X` grant. `REVOKE ALL ... FROM PUBLIC` therefore did NOT remove
the anon grant on the entry points, and the internals were never revoked from
PUBLIC at all. Measured ACLs after migration 20261005100060:

    place_order | {postgres=X,anon=X,authenticated=X,service_role=X}
    cancel_order| {postgres=X,anon=X,authenticated=X,service_role=X}
    post_entry  | {=X,postgres=X,service_role=X}      <- PUBLIC still has EXECUTE

As a result an *unauthenticated* caller could trade for any user:

    begin;
      set local role anon;
      select public.place_order('BTC/USDT','buy','limit',10000,6000000000000,
                                null,null,'00000000-0000-0000-0000-000000000002');
    -- succeeded: {"status":"new", ...,"hold_units":6003000}
    rollback;

(the order was placed and a real 6,003,000-unit hold was moved). `post_entry`
was executable by PUBLIC, i.e. by anon too.
Fix
---
`anon` and `PUBLIC` lose EXECUTE on every exchange function; the entry points
stay callable by `authenticated` and `service_role`, the internals by
`service_role` only. Discovery via `pg_proc` is used so no signature can drift.
No behaviour of the engine changes for legitimate callers.
*/
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
         'place_order', 'cancel_order', 'post_entry', 'match_order', 'settle_fill',
         'close_order', 'book_fillable', 'order_result', 'ensure_user_account',
         'system_account_id', 'assert_trading_enabled', 'resolve_order_actor',
         'account_allows_negative', 'app_mode', 'is_live_mode',
         'notional_units', 'price_units_from_notional')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f.sig);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f.sig);
    END IF;
  END LOOP;
  -- entry points: a signed-in user may trade (auth.uid() decides the actor)
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname IN ('place_order', 'cancel_order')
  LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
    END IF;
  END LOOP;
  -- read helpers: authenticated too
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('app_mode', 'is_live_mode', 'notional_units',
                         'price_units_from_notional')
  LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated', f.sig);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
    END IF;
  END LOOP;
  -- internals: service_role only
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN ('post_entry', 'match_order', 'settle_fill', 'close_order',
                         'book_fillable', 'order_result', 'ensure_user_account',
                         'system_account_id', 'assert_trading_enabled',
                         'resolve_order_actor')
  LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
    END IF;
  END LOOP;
END $$;
