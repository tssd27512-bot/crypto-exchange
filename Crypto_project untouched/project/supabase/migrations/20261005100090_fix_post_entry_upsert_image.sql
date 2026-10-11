/*
# Migration: post_entry must not feed the balance guard a raw insert image
Purpose
-------
`post_entry()` moved the cached balance with a single upsert
(`INSERT ... ON CONFLICT (account_id) DO UPDATE SET available_units = public.balances.available_units + delta`).
That looks atomic but it is wrong for **negative** deltas, because of trigger
timing in PostgreSQL:

  For `INSERT ... ON CONFLICT DO UPDATE`, the `BEFORE INSERT` ROW trigger fires
  **before** the conflict is resolved, and it fires with the *proposed insert
  image*. Only then does the UPDATE branch run and its own `BEFORE UPDATE`
  image get validated.

`public.balances_before_write` is `BEFORE INSERT OR UPDATE` and validates
`NEW.available_units >= 0`, so for a negative delta it validated the raw
insert image `-delta` instead of the real resulting balance
(`existing - delta`). Any correctly-funded account therefore aborted with

    user account <uuid> cannot go negative (available -100000, locked 0)

even though `SELECT available_units ... FOR UPDATE` in the same transaction
showed enough funds, while a *positive* delta (funding) sailed through because
its raw image is non-negative. Reproduced in plain SQL, no engine code:

    insert into public.balances (account_id, available_units, locked_units, last_entry_at)
    values (<account>, -100000, 0, now())
    on conflict (account_id) do update
      set available_units = public.balances.available_units + (-100000);
    -- ERROR: user account ... cannot go negative (available -100000, locked 0)

and a minimal probe proves the timing (`before insert or update` trigger on
`(id primary key, v int)`; `insert ... on conflict (id) do update set v = probe.v + (-3)`):

    NOTICE:  PROBE TG_OP=INSERT NEW.v=-3     <- proposed image, guard fires here
    NOTICE:  PROBE TG_OP=UPDATE NEW.v=2      <- real resulting state

Fix
---
`post_entry()` now does the two steps explicitly:

  1. `INSERT ... VALUES (account_id, 0, 0, now()) ON CONFLICT DO NOTHING`
     — the row exists for every account already (see `accounts_create_balance`
     in migration `20261005100010`), so this is normally a no-op; when a row is
     missing it is created with zeros, whose insert image is always valid.
  2. `UPDATE ... SET available_units = available_units + delta, ...`
     — the guard then validates the true post-update values, as intended.

The relative-increment property is unchanged: still `+ delta` (never an
absolute write), so concurrent writers still serialise on the balance row lock
and cannot lose an update. The invariant itself is untouched — a user account
still cannot end up negative (`available_units + locked_units` and each column
individually), and system accounts may still go negative on
`available_units`. Overdrawing now fails *after* the increment, i.e. against
the real row, which is what the guard is for.
*/
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
  v_available_delta numeric;
  v_locked_delta    numeric;
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
  -- The account's `kind` decides whether the amount lands in available_units or
  -- locked_units.
  IF v_account.kind = 'locked' THEN
    v_available_delta := 0;
    v_locked_delta    := p_amount_units;
  ELSE
    v_available_delta := p_amount_units;
    v_locked_delta    := 0;
  END IF;
  -- Make sure the row exists *before* the guarded relative increment, and only
  -- ever insert a zero image: a BEFORE INSERT trigger cannot know that
  -- ON CONFLICT will divert this row into the UPDATE branch, so the image it
  -- validates must be the one that will actually be written. Zeros are always
  -- valid; the real values are validated by the UPDATE below.
  INSERT INTO public.balances (account_id, available_units, locked_units, last_entry_at)
  VALUES (p_account_id, 0, 0, now())
  ON CONFLICT (account_id) DO NOTHING;
  -- Relative increments (never absolute writes) so two concurrent fills on the
  -- same account serialise on the row lock instead of losing an update.
  UPDATE public.balances
     SET available_units = public.balances.available_units + v_available_delta,
         locked_units    = public.balances.locked_units + v_locked_delta,
         last_entry_at   = now()
   WHERE account_id = p_account_id;
END $$;
COMMENT ON FUNCTION public.post_entry(uuid, uuid, numeric, text) IS
  'Appends one signed ledger entry and moves the corresponding cached balance in the same transaction, choosing available_units or locked_units from the account kind. The balance row is created with a zero image and then incremented, so the no-negative-balance guard validates the true resulting values rather than an insert image. Internal to the engine.';
