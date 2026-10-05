/*
# Migration 3/6 — immutable double-entry ledger

Purpose
-------
The ledger is the source of truth for money. `balances` is only a cache; the
ledger is what the books are audited against.

Shape
-----
- `ledger_transactions` — one row per business event (deposit credited, order
  hold placed, order hold released, fill, fee, withdrawal request/settle,
  referral reward, admin adjustment, correction). Carries the event `type`, the
  `environment` (paper|live), an optional `idempotency_key`, a polymorphic
  `reference_type`/`reference_id` back to the business row (order, fill,
  deposit, withdrawal), and `reverses_transaction_id` for corrections.
- `ledger_entries` — the postings. One row per account movement, signed:
    * positive `amount_units` = credit the account
    * negative `amount_units` = debit the account
  Every transaction must post at least two entries on different accounts and
  **sum to zero per asset**. A user's "available -> locked" hold is therefore two
  entries (debit the available account, credit the locked account), and an
  external deposit credits a user available account while debiting a system
  (`EXTERNAL_DEPOSIT`) account — so `SUM(all entries)` per asset stays zero and
  user liabilities can always be reconciled against system accounts.

Amounts
-------
`numeric(38,0)` integer base units. Negative values are produced by ordinary
integer arithmetic; no float/double is involved anywhere. `amount_units <> 0` is
enforced (a zero posting is a bug, not an entry).

Immutability (the rule that makes the audit trail worth anything)
----------------------------------------------------------------
1. `REVOKE UPDATE, DELETE, TRUNCATE` on both tables from PUBLIC, anon,
   authenticated and service_role.
2. `BEFORE UPDATE OR DELETE` triggers on both tables raise an exception, so even
   a role that could re-grant itself privileges (or the table owner) cannot edit
   history by accident. The only bypasses are dropping the trigger or
   `session_replication_role = replica`, both of which require ownership /
   superuser and are themselves auditable.
3. Corrections are new compensating transactions that point at the original via
   `reverses_transaction_id` (e.g. type `correction` / `withdrawal_refund`) and
   identical amounts with the opposite sign. Never an edit.
4. A deferred constraint trigger (`ledger_entries_balanced`) re-checks at COMMIT
   that each touched transaction is zero-sum per asset, has entries on at least
   two distinct accounts, and that every entry's environment matches its
   transaction's environment.
5. A second deferred constraint trigger (`balances_match_ledger`) aborts a commit
   that moves a cached balance without the corresponding ledger postings.

Atomicity
---------
Everything above is checkable inside one transaction, which is what lets a future
in-DB matching engine place an order, match fills, move holds and write the
ledger rows in a single `BEGIN ... COMMIT` — a failure rolls the whole match back.
*/

-- ---------------------------------------------------------------------------
-- ledger_transactions
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ledger_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type text NOT NULL,
  environment text NOT NULL DEFAULT 'paper',
  idempotency_key text,
  reference_type text,
  reference_id uuid,
  reverses_transaction_id uuid REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  actor_user_id uuid,
  description text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ledger_transactions_type_check CHECK (type IN (
    'deposit_credit',
    'deposit_reversal',
    'withdrawal_request',
    'withdrawal_settle',
    'withdrawal_refund',
    'order_hold',
    'order_release',
    'trade_fill',
    'maker_fee',
    'taker_fee',
    'fee',
    'referral_reward',
    'paper_funding',
    'admin_adjustment',
    'correction'
  )),
  CONSTRAINT ledger_transactions_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT ledger_transactions_key_check CHECK (
    idempotency_key IS NULL OR length(idempotency_key) BETWEEN 1 AND 200
  )
);

-- one business event == one transaction, even if a client retries
CREATE UNIQUE INDEX IF NOT EXISTS ledger_transactions_idempotency_key
  ON public.ledger_transactions (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS ledger_transactions_reference_idx
  ON public.ledger_transactions (reference_type, reference_id);

CREATE INDEX IF NOT EXISTS ledger_transactions_created_idx
  ON public.ledger_transactions (environment, created_at DESC);

DROP TRIGGER IF EXISTS ledger_transactions_environment_gate ON public.ledger_transactions;
CREATE TRIGGER ledger_transactions_environment_gate
  BEFORE INSERT ON public.ledger_transactions
  FOR EACH ROW EXECUTE FUNCTION public.enforce_environment_gate();

COMMENT ON TABLE public.ledger_transactions IS
  'Append-only journal header: one row per business/money event. Corrections are new transactions referencing the original via reverses_transaction_id.';

-- ---------------------------------------------------------------------------
-- ledger_entries
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ledger_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  account_id uuid NOT NULL,
  asset_id uuid NOT NULL,
  environment text NOT NULL,
  amount_units numeric(38, 0) NOT NULL,
  balance_after_units numeric(38, 0),
  memo text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ledger_entries_amount_non_zero CHECK (amount_units <> 0),
  CONSTRAINT ledger_entries_environment_check CHECK (environment IN ('paper', 'live')),
  -- an entry's asset and environment can never disagree with its account
  CONSTRAINT ledger_entries_account_fkey
    FOREIGN KEY (account_id, asset_id, environment)
    REFERENCES public.accounts (id, asset_id, environment)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ledger_entries_transaction_idx ON public.ledger_entries (transaction_id);
CREATE INDEX IF NOT EXISTS ledger_entries_account_idx ON public.ledger_entries (account_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ledger_entries_asset_idx ON public.ledger_entries (asset_id, created_at DESC);

COMMENT ON TABLE public.ledger_entries IS
  'Append-only double-entry postings. Positive amount_units credits the account, negative debits it. Entries of one transaction must sum to zero per asset (deferred constraint trigger). UPDATE and DELETE are impossible by privilege and by trigger.';
COMMENT ON COLUMN public.ledger_entries.amount_units IS
  'Signed integer base units (see assets.base_decimals). balance_after_units is an optional audit snapshot of the account total after this posting.';

-- ---------------------------------------------------------------------------
-- immutability: privilege revocation + trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION
    '% is append-only: % on %.% is not permitted. Insert a compensating transaction instead of editing history.',
    TG_TABLE_NAME, TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END;
$$;

-- Trigger functions keep the default EXECUTE grant: PostgreSQL checks EXECUTE
-- with the invoking role's privileges, so revoking it would break the triggers
-- themselves, and a trigger function cannot be called outside a trigger anyway.

DROP TRIGGER IF EXISTS ledger_entries_immutable ON public.ledger_entries;
CREATE TRIGGER ledger_entries_immutable
  BEFORE UPDATE OR DELETE ON public.ledger_entries
  FOR EACH ROW EXECUTE FUNCTION public.reject_mutation();

DROP TRIGGER IF EXISTS ledger_transactions_immutable ON public.ledger_transactions;
CREATE TRIGGER ledger_transactions_immutable
  BEFORE UPDATE OR DELETE ON public.ledger_transactions
  FOR EACH ROW EXECUTE FUNCTION public.reject_mutation();

-- Privileges: nobody gets UPDATE/DELETE on the ledger, not even service_role.
-- (Roles are guarded with a catalogue check so this file also applies to a bare
-- PostgreSQL instance without Supabase's anon/authenticated/service_role roles.)
DO $$
DECLARE
  r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON public.ledger_entries FROM %I', r);
      EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON public.ledger_transactions FROM %I', r);
    END IF;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- deferred invariant: every transaction balances per asset, across >= 2 accounts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_ledger_transaction_balanced()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_bad record;
BEGIN
  SELECT e.asset_id,
         sum(e.amount_units) AS net_units,
         count(DISTINCT e.account_id) AS account_count
    INTO v_bad
    FROM public.ledger_entries e
   WHERE e.transaction_id = NEW.transaction_id
   GROUP BY e.asset_id
  HAVING sum(e.amount_units) <> 0 OR count(DISTINCT e.account_id) < 2
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION
      'ledger transaction % is not a valid double-entry posting for asset %: net % base units across % distinct account(s) (needs net 0 across >= 2 accounts)',
      NEW.transaction_id, v_bad.asset_id, v_bad.net_units, v_bad.account_count
      USING ERRCODE = 'check_violation';
  END IF;

  SELECT e.id INTO v_bad
    FROM public.ledger_entries e
    JOIN public.ledger_transactions t ON t.id = e.transaction_id
   WHERE e.transaction_id = NEW.transaction_id
     AND e.environment <> t.environment
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION
      'ledger entry % on transaction % has a different environment than the transaction itself',
      v_bad.id, NEW.transaction_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- The reverse direction of balances_match_ledger: posting to an account
  -- without moving its cached balance is just as wrong as moving the cache
  -- without posting. (Deferred, so the cache update may happen after the
  -- entries inside the same transaction.)
  SELECT b.account_id,
         COALESCE(b.available_units, 0) + COALESCE(b.locked_units, 0) AS cached_units,
         COALESCE(e.ledger_units, 0) AS ledger_units
    INTO v_bad
    FROM (
      SELECT DISTINCT account_id
        FROM public.ledger_entries
       WHERE transaction_id = NEW.transaction_id
    ) touched
    LEFT JOIN public.balances b ON b.account_id = touched.account_id
    LEFT JOIN (
      SELECT account_id, sum(amount_units) AS ledger_units
        FROM public.ledger_entries
       GROUP BY account_id
    ) e ON e.account_id = touched.account_id
   WHERE b.account_id IS NULL
      OR (COALESCE(b.available_units, 0) + COALESCE(b.locked_units, 0)) <> COALESCE(e.ledger_units, 0)
   LIMIT 1;

  IF FOUND THEN
    RAISE EXCEPTION
      'ledger transaction % posts to account % but the cached balance is % while the ledger sums to % — write the balances row in the same transaction',
      NEW.transaction_id, v_bad.account_id, v_bad.cached_units, v_bad.ledger_units
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NULL;
END;
$$;

-- (reject_mutation, assert_ledger_transaction_balanced, assert_balance_matches_ledger
-- are trigger functions — they are not callable outside a trigger and therefore
-- keep the default EXECUTE grant; see the note above.)

DROP TRIGGER IF EXISTS ledger_entries_balanced ON public.ledger_entries;
CREATE CONSTRAINT TRIGGER ledger_entries_balanced
  AFTER INSERT ON public.ledger_entries
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.assert_ledger_transaction_balanced();

-- ---------------------------------------------------------------------------
-- deferred invariant: a cached balance may only move together with the ledger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_balance_matches_ledger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_ledger_units numeric(38, 0);
  v_cached_units numeric(38, 0);
BEGIN
  SELECT COALESCE(sum(amount_units), 0)
    INTO v_ledger_units
    FROM public.ledger_entries
   WHERE account_id = NEW.account_id;

  v_cached_units := NEW.available_units + NEW.locked_units;

  IF v_cached_units <> v_ledger_units THEN
    RAISE EXCEPTION
      'balance drift on account %: cached % base units but ledger sums to % — every balance change must be written together with its ledger entries',
      NEW.account_id, v_cached_units, v_ledger_units
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS balances_match_ledger ON public.balances;
CREATE CONSTRAINT TRIGGER balances_match_ledger
  AFTER INSERT OR UPDATE ON public.balances
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION public.assert_balance_matches_ledger();
