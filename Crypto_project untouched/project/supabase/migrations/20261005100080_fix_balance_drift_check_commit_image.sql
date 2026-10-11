-- Fix: the deferred balance-vs-ledger check compared the tuple image that was
-- queued when the row was first touched in the transaction.
--
-- `balances_match_ledger` is a DEFERRABLE INITIALLY DEFERRED constraint trigger
-- on `public.balances`, so it fires at COMMIT and reads the ledger entries that
-- exist *then*. `NEW` however is the row image captured when the event was
-- queued. Whenever an account's cached row is created and funded in the same
-- transaction -- i.e. every first funding of a user account, the faucet path and
-- the deposit path: `ensure_user_account()` / `system_account_id()` insert
-- `balances` with 0, then `post_entry()` moves it -- the queued INSERT image
-- (cached 0) is compared against the ledger sum that already includes the new
-- entry, and the commit is rejected with a bogus
--   balance drift on account ...: cached 0 base units but ledger sums to ...
--
-- The ledger is the source of truth and every change is committed with its
-- entries, so at COMMIT the *live* row is the thing to assert. Re-reading
-- `public.balances` makes the check independent of which tuple image was queued
-- and keeps the invariant it is meant to enforce: at commit time the cached
-- balance must equal SUM(ledger_entries) for that account, so an UPDATE that
-- moves the cache without entries (and entries without a cache move) still
-- fails exactly as before.
CREATE OR REPLACE FUNCTION public.assert_balance_matches_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_ledger_units numeric(38, 0);
  v_cached_units numeric(38, 0);
BEGIN
  SELECT COALESCE(sum(amount_units), 0)
    INTO v_ledger_units
    FROM public.ledger_entries
   WHERE account_id = NEW.account_id;
  -- live row, not the queued tuple: the trigger runs at COMMIT
  SELECT available_units + locked_units
    INTO v_cached_units
    FROM public.balances
   WHERE account_id = NEW.account_id;
  v_cached_units := COALESCE(v_cached_units, 0);
  IF v_cached_units <> v_ledger_units THEN
    RAISE EXCEPTION
      'balance drift on account %: cached % base units but ledger sums to % — every balance change must be written together with its ledger entries',
      NEW.account_id, v_cached_units, v_ledger_units
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END;
$fn$;
COMMENT ON FUNCTION public.assert_balance_matches_ledger() IS
  'Deferred invariant: at COMMIT the cached balances row for the touched account must equal SUM(ledger_entries). Re-reads the live row so a cache row created and funded in the same transaction is judged by its final value.';
