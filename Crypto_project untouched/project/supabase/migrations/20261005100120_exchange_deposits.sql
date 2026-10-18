/*
# Migration 9/9 — deposit addresses and deposit crediting

Purpose
-------
The database layer of the deposit path for BTC / ETH / USDT / SOL — the model,
the state machine and the RPCs an operator or (later) a chain watcher calls.
**No chain integration, no address generation, no external provider, no seeded
data of any kind.** Nothing here invents a chain address or a deposit.

Shape
-----
- `deposit_networks` — which (asset, network) pairs the exchange accepts, with
  the confirmation policy and the minimum deposit. Operator configuration, not
  seeded (a network that is not registered cannot receive a deposit).
  `environment` keeps paper and live configuration apart.
- `deposit_addresses` — where a user is told to send funds: per-user (the RPC
  refuses a NULL user, so the spec's "shared address" case is not created by any
  path yet), per asset, per network, address-tag aware (memo/tag). Provisioning
  is pluggable by design: `register_deposit_address()` takes the address string
  from the caller, so an operator types it now and a custody provider supplies
  it later. **No address is generated or seeded here** — a fake address would be
  worse than none.
- `deposits` — one row per observed inbound chain transaction, with the state
  machine, the confirmation count, the provider txid and the ledger reference of
  the credit.

State machine
-------------
    detected --(confirmations)--> confirming --> credited      (terminal)
        \_____________________________/  \__> failed | cancelled | orphaned | reorged (terminal)

  * `detected`       seen, 0 confirmations (or below the policy)
  * `confirming`     some confirmations, still below the policy
  * `credited`       posted to the ledger; `credited_ledger_transaction_id` is
                     set and can never change; no further transition
  * `failed`         the operator/watcher rejected it (wrong asset, dust, …)
  * `cancelled`      withdrawn before it was credited (operator decision)
  * `orphaned`       never reached the policy (dropped from the mempool)
  * `reorged`        reorged out of the canonical chain before crediting
  Every other transition raises (`deposits_before_update`), and the identity of
  the chain transaction (user, asset, network, environment, txid, log_index,
  amount, required confirmations) is immutable by trigger.
  (The requirements doc §5.2 names detected|confirming|credited|failed|orphaned|
  reorged; `cancelled` is added because the build brief asks for it. A credited
  deposit is terminal: reversing it after a reorg needs a compensating
  `deposit_reversal` transaction, which is NOT implemented in this step.)

Idempotency (the property that makes crediting safe)
----------------------------------------------------
Three independent guards, all in the database:
  1. `deposits_chain_key` — UNIQUE (environment, network, txid, log_index). One
     chain transaction is one deposit row, ever. `log_index` is -1 for a native
     transfer (no log/event), >= 0 for a log entry, so USDT on Ethereum (a log)
     and USDT on Tron (a tx) cannot collide on the same txid.
  2. `credit_deposit()` refuses a deposit that is already credited, is terminal,
     or whose (network, txid, log_index) was already credited by another row,
     and locks the row (`FOR UPDATE`) so two concurrent credits serialise.
  3. The ledger transaction it writes carries
     `idempotency_key = deposit_credit:<environment>:<network>:<txid>:<log_index>`,
     which the ledger's own unique index rejects a second time — so even a bug
     that got past the deposit guards cannot post the credit twice.

Crediting
---------
`credit_deposit()` posts through the existing immutable ledger: one
`deposit_credit` transaction, the user's **available** account credited, the
`EXTERNAL_DEPOSIT` system account for that asset/environment debited for the
same amount (system accounts may go negative — they are the counterparty side of
the double entry). The transaction, both postings and the `deposits` status
change happen in one function call, i.e. one transaction, so the deferred
invariants of migration 3 (zero-sum per asset, >= 2 accounts, cached balance ==
ledger sum) hold for every credit or nothing happens. Related tables:
`ledger_transactions.type = 'deposit_credit'` and
`reference_type = 'deposit'` / `reference_id = deposits.id`.

Gating (paper mode vs live)
---------------------------
`assert_deposits_enabled()` is the one place the deposit switch is read.
`app_settings.deposits_enabled` is the DB side of the plan's
`LIVE_DEPOSITS_ENABLED`: while `mode = 'live'` a deposit write is refused unless
it is true, and the `enforce_environment_gate` trigger (migration 1, which maps
the table name `deposits` to exactly that flag) refuses a live row a second time
independently. In paper mode the operator mechanics are **not** gated by the flag
— it is the real-money (live) switch, and paper deposits are the same mechanics
the paper faucet already uses. This reading is flagged in the build report as an
ambiguity in the spec (see SCHEMA.md §9). There is no automatic path in this
step: every deposit row is written by `record_deposit()` with the txid the
operator supplies.
*/

-- ---------------------------------------------------------------------------
-- deposit_networks — supported (asset, network) configuration
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.deposit_networks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  network text NOT NULL,
  environment text NOT NULL DEFAULT 'paper',
  chain_id bigint,
  requires_memo boolean NOT NULL DEFAULT false,
  required_confirmations integer NOT NULL,
  min_deposit_units numeric(38, 0),
  deposit_enabled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deposit_networks_network_check CHECK (network ~ '^[a-z0-9][a-z0-9._-]{1,31}$'),
  CONSTRAINT deposit_networks_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT deposit_networks_confirmations_check CHECK (required_confirmations BETWEEN 0 AND 1000),
  CONSTRAINT deposit_networks_min_units_check CHECK (
    min_deposit_units IS NULL
    OR (min_deposit_units > 0 AND min_deposit_units = trunc(min_deposit_units))
  )
);

-- the (asset, network, environment) triple is the configuration key and the
-- target of the composite FK from deposits / deposit_addresses
CREATE UNIQUE INDEX IF NOT EXISTS deposit_networks_key
  ON public.deposit_networks (asset_id, network, environment);

DROP TRIGGER IF EXISTS deposit_networks_set_updated_at ON public.deposit_networks;
CREATE TRIGGER deposit_networks_set_updated_at
  BEFORE UPDATE ON public.deposit_networks
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.deposit_networks IS
  'Which (asset, network) pairs the exchange accepts, per environment: confirmation policy, memo/tag requirement, minimum deposit and the deposit_enabled switch. Operator configuration — never seeded, and a deposit can only be recorded on a registered network.';
COMMENT ON COLUMN public.deposit_networks.network IS
  'Chain/network identifier as it appears on the chain: bitcoin, ethereum, tron, solana, ... (USDT exists on several, so the asset symbol alone is not enough). Distinct from assets.chain, which is the asset''s home chain.';
COMMENT ON COLUMN public.deposit_networks.required_confirmations IS
  'Confirmations a deposit must reach before credit_deposit() will credit it. Set by the operator; no default is invented here.';
COMMENT ON COLUMN public.deposit_networks.min_deposit_units IS
  'Smallest creditable deposit in base units. NULL means "not configured", which the deposits layer treats as "deposits disabled" for that network (migration 1 convention) — the operator must set it before anything can be credited.';

-- ---------------------------------------------------------------------------
-- deposit_addresses — where a user sends funds (provided, never generated)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.deposit_addresses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  asset_id uuid NOT NULL,
  network text NOT NULL,
  environment text NOT NULL DEFAULT 'paper',
  address text NOT NULL,
  address_tag text,
  label text,
  active boolean NOT NULL DEFAULT true,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deposit_addresses_address_check CHECK (
    length(btrim(address)) BETWEEN 4 AND 200 AND address !~ '\s'
  ),
  CONSTRAINT deposit_addresses_network_fkey
    FOREIGN KEY (asset_id, network, environment)
    REFERENCES public.deposit_networks (asset_id, network, environment)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

-- one deposit address on a network belongs to one owner (and one environment)
CREATE UNIQUE INDEX IF NOT EXISTS deposit_addresses_chain_key
  ON public.deposit_addresses (environment, network, address);

-- at most one active address per user/asset/network/environment
CREATE UNIQUE INDEX IF NOT EXISTS deposit_addresses_active_user_key
  ON public.deposit_addresses (user_id, asset_id, network, environment)
  WHERE active AND user_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS deposit_addresses_user_idx
  ON public.deposit_addresses (user_id, environment);

DROP TRIGGER IF EXISTS deposit_addresses_set_updated_at ON public.deposit_addresses;
CREATE TRIGGER deposit_addresses_set_updated_at
  BEFORE UPDATE ON public.deposit_addresses
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.deposit_addresses IS
  'Deposit address per user / asset / network / environment. The address string is supplied by the caller (operator now, custody provider later) — this schema never generates or seeds chain addresses. user_id is nullable only so the requirements doc''s shared-address case stays representable; no code path creates a NULL-user row yet.';
COMMENT ON COLUMN public.deposit_addresses.address_tag IS
  'Memo/tag/destination tag for networks that need one (deposit_networks.requires_memo). NULL when the network does not use one.';

-- ---------------------------------------------------------------------------
-- deposits — observed inbound chain transactions and their credit state
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.deposits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  asset_id uuid NOT NULL,
  network text NOT NULL,
  environment text NOT NULL,
  address text,
  memo text,
  txid text NOT NULL,
  log_index integer NOT NULL DEFAULT -1,
  amount_units numeric(38, 0) NOT NULL,
  confirmations integer NOT NULL DEFAULT 0,
  required_confirmations integer NOT NULL,
  status text NOT NULL DEFAULT 'detected',
  credited_ledger_transaction_id uuid REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  failed_reason text,
  detected_at timestamptz NOT NULL DEFAULT now(),
  credited_at timestamptz,
  raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT deposits_txid_check CHECK (length(btrim(txid)) BETWEEN 1 AND 200),
  CONSTRAINT deposits_log_index_check CHECK (log_index >= -1),
  CONSTRAINT deposits_amount_check CHECK (
    amount_units > 0 AND amount_units = trunc(amount_units)
  ),
  CONSTRAINT deposits_confirmations_check CHECK (confirmations >= 0),
  CONSTRAINT deposits_required_confirmations_check CHECK (required_confirmations BETWEEN 0 AND 1000),
  CONSTRAINT deposits_status_check CHECK (status IN (
    'detected', 'confirming', 'credited', 'failed', 'cancelled', 'orphaned', 'reorged'
  )),
  -- credited <=> has a ledger transaction, and only a credited row may
  CONSTRAINT deposits_credited_reference_check CHECK (
    (status = 'credited') = (credited_ledger_transaction_id IS NOT NULL)
  ),
  CONSTRAINT deposits_credited_state_check CHECK (
    status <> 'credited'
    OR (credited_at IS NOT NULL AND confirmations >= required_confirmations)
  ),
  CONSTRAINT deposits_network_fkey
    FOREIGN KEY (asset_id, network, environment)
    REFERENCES public.deposit_networks (asset_id, network, environment)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

-- guard #1 of the idempotency: one chain transaction == one deposit row, ever
CREATE UNIQUE INDEX IF NOT EXISTS deposits_chain_key
  ON public.deposits (environment, network, txid, log_index);

CREATE INDEX IF NOT EXISTS deposits_user_idx ON public.deposits (user_id, detected_at DESC);
CREATE INDEX IF NOT EXISTS deposits_status_idx ON public.deposits (environment, status, detected_at DESC);
CREATE INDEX IF NOT EXISTS deposits_ledger_idx ON public.deposits (credited_ledger_transaction_id);

DROP TRIGGER IF EXISTS deposits_environment_gate ON public.deposits;
CREATE TRIGGER deposits_environment_gate
  BEFORE INSERT ON public.deposits
  FOR EACH ROW EXECUTE FUNCTION public.enforce_environment_gate();

COMMENT ON TABLE public.deposits IS
  'One row per observed inbound chain transaction: state machine, confirmations, provider txid and the ledger transaction that credited it. Written only by record_deposit()/credit_deposit()/set_deposit_confirmations()/fail_deposit() (service_role) — a client role has no write path, or a user could mint funds. Unique (environment, network, txid, log_index).';
COMMENT ON COLUMN public.deposits.log_index IS
  'Log/event index inside the txid; -1 for a native transfer that has no log. Part of the idempotency key, so a txid that carries several transfers keeps them apart.';
COMMENT ON COLUMN public.deposits.credited_ledger_transaction_id IS
  'The immutable double-entry transaction that credited this deposit. Write-once (trigger): a credit is never re-pointed.';
COMMENT ON COLUMN public.deposits.required_confirmations IS
  'Snapshot of deposit_networks.required_confirmations at record time, so a later policy change cannot retroactively make an old deposit creditable.';

-- ---------------------------------------------------------------------------
-- immutability + state machine of a deposit row
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.deposits_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_allowed boolean;
BEGIN
  IF NEW.user_id     <> OLD.user_id
     OR NEW.asset_id <> OLD.asset_id
     OR NEW.network  <> OLD.network
     OR NEW.environment <> OLD.environment
     OR NEW.txid     <> OLD.txid
     OR NEW.log_index <> OLD.log_index
     OR NEW.amount_units <> OLD.amount_units
     OR NEW.required_confirmations <> OLD.required_confirmations THEN
    RAISE EXCEPTION
      'the chain identity of deposit % is immutable (user, asset, network, environment, txid, log_index, amount, required_confirmations can never change)',
      OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.status <> OLD.status THEN
    v_allowed := CASE OLD.status
                   WHEN 'detected'   THEN NEW.status IN ('confirming', 'credited', 'failed', 'cancelled', 'orphaned', 'reorged')
                   WHEN 'confirming' THEN NEW.status IN ('credited', 'failed', 'cancelled', 'orphaned', 'reorged')
                   ELSE false
                 END;
    IF NOT v_allowed THEN
      RAISE EXCEPTION 'illegal deposit status transition on deposit %: % -> % (% is terminal or the step is not part of the state machine)',
        OLD.id, OLD.status, NEW.status, OLD.status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF NEW.confirmations < OLD.confirmations THEN
    RAISE EXCEPTION 'confirmations on deposit % cannot go backwards (% -> %)',
      OLD.id, OLD.confirmations, NEW.confirmations
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.credited_ledger_transaction_id IS NOT NULL
     AND NEW.credited_ledger_transaction_id IS DISTINCT FROM OLD.credited_ledger_transaction_id THEN
    RAISE EXCEPTION 'the ledger transaction that credited deposit % is immutable (% -> %)',
      OLD.id, OLD.credited_ledger_transaction_id, NEW.credited_ledger_transaction_id
      USING ERRCODE = 'check_violation';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS deposits_before_update ON public.deposits;
CREATE TRIGGER deposits_before_update
  BEFORE UPDATE ON public.deposits
  FOR EACH ROW EXECUTE FUNCTION public.deposits_before_update();

-- ---------------------------------------------------------------------------
-- the deposit gate: the DB side of LIVE_DEPOSITS_ENABLED
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_deposits_enabled()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_mode text;
  v_deposits boolean;
BEGIN
  SELECT mode, deposits_enabled
    INTO v_mode, v_deposits
    FROM public.app_settings
   WHERE id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'app_settings has no row: the deposit gate cannot be evaluated'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_mode = 'live' AND NOT COALESCE(v_deposits, false) THEN
    RAISE EXCEPTION
      'live deposits are disabled: app_settings.mode = live but deposits_enabled = false; refusing to move funds'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN v_mode;
END $$;

COMMENT ON FUNCTION public.assert_deposits_enabled() IS
  'Reads the single app_settings row and raises when a deposit write is not allowed (live mode with deposits_enabled = false). Returns the environment deposits are written in. Called by every deposit entry point; the deposits table carries enforce_environment_gate as the independent second gate.';

-- ---------------------------------------------------------------------------
-- operator path 1: register a network, an address, and an observed deposit
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_deposit_network(
  p_asset_symbol           text,
  p_network                text,
  p_required_confirmations integer,
  p_chain_id               bigint DEFAULT NULL,
  p_requires_memo          boolean DEFAULT false,
  p_min_deposit_units      numeric DEFAULT NULL,
  p_deposit_enabled        boolean DEFAULT false
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_asset uuid;
  v_env   text := public.app_mode();
  v_id    uuid;
BEGIN
  SELECT id INTO v_asset FROM public.assets WHERE symbol = p_asset_symbol;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'unknown asset symbol %', p_asset_symbol USING ERRCODE = 'no_data_found';
  END IF;

  INSERT INTO public.deposit_networks AS dn (
    asset_id, network, environment, chain_id, requires_memo,
    required_confirmations, min_deposit_units, deposit_enabled
  )
  VALUES (
    v_asset, p_network, v_env, p_chain_id, COALESCE(p_requires_memo, false),
    p_required_confirmations, p_min_deposit_units, COALESCE(p_deposit_enabled, false)
  )
  ON CONFLICT (asset_id, network, environment) DO UPDATE
     SET chain_id               = EXCLUDED.chain_id,
         requires_memo          = EXCLUDED.requires_memo,
         required_confirmations = EXCLUDED.required_confirmations,
         min_deposit_units      = EXCLUDED.min_deposit_units,
         deposit_enabled        = EXCLUDED.deposit_enabled
  RETURNING dn.id INTO v_id;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION public.register_deposit_network(text, text, integer, bigint, boolean, numeric, boolean) IS
  'Operator path: create or reconfigure an (asset, network) deposit configuration in the current environment (app_mode()). Upsert by (asset, network, environment). service_role only — this is configuration, no deposit is created and no address is generated.';

CREATE OR REPLACE FUNCTION public.register_deposit_address(
  p_user_id     uuid,
  p_asset_symbol text,
  p_network     text,
  p_address     text,
  p_address_tag text DEFAULT NULL,
  p_label       text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_asset    uuid;
  v_env      text := public.app_mode();
  v_existing record;
  v_id       uuid;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'a deposit address is provisioned for one user: p_user_id is required'
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %', p_user_id USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_asset FROM public.assets WHERE symbol = p_asset_symbol;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'unknown asset symbol %', p_asset_symbol USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.deposit_networks dn
     WHERE dn.asset_id = v_asset AND dn.network = p_network AND dn.environment = v_env
  ) THEN
    RAISE EXCEPTION 'network % is not registered for % in %: call register_deposit_network() first',
      p_network, p_asset_symbol, v_env
      USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id, address INTO v_existing
    FROM public.deposit_addresses
   WHERE user_id = p_user_id AND asset_id = v_asset
     AND network = p_network AND environment = v_env AND active;

  IF FOUND THEN
    IF v_existing.address = p_address THEN
      RETURN v_existing.id;   -- idempotent: the same address is not registered twice
    END IF;
    RAISE EXCEPTION
      'user % already has an active %/% deposit address in % (%): deactivate it before assigning another',
      p_user_id, p_asset_symbol, p_network, v_env, v_existing.address
      USING ERRCODE = 'unique_violation';
  END IF;

  INSERT INTO public.deposit_addresses (
    user_id, asset_id, network, environment, address, address_tag, label
  )
  VALUES (p_user_id, v_asset, p_network, v_env, btrim(p_address), p_address_tag, p_label)
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION public.register_deposit_address(uuid, text, text, text, text, text) IS
  'Operator/provider path: register the address a user deposits to, for one asset on one network in the current environment. The caller supplies the address string — nothing is generated. Idempotent for the same address; refuses to replace a different active address. service_role only.';

CREATE OR REPLACE FUNCTION public.record_deposit(
  p_user_id       uuid,
  p_asset_symbol  text,
  p_network       text,
  p_txid          text,
  p_amount_units  numeric,
  p_log_index     integer DEFAULT -1,
  p_address       text DEFAULT NULL,
  p_memo          text DEFAULT NULL,
  p_confirmations integer DEFAULT 0,
  p_raw           jsonb DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_asset   uuid;
  v_env     text;
  v_net     public.deposit_networks;
  v_id      uuid;
  v_log     integer := COALESCE(p_log_index, -1);
  v_conf    integer := COALESCE(p_confirmations, 0);
BEGIN
  v_env := public.assert_deposits_enabled();

  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %: a deposit belongs to exactly one user', p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_asset FROM public.assets WHERE symbol = p_asset_symbol;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'unknown asset symbol %', p_asset_symbol USING ERRCODE = 'no_data_found';
  END IF;

  SELECT * INTO v_net
    FROM public.deposit_networks
   WHERE asset_id = v_asset AND network = p_network AND environment = v_env;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'network % is not registered for % in %: call register_deposit_network() first',
      p_network, p_asset_symbol, v_env
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_txid IS NULL OR btrim(p_txid) = '' THEN
    RAISE EXCEPTION 'a deposit needs the provider txid it was seen in'
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  IF p_amount_units IS NULL OR p_amount_units <= 0 OR p_amount_units <> trunc(p_amount_units) THEN
    RAISE EXCEPTION 'deposit amount must be a positive whole number of base units (got %)', p_amount_units
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_conf < 0 THEN
    RAISE EXCEPTION 'confirmations cannot be negative (%)', v_conf
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_net.requires_memo AND (p_memo IS NULL OR btrim(p_memo) = '') THEN
    RAISE EXCEPTION 'network % requires a memo/tag on every deposit', p_network
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  -- idempotent by chain identity: an operator/watcher replaying the same chain
  -- transaction gets the existing row back instead of a second deposit
  SELECT id INTO v_id
    FROM public.deposits
   WHERE environment = v_env AND network = p_network
     AND txid = p_txid AND log_index = v_log;
  IF FOUND THEN
    RETURN v_id;
  END IF;

  INSERT INTO public.deposits (
    user_id, asset_id, network, environment, address, memo, txid, log_index,
    amount_units, confirmations, required_confirmations, status, detected_at, raw
  )
  VALUES (
    p_user_id, v_asset, p_network, v_env, p_address, p_memo, btrim(p_txid), v_log,
    p_amount_units, v_conf, v_net.required_confirmations,
    CASE WHEN v_conf > 0 THEN 'confirming' ELSE 'detected' END, now(), COALESCE(p_raw, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION public.record_deposit(uuid, text, text, text, numeric, integer, text, text, integer, jsonb) IS
  'Operator/watcher path: record an observed inbound chain transaction for a user (status detected, or confirming when confirmations > 0). The txid is supplied by the caller — nothing is invented. Idempotent on (environment, network, txid, log_index). service_role only.';

-- ---------------------------------------------------------------------------
-- operator path 2: confirmations, terminal states and crediting
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_deposit_confirmations(
  p_deposit_id    uuid,
  p_confirmations integer
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dep    public.deposits;
  v_status text;
BEGIN
  PERFORM public.assert_deposits_enabled();

  SELECT * INTO v_dep FROM public.deposits WHERE id = p_deposit_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown deposit %', p_deposit_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_dep.status IN ('credited', 'failed', 'cancelled', 'orphaned', 'reorged') THEN
    RAISE EXCEPTION 'deposit % is % (terminal): its confirmations cannot be updated', v_dep.id, v_dep.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_confirmations IS NULL OR p_confirmations < 0 THEN
    RAISE EXCEPTION 'confirmations must be a non-negative integer (got %)', p_confirmations
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_confirmations < v_dep.confirmations THEN
    RAISE EXCEPTION 'confirmations on deposit % cannot go backwards (% -> %)', v_dep.id, v_dep.confirmations, p_confirmations
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.deposits
     SET confirmations = p_confirmations,
         status = CASE
                    WHEN v_dep.status = 'detected' AND p_confirmations > 0 THEN 'confirming'
                    ELSE v_dep.status
                  END
   WHERE id = v_dep.id
  RETURNING status INTO v_status;

  RETURN v_status;
END $$;

COMMENT ON FUNCTION public.set_deposit_confirmations(uuid, integer) IS
  'Operator/watcher path: record how many confirmations a deposit now has. Monotonic, refused on a terminal deposit; moves detected -> confirming on the first confirmation. Returns the resulting status. service_role only.';

CREATE OR REPLACE FUNCTION public.fail_deposit(
  p_deposit_id uuid,
  p_status     text,
  p_reason     text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dep public.deposits;
BEGIN
  PERFORM public.assert_deposits_enabled();

  SELECT * INTO v_dep FROM public.deposits WHERE id = p_deposit_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown deposit %', p_deposit_id USING ERRCODE = 'no_data_found';
  END IF;

  IF p_status IS NULL OR p_status NOT IN ('failed', 'cancelled', 'orphaned', 'reorged') THEN
    RAISE EXCEPTION 'fail_deposit can only move a deposit to failed|cancelled|orphaned|reorged (got %)', p_status
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_dep.status NOT IN ('detected', 'confirming') THEN
    RAISE EXCEPTION 'deposit % is % (terminal): it cannot be moved to %', v_dep.id, v_dep.status, p_status
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.deposits
     SET status = p_status,
         failed_reason = p_reason
   WHERE id = v_dep.id;
END $$;

COMMENT ON FUNCTION public.fail_deposit(uuid, text, text) IS
  'Operator/watcher path: move an uncredited deposit to a terminal non-credit state (failed|cancelled|orphaned|reorged) with a reason. A credited deposit is never touched here — reversing a credit needs a compensating ledger transaction, which is not implemented yet. service_role only.';

CREATE OR REPLACE FUNCTION public.credit_deposit(p_deposit_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_dep    public.deposits;
  v_net    public.deposit_networks;
  v_tx     uuid;
  v_user   uuid;
  v_clear  uuid;
BEGIN
  PERFORM public.assert_deposits_enabled();

  -- serialise concurrent credits of the same deposit on its own row
  SELECT * INTO v_dep FROM public.deposits WHERE id = p_deposit_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown deposit %', p_deposit_id USING ERRCODE = 'no_data_found';
  END IF;

  -- guard #2 of the idempotency: an explicit, readable refusal
  IF v_dep.status = 'credited' OR v_dep.credited_ledger_transaction_id IS NOT NULL THEN
    RAISE EXCEPTION 'deposit % is already credited by ledger transaction %: a chain transaction can never be credited twice',
      v_dep.id, v_dep.credited_ledger_transaction_id
      USING ERRCODE = 'unique_violation';
  END IF;

  IF v_dep.status NOT IN ('detected', 'confirming') THEN
    RAISE EXCEPTION 'deposit % is % (terminal): only a detected or confirming deposit can be credited', v_dep.id, v_dep.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.deposits d
     WHERE d.environment = v_dep.environment AND d.network = v_dep.network
       AND d.txid = v_dep.txid AND d.log_index = v_dep.log_index
       AND d.status = 'credited' AND d.id <> v_dep.id
  ) THEN
    RAISE EXCEPTION 'chain transaction % on % (log_index %) has already been credited by another deposit row',
      v_dep.txid, v_dep.network, v_dep.log_index
      USING ERRCODE = 'unique_violation';
  END IF;

  SELECT * INTO v_net
    FROM public.deposit_networks
   WHERE asset_id = v_dep.asset_id AND network = v_dep.network AND environment = v_dep.environment;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'deposit % references an unregistered network (% on %)', v_dep.id, v_dep.network, v_dep.environment
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT v_net.deposit_enabled THEN
    RAISE EXCEPTION 'deposits are not enabled for % on % in %: enable the network first',
      v_dep.asset_id, v_dep.network, v_dep.environment
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_net.min_deposit_units IS NULL THEN
    RAISE EXCEPTION 'no minimum deposit is configured for % on % in % (min_deposit_units is NULL = not configured = deposits disabled for that network)',
      v_dep.asset_id, v_dep.network, v_dep.environment
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_dep.amount_units < v_net.min_deposit_units THEN
    RAISE EXCEPTION 'deposit % of % base units is below the configured minimum of % for % on %',
      v_dep.id, v_dep.amount_units, v_net.min_deposit_units, v_dep.asset_id, v_dep.network
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_dep.confirmations < v_dep.required_confirmations THEN
    RAISE EXCEPTION 'deposit % has % of the % required confirmations: not creditable yet',
      v_dep.id, v_dep.confirmations, v_dep.required_confirmations
      USING ERRCODE = 'check_violation';
  END IF;

  -- the credit: user available +amount, EXTERNAL_DEPOSIT system account -amount
  v_user  := public.ensure_user_account(v_dep.user_id, v_dep.asset_id, 'available', v_dep.environment);
  v_clear := public.system_account_id('EXTERNAL_DEPOSIT', v_dep.asset_id, v_dep.environment);

  -- guard #3 of the idempotency: the ledger's own unique idempotency_key
  INSERT INTO public.ledger_transactions (
    type, environment, idempotency_key, reference_type, reference_id, description, metadata
  )
  VALUES (
    'deposit_credit', v_dep.environment,
    'deposit_credit:' || v_dep.environment || ':' || v_dep.network || ':' || v_dep.txid || ':' || v_dep.log_index,
    'deposit', v_dep.id, 'deposit credited',
    jsonb_build_object(
      'network', v_dep.network,
      'txid', v_dep.txid,
      'log_index', v_dep.log_index,
      'confirmations', v_dep.confirmations,
      'amount_units', v_dep.amount_units
    )
  )
  RETURNING id INTO v_tx;

  PERFORM public.post_entry(v_tx, v_user,  v_dep.amount_units, 'deposit ' || v_dep.txid);
  PERFORM public.post_entry(v_tx, v_clear, -v_dep.amount_units, 'deposit clearing ' || v_dep.txid);

  UPDATE public.deposits
     SET status = 'credited',
         credited_ledger_transaction_id = v_tx,
         credited_at = now()
   WHERE id = v_dep.id;

  RETURN v_tx;
END $$;

COMMENT ON FUNCTION public.credit_deposit(uuid) IS
  'Operator path: credit a confirmed deposit. Posts one immutable deposit_credit ledger transaction (user available += amount, EXTERNAL_DEPOSIT system account -= amount) and flips the deposit to credited in the same transaction, so the deferred ledger invariants hold or nothing happens. Refuses an already credited/terminal deposit, a below-policy confirmation count, a disabled network, a below-minimum amount, and double-credits (row lock + explicit guard + ledger idempotency key). service_role only.';

-- ---------------------------------------------------------------------------
-- RLS and privileges
-- ---------------------------------------------------------------------------
ALTER TABLE public.deposit_networks  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deposit_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deposits          ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['deposit_networks', 'deposit_addresses', 'deposits'] LOOP
    -- anonymous visitors: nothing at all, not even the configuration
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
    END IF;

    -- signed-in users: read-only, and only what an RLS policy allows
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM authenticated', t);
      EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    END IF;

    -- server side: the operator/watcher paths
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM service_role', t);
      EXECUTE format('GRANT SELECT, INSERT, UPDATE ON public.%I TO service_role', t);
    END IF;
  END LOOP;
END $$;

-- No DELETE for anybody: a deposit row is evidence, and configuration is
-- deactivated (deposit_addresses.active) rather than deleted.
DROP POLICY IF EXISTS deposit_networks_select_authenticated ON public.deposit_networks;
CREATE POLICY deposit_networks_select_authenticated ON public.deposit_networks
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS deposit_addresses_select_own ON public.deposit_addresses;
CREATE POLICY deposit_addresses_select_own ON public.deposit_addresses
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS deposits_select_own ON public.deposits;
CREATE POLICY deposits_select_own ON public.deposits
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- No INSERT/UPDATE/DELETE policy for anon or authenticated: client writes are
-- denied by RLS regardless of any future privilege grant.

-- ---------------------------------------------------------------------------
-- function ACLs — same pattern as 20261005100100: Supabase grants EXECUTE on new
-- functions to anon/authenticated/service_role by default, so PUBLIC and the
-- client roles are revoked explicitly and only service_role gets it back.
-- ---------------------------------------------------------------------------
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
         'assert_deposits_enabled', 'register_deposit_network', 'register_deposit_address',
         'record_deposit', 'set_deposit_confirmations', 'fail_deposit', 'credit_deposit'
       )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', f.sig);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM authenticated', f.sig);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', f.sig);
    END IF;
  END LOOP;
END $$;
-- (deposits_before_update is a trigger function and keeps the default EXECUTE
-- grant on purpose: PostgreSQL checks EXECUTE with the invoking role, so
-- revoking it would break the trigger, and it cannot be called outside one.)
