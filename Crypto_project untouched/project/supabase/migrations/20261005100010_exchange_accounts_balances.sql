/*
# Migration 2/6 — accounts and balances

Purpose
-------
`accounts` is the wallet container (who/what owns value); `balances` is the
mutable cached projection of the append-only ledger for that account.

Model
-----
- One row per (owner, asset, kind, environment, ...). `kind` is:
    * `available` — spendable
    * `locked`    — held against open orders / pending withdrawals
- User accounts hang off `auth.users` (public.accounts.user_id). Supabase Auth is
  the only credential store; this table never holds passwords.
- System accounts (`account_type = 'system'`) have no user and a unique `code`
  (e.g. `FEE_INCOME`, `PAPER_FAUCET`, and later `EXTERNAL_DEPOSIT` /
  `EXTERNAL_WITHDRAWAL` for chains). They are what makes the double-entry ledger
  balance to zero: a user credit is always matched by a system debit.
- `environment` (paper|live) is part of every key. Paper and live balances can
  never share a row.
- `kyc_status` is deliberately NOT on this table: KYC belongs to the identity
  layer (`profiles`/KYC tables, later work). `accounts` stays money-only so a KYC
  state change can never touch a balance row. A `kyc_status` placeholder is
  expected on the profile table instead.

Amount columns
--------------
`numeric(38,0)` integer base units (BTC satoshi, ETH wei, USDT 1e-6, SOL
lamport). `assets.base_decimals` decides how to display them. No float/double
anywhere in this schema.

Integrity / concurrency guard
-----------------------------
- `balances.available_units` and `locked_units` have CHECK (>= 0), so a
  withdrawal or fill can never take a balance negative even if application code
  is wrong.
- `balances.version` is bumped by trigger on every UPDATE and is the optimistic
  lock for writers (`UPDATE ... WHERE account_id = $1 AND version = $2`);
  pessimistic writers use `SELECT ... FOR UPDATE` on the same row. Either way the
  row is the serialisation point for one account.
- `balances.account_id` is immutable (trigger).
- Every change to a balance must be part of the same transaction as the
  matching ledger entries: the deferred constraint trigger added in migration 3
  (`balances_match_ledger`) aborts the commit if
  `available_units + locked_units <> SUM(ledger_entries.amount_units)` for that
  account.
- A `balances` row is created automatically for every new account.

Security
--------
RLS is enabled and policies are added in migration 5 (owner-only SELECT, no
client write path at all).
*/

CREATE TABLE IF NOT EXISTS public.accounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  account_type text NOT NULL DEFAULT 'user',
  code text,
  asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  kind text NOT NULL DEFAULT 'available',
  environment text NOT NULL DEFAULT 'paper',
  label text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT accounts_type_check CHECK (account_type IN ('user', 'system')),
  CONSTRAINT accounts_kind_check CHECK (kind IN ('available', 'locked')),
  CONSTRAINT accounts_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT accounts_owner_check CHECK (
    (account_type = 'user' AND user_id IS NOT NULL AND code IS NULL)
    OR (account_type = 'system' AND user_id IS NULL AND code IS NOT NULL)
  ),
  CONSTRAINT accounts_code_check CHECK (code IS NULL OR code ~ '^[A-Z0-9_]{2,32}$')
);

-- one available + one locked account per user/asset/environment
CREATE UNIQUE INDEX IF NOT EXISTS accounts_user_key
  ON public.accounts (user_id, asset_id, kind, environment)
  WHERE user_id IS NOT NULL;

-- one system account per code/asset/kind/environment
CREATE UNIQUE INDEX IF NOT EXISTS accounts_system_key
  ON public.accounts (code, asset_id, kind, environment)
  WHERE code IS NOT NULL;

-- target for the composite FK from ledger_entries (keeps an entry's asset and
-- environment in lock-step with its account — a mixed-currency posting becomes
-- impossible at the constraint level, not just in code)
CREATE UNIQUE INDEX IF NOT EXISTS accounts_id_asset_environment_key
  ON public.accounts (id, asset_id, environment);

CREATE INDEX IF NOT EXISTS accounts_user_idx ON public.accounts (user_id);

DROP TRIGGER IF EXISTS accounts_set_updated_at ON public.accounts;
CREATE TRIGGER accounts_set_updated_at
  BEFORE UPDATE ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS accounts_environment_gate ON public.accounts;
CREATE TRIGGER accounts_environment_gate
  BEFORE INSERT ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.enforce_environment_gate();

COMMENT ON TABLE public.accounts IS
  'Wallet container: user accounts keyed by auth.users id, or system accounts (code) used as the counterparty side of double-entry postings. One row per asset/kind/environment.';
COMMENT ON COLUMN public.accounts.kind IS
  'available = spendable, locked = held against open orders / pending withdrawals.';

-- ---------------------------------------------------------------------------
-- balances — cached projection of the ledger, written only next to ledger rows
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.balances (
  account_id uuid PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  available_units numeric(38, 0) NOT NULL DEFAULT 0,
  locked_units numeric(38, 0) NOT NULL DEFAULT 0,
  version bigint NOT NULL DEFAULT 0,
  last_entry_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT balances_available_non_negative CHECK (available_units >= 0),
  CONSTRAINT balances_locked_non_negative CHECK (locked_units >= 0)
);

COMMENT ON TABLE public.balances IS
  'Cached projection of ledger_entries, one row per account. A change is only valid in the same transaction as the matching ledger entries (enforced by the deferrable trigger balances_match_ledger). version is the optimistic concurrency guard.';

-- optimistic-lock / immutability guard
CREATE OR REPLACE FUNCTION public.balances_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.account_id <> OLD.account_id THEN
    RAISE EXCEPTION 'balances.account_id is immutable (% -> %)', OLD.account_id, NEW.account_id
      USING ERRCODE = 'check_violation';
  END IF;
  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS balances_before_update ON public.balances;
CREATE TRIGGER balances_before_update
  BEFORE UPDATE ON public.balances
  FOR EACH ROW EXECUTE FUNCTION public.balances_before_update();

-- every new account gets its balance row immediately, so writers never upsert
CREATE OR REPLACE FUNCTION public.accounts_create_balance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.balances (account_id) VALUES (NEW.id)
  ON CONFLICT (account_id) DO NOTHING;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS accounts_create_balance ON public.accounts;
CREATE TRIGGER accounts_create_balance
  AFTER INSERT ON public.accounts
  FOR EACH ROW EXECUTE FUNCTION public.accounts_create_balance();

-- ---------------------------------------------------------------------------
-- paper-mode system accounts (the counterparty side of paper postings).
-- Inventing these two codes here only names the paper faucet and the fee sink;
-- live-mode system accounts come with the deposits/withdrawals layer.
-- ---------------------------------------------------------------------------
INSERT INTO public.accounts (account_type, code, asset_id, kind, environment, label)
SELECT 'system', code, a.id, 'available', 'paper', label
FROM public.assets a
CROSS JOIN (
  VALUES ('PAPER_FAUCET', 'Paper-mode faucet (admin_adjustment / paper_funding)'),
         ('FEE_INCOME',   'Trading fee income')
) AS s(code, label)
WHERE a.is_active
ON CONFLICT DO NOTHING;
