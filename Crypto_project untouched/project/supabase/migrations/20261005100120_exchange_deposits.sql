/*
# Migration 9/9 — deposit addresses, deposit state machine, ledger crediting and the
# provider-adapter contract

Purpose
-------
The database layer of the deposit path for BTC / ETH / USDT / SOL — the model, the
state machine, the RPCs an operator calls and the contract a (future) live
blockchain-provider adapter must satisfy.
**No chain integration, no address generation, no external provider, no credentials,
no seeded data of any kind.** Nothing here invents a chain address, a confirmation or
a deposit.

Statuses (owner-specified, 2026-10-11 — these five and no others)
-----------------------------------------------------------------
    pending, confirming, confirmed, failed, under review

    pending       seen by the watcher/operator, below the network's confirmation policy
    confirming    partial confirmations, still below the policy
    confirmed     the confirmation policy is reached; this is the ONLY state a deposit
                  can be credited from
    failed        terminal: rejected/dropped/cancelled — always carries `failed_reason`
    under review  operator hold (suspicious, needs approval); crediting is refused
                  while the hold is open

Crediting is **data on the row**, not a status: `credited_ledger_transaction_id` +
`credited_at` are set (atomically with the ledger posting, in the same call) and
`status` stays `confirmed`. `(credited_ledger_transaction_id IS NULL) = (credited_at IS
NULL)` holds by CHECK, so "credited" can only ever be observed as data.

    state machine (enforced by the deposits_before_update trigger)
        pending      --> confirming | confirmed | failed | under review
        confirming   --> confirmed  | failed    | under review
        under review --> confirmed  | failed
        confirmed    --> failed, but ONLY while the row is not credited (an
                         operator can still reject a confirmed deposit before the
                         credit posts); a credited row can never leave confirmed
                         (deposits_credit_state_check)
        failed       --> (terminal)

Mapping from the pre-directive draft of this migration (this file was never deployed,
so the rename is free; recorded here so the earlier run-1 report stays readable):

    detected   -> pending
    confirming -> confirming      (unchanged)
    credited   -> dropped as a status; credit is now credited_ledger_transaction_id
                  + credited_at on a row whose status is `confirmed`
    cancelled  -> failed + failed_reason   (folded: one terminal non-credit state)
    orphaned   -> failed + failed_reason   (folded, e.g. 'orphaned: dropped from the mempool')
    reorged    -> failed + failed_reason   (folded)

Shape
-----
- `deposit_networks` — which (asset, network) pairs the exchange accepts, with the
  confirmation policy and the minimum deposit. Operator configuration, not seeded (a
  network that is not registered cannot receive a deposit). `environment` keeps paper
  and live configuration apart.
- `deposit_addresses` — where a user is told to send funds: per-user, per asset, per
  network, address-tag aware (memo/tag). Provisioning is pluggable by design:
  `register_deposit_address()` takes the address string from the caller, so an operator
  types it now and a custody provider supplies it later. **No address is generated or
  seeded here.**
- `deposits` — one row per observed inbound chain transaction, with the state machine,
  the confirmation count, the provider txid, the credit data and `source` (which path
  produced the row).

Paper vs real: two paths, distinguishable in the data
-----------------------------------------------------
`deposits.source` + `deposits.environment` say which path produced a row, and the two
paths cannot be mixed — a CHECK pins the pairing and each entry point refuses the other
mode:

| source             | environment | entry point                | who calls it                        |
|--------------------|-------------|----------------------------|-------------------------------------|
| `paper_operator`   | `paper`     | `record_deposit()`         | operator / test harness (paper only)|
| `provider_adapter` | `live`      | `record_provider_deposit()`| the live chain-provider adapter     |

- `record_deposit()` (paper) raises while `app_settings.mode = 'live'`; paper data can
  never be written as a real deposit.
- `record_provider_deposit()` (live) raises while `app_settings.mode <> 'live'`; a
  provider event can never enter the paper path. It also passes through the
  `LIVE_DEPOSITS_ENABLED` gate, and the `enforce_environment_gate` trigger (migration 1)
  refuses a live row a second time independently.
- Paper rows are never represented as chain-verified: they carry
  `source = 'paper_operator'`, and the live cell of the table above is unreachable
  without a provider adapter.

Provider adapter contract (the interface the live path depends on)
------------------------------------------------------------------
The pipeline depends on this contract, not on any provider. An adapter (whatever
provider) turns a provider event into **one normalised JSON object** and hands it to
`record_provider_deposit(p_event jsonb) RETURNS uuid`; nothing else in the deposit
layer reads provider-specific data.

    { "network":       "bitcoin",          -- required, text (deposit_networks.network)
      "asset_symbol":  "BTC",              -- required, text (assets.symbol)
      "user_id":       "<uuid>",           -- required, owner resolved by the adapter
      "txid":          "<chain tx hash>",  -- required, text
      "amount_units":  100000000,          -- required, base units (whole number > 0)
      "log_index":     -1,                 -- optional, -1 = native transfer (default -1)
      "confirmations": 0,                  -- optional, >= 0 (default 0)
      "to_address":    "<chain address>",  -- optional, the address the funds went to
      "memo":          null,               -- optional, memo/tag where the network needs one
      ... any further provider fields are preserved verbatim in deposits.raw }

Mapping into a row (all of it is what `record_deposit` does, plus the live-only fields):

| event field      | deposits column        | rule                                              |
|------------------|------------------------|---------------------------------------------------|
| `network`        | `network`              | must be registered for (asset, live)              |
| `asset_symbol`   | `asset_id`             | must exist in `assets`                            |
| `user_id`        | `user_id`              | must exist in `auth.users`                        |
| `txid`           | `txid`                 | non-blank; part of the chain key                  |
| `log_index`      | `log_index`            | default -1                                        |
| `amount_units`   | `amount_units`         | positive whole number of base units               |
| `confirmations`  | `confirmations`        | >= 0; status pending/confirming/confirmed from it |
| `to_address`     | `address`              | recorded as reported, never verified here         |
| `memo`           | `memo`                 | required when `deposit_networks.requires_memo`    |
| whole event      | `raw`                  | the adapter event, kept verbatim for audit        |
| (path constant)  | `source` / `environment`| `provider_adapter` / `live`                      |

A missing required key, a non-object event or a non-numeric amount is refused as an
*adapter contract violation* (`invalid_parameter_value`), so a provider that changes its
payload shape cannot silently record a wrong deposit. The adapter itself — network
polling, signature verification, key management — is NOT implemented in this step; this
migration defines the boundary it must meet.

Idempotency (the property that makes crediting safe)
----------------------------------------------------
Three independent guards, all in the database:
  1. `deposits_chain_key` — UNIQUE (environment, network, txid, log_index). One chain
     transaction is one deposit row, ever. `log_index` is -1 for a native transfer (no
     log/event), >= 0 for a log entry, so USDT on Ethereum (a log) and USDT on Tron
     (a tx) cannot collide on the same txid.
  2. `credit_deposit()` refuses a deposit that already carries credit data, is not
     `confirmed`, or whose (network, txid, log_index) was already credited by another
     row, and locks the row (`FOR UPDATE`) so two concurrent credits serialise.
  3. The ledger transaction it writes carries
     `idempotency_key = deposit_credit:<environment>:<network>:<txid>:<log_index>`,
     which the ledger's own unique index rejects a second time — so even a bug that got
     past the deposit guards cannot post the credit twice.

Crediting
---------
`credit_deposit()` posts through the existing immutable ledger: one `deposit_credit`
transaction, the user's **available** account credited, the `EXTERNAL_DEPOSIT` system
account for that asset/environment debited for the same amount (system accounts may go
negative — they are the counterparty side of the double entry). The transaction, both
postings and the deposit's credit data/`credited_at` are written in one function call,
i.e. one transaction, so the deferred invariants of migration 3 (zero-sum per asset,
>= 2 accounts, cached balance == ledger sum) hold for every credit or nothing happens.
Related tables: `ledger_transactions.type = 'deposit_credit'` and `reference_type =
'deposit'` / `reference_id = deposits.id`.

Gating (paper mode vs live)
---------------------------
`assert_deposits_enabled()` is the one place the deposit switch is read.
`app_settings.deposits_enabled` is the DB side of the plan's `LIVE_DEPOSITS_ENABLED`:
while `mode = 'live'` a deposit write is refused unless it is true, and the
`enforce_environment_gate` trigger (migration 1, which maps the table name `deposits` to
exactly that flag) refuses a live row a second time independently. In paper mode the
operator mechanics are **not** gated by the flag — it is the real-money (live) switch.
There is no automatic path in this step: every deposit row is written by `record_deposit()`
(paper) or `record_provider_deposit()` (live) with the txid the caller supplies.
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
  'Confirmations a deposit must reach before it can become confirmed (and only a confirmed deposit can be credited). Set by the operator; no default is invented here. 0 means "no policy configured", which credit_deposit() refuses to credit.';
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
-- deposits — observed inbound chain transactions, their state and their credit data
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.deposits (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  asset_id uuid NOT NULL,
  network text NOT NULL,
  environment text NOT NULL,
  source text NOT NULL DEFAULT 'paper_operator',
  address text,
  memo text,
  txid text NOT NULL,
  log_index integer NOT NULL DEFAULT -1,
  amount_units numeric(38, 0) NOT NULL,
  confirmations integer NOT NULL DEFAULT 0,
  required_confirmations integer NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  credited_ledger_transaction_id uuid REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  failed_reason text,
  review_reason text,
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
  -- the owner's five statuses, and no other value
  CONSTRAINT deposits_status_check CHECK (status IN (
    'pending', 'confirming', 'confirmed', 'failed', 'under review'
  )),
  -- which path produced the row is part of the row, and the two paths cannot mix:
  -- the paper operator/test path only ever writes paper rows, the provider adapter
  -- only ever writes live rows.
  CONSTRAINT deposits_source_check CHECK (source IN ('paper_operator', 'provider_adapter')),
  CONSTRAINT deposits_source_environment_check CHECK (
    (source = 'provider_adapter') = (environment = 'live')
  ),
  -- `confirmed` means the confirmation policy was reached
  CONSTRAINT deposits_confirmed_state_check CHECK (
    status <> 'confirmed' OR confirmations >= required_confirmations
  ),
  -- crediting is data: the ledger transaction and the timestamp appear together
  -- (or not at all), and credit data only ever exists on a confirmed row
  CONSTRAINT deposits_credit_data_check CHECK (
    (credited_ledger_transaction_id IS NULL) = (credited_at IS NULL)
  ),
  CONSTRAINT deposits_credit_state_check CHECK (
    credited_at IS NULL
    OR (status = 'confirmed' AND confirmations >= required_confirmations)
  ),
  -- a failed deposit always says why (cancelled/orphaned/reorged fold in here)
  CONSTRAINT deposits_failed_reason_check CHECK (
    status <> 'failed' OR (failed_reason IS NOT NULL AND btrim(failed_reason) <> '')
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
CREATE INDEX IF NOT EXISTS deposits_source_idx ON public.deposits (source, status, detected_at DESC);

DROP TRIGGER IF EXISTS deposits_environment_gate ON public.deposits;
CREATE TRIGGER deposits_environment_gate
  BEFORE INSERT ON public.deposits
  FOR EACH ROW EXECUTE FUNCTION public.enforce_environment_gate();

COMMENT ON TABLE public.deposits IS
  'One row per observed inbound chain transaction: the owner''s state machine (pending/confirming/confirmed/failed/under review), confirmations, provider txid, the path that produced it (source) and the ledger transaction that credited it (credit data, not a status). Written only by record_deposit() (paper operator/test path) and record_provider_deposit() (live provider-adapter path) plus the operator transitions (service_role) — a client role has no write path, or a user could mint funds. Unique (environment, network, txid, log_index).';
COMMENT ON COLUMN public.deposits.source IS
  'Which path produced this row: paper_operator (operator/test harness, paper only) or provider_adapter (live chain-provider adapter, live only). Part of the row so paper and real deposits are distinguishable in the data; paired with environment by CHECK.';
COMMENT ON COLUMN public.deposits.status IS
  'pending | confirming | confirmed | failed | under review (owner-specified set). credited is NOT a status: credit is credited_ledger_transaction_id + credited_at on a confirmed row.';
COMMENT ON COLUMN public.deposits.log_index IS
  'Log/event index inside the txid; -1 for a native transfer that has no log. Part of the idempotency key, so a txid that carries several transfers keeps them apart.';
COMMENT ON COLUMN public.deposits.credited_ledger_transaction_id IS
  'The immutable double-entry transaction that credited this deposit. Write-once (trigger): a credit is never re-pointed, and only a confirmed row may carry it.';
COMMENT ON COLUMN public.deposits.failed_reason IS
  'Why the deposit is failed. Required whenever status = failed; the folded states record themselves here (e.g. ''cancelled: operator rejected'', ''orphaned: dropped from the mempool'', ''reorged: ...'').';
COMMENT ON COLUMN public.deposits.review_reason IS
  'Why an operator put the deposit under review. Set by set_deposit_under_review() (which requires a reason); kept after the hold is resolved as the audit trail.';
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
     OR NEW.source   <> OLD.source
     OR NEW.txid     <> OLD.txid
     OR NEW.log_index <> OLD.log_index
     OR NEW.amount_units <> OLD.amount_units
     OR NEW.required_confirmations <> OLD.required_confirmations THEN
    RAISE EXCEPTION
      'the chain identity of deposit % is immutable (user, asset, network, environment, source, txid, log_index, amount, required_confirmations can never change)',
      OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  -- the owner's state machine; every unlisted transition raises
  IF NEW.status <> OLD.status THEN
    v_allowed := CASE OLD.status
                   WHEN 'pending'      THEN NEW.status IN ('confirming', 'confirmed', 'failed', 'under review')
                   WHEN 'confirming'   THEN NEW.status IN ('confirmed', 'failed', 'under review')
                   WHEN 'under review' THEN NEW.status IN ('confirmed', 'failed')
                   -- a confirmed row may still be failed while it is uncredited
                   -- (that is the only way to reject a deposit that already met
                   -- its policy); deposits_credit_state_check blocks the credited
                   -- case, so a credited row can never leave confirmed
                   WHEN 'confirmed'    THEN NEW.status = 'failed'
                   ELSE false   -- failed is terminal
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

  IF OLD.credited_at IS NOT NULL AND NEW.credited_at IS DISTINCT FROM OLD.credited_at THEN
    RAISE EXCEPTION 'the credit timestamp of deposit % is immutable (%)',
      OLD.id, OLD.credited_at
      USING ERRCODE = 'check_violation';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS deposits_before_update ON public.deposits;
CREATE TRIGGER deposits_before_update
  BEFORE UPDATE ON public.deposits
  FOR EACH ROW EXECUTE FUNCTION public.deposits_before_update();

COMMENT ON FUNCTION public.deposits_before_update() IS
  'Implemented as a trigger: enforces the deposit state machine (pending/confirming/confirmed/failed/under review) and the immutability of the chain identity, of the credit data and of a monotone confirmation count. Financial statuses are only reachable through the SECURITY DEFINER entry points below — anon/authenticated have no UPDATE privilege on public.deposits at all.';

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
  'Reads the single app_settings row and raises when a deposit write is not allowed (live mode with deposits_enabled = false). Returns the mode deposits are written in. Called by every deposit entry point; the deposits table carries enforce_environment_gate as the independent second gate.';

-- ---------------------------------------------------------------------------
-- operator path 1: register a network and an address (nothing generated)
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

-- ---------------------------------------------------------------------------
-- operator path 2: record an observed inbound transaction (the two sources)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._deposit_ingest(
  p_source        text,
  p_user_id       uuid,
  p_asset_symbol  text,
  p_network       text,
  p_txid          text,
  p_amount_units  numeric,
  p_log_index     integer,
  p_address       text,
  p_memo          text,
  p_confirmations integer,
  p_raw           jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_asset uuid;
  v_env   text;
  v_mode  text;
  v_net   public.deposit_networks;
  v_id    uuid;
  v_log   integer := COALESCE(p_log_index, -1);
  v_conf  integer := COALESCE(p_confirmations, 0);
BEGIN
  IF p_source NOT IN ('paper_operator', 'provider_adapter') THEN
    RAISE EXCEPTION 'unknown deposit source %: only paper_operator (paper operator/test path) and provider_adapter (live chain-provider path) exist', p_source
      USING ERRCODE = 'check_violation';
  END IF;

  v_mode := public.app_mode();
  v_env  := CASE p_source WHEN 'provider_adapter' THEN 'live' ELSE 'paper' END;

  -- the two paths are mutually exclusive, in the data and in the mode: paper data can
  -- never enter through the adapter, an adapter event can never be recorded as paper.
  IF p_source = 'paper_operator' AND v_mode <> 'paper' THEN
    RAISE EXCEPTION 'the operator/test deposit path is paper-only: app_settings.mode is % (real deposits enter through the provider adapter via record_provider_deposit())', v_mode
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_source = 'provider_adapter' AND v_mode <> 'live' THEN
    RAISE EXCEPTION 'the provider adapter path is live-only: app_settings.mode is %, so no adapter event may be recorded (paper data never enters through the adapter)', v_mode
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM public.assert_deposits_enabled();

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
    user_id, asset_id, network, environment, source, address, memo, txid, log_index,
    amount_units, confirmations, required_confirmations, status, detected_at, raw
  )
  VALUES (
    p_user_id, v_asset, p_network, v_env, p_source, p_address, p_memo, btrim(p_txid), v_log,
    p_amount_units, v_conf, v_net.required_confirmations,
    CASE
      WHEN v_net.required_confirmations > 0 AND v_conf >= v_net.required_confirmations THEN 'confirmed'
      WHEN v_conf > 0 THEN 'confirming'
      ELSE 'pending'
    END,
    now(), COALESCE(p_raw, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION public._deposit_ingest(text, uuid, text, text, text, numeric, integer, text, text, integer, jsonb) IS
  'Internal (not an entry point): the shared body of the two deposit sources. Derives environment from source, refuses the wrong mode for the path, and writes the row. Callers: record_deposit() (paper) and record_provider_deposit() (live adapter).';

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
BEGIN
  RETURN public._deposit_ingest(
    'paper_operator', p_user_id, p_asset_symbol, p_network, p_txid, p_amount_units,
    p_log_index, p_address, p_memo, p_confirmations, p_raw
  );
END $$;

COMMENT ON FUNCTION public.record_deposit(uuid, text, text, text, numeric, integer, text, text, integer, jsonb) IS
  'Paper operator/test path: record an observed inbound transaction for a user as source = paper_operator in the paper environment (status pending, confirming or confirmed depending on the confirmations supplied). The txid is supplied by the caller — nothing is invented, and nothing here claims the deposit was verified on chain. Refused while app_settings.mode = live (real deposits enter through the provider adapter). Idempotent on (environment, network, txid, log_index). service_role only.';

CREATE OR REPLACE FUNCTION public.record_provider_deposit(p_event jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing  text;
  v_user     uuid;
  v_amount   numeric;
  v_log      integer;
  v_conf     integer;
BEGIN
  IF p_event IS NULL OR jsonb_typeof(p_event) <> 'object' THEN
    RAISE EXCEPTION 'provider adapter contract violation: the event must be a JSON object (got %)',
      COALESCE(jsonb_typeof(p_event), 'NULL')
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT string_agg(k, ', ' ORDER BY k)
    INTO v_missing
    FROM unnest(ARRAY['network', 'asset_symbol', 'user_id', 'txid', 'amount_units']) AS k
   WHERE NOT (p_event ? k);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'provider adapter contract violation: event is missing required key(s) % (required: network, asset_symbol, user_id, txid, amount_units; optional: log_index, confirmations, to_address, memo)',
      v_missing
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  BEGIN
    v_user := (p_event->>'user_id')::uuid;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'provider adapter contract violation: user_id is not a uuid (got %)', p_event->>'user_id'
      USING ERRCODE = 'invalid_parameter_value';
  END;

  BEGIN
    v_amount := (p_event->>'amount_units')::numeric;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'provider adapter contract violation: amount_units is not numeric (got %)', p_event->>'amount_units'
      USING ERRCODE = 'invalid_parameter_value';
  END;

  BEGIN
    v_log := COALESCE((p_event->>'log_index')::integer, -1);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'provider adapter contract violation: log_index is not an integer (got %)', p_event->>'log_index'
      USING ERRCODE = 'invalid_parameter_value';
  END;

  BEGIN
    v_conf := COALESCE((p_event->>'confirmations')::integer, 0);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'provider adapter contract violation: confirmations is not an integer (got %)', p_event->>'confirmations'
      USING ERRCODE = 'invalid_parameter_value';
  END;

  -- the live-only path: mode, the LIVE_DEPOSITS_ENABLED gate and the row's
  -- (source, environment) pairing are all checked below/in _deposit_ingest
  RETURN public._deposit_ingest(
    'provider_adapter', v_user, p_event->>'asset_symbol', p_event->>'network',
    p_event->>'txid', v_amount, v_log, p_event->>'to_address', p_event->>'memo',
    v_conf, p_event
  );
END $$;

COMMENT ON FUNCTION public.record_provider_deposit(jsonb) IS
  'Live chain-provider adapter path (the documented adapter contract): takes ONE normalised provider event as JSON (network, asset_symbol, user_id, txid, amount_units required; log_index, confirmations, to_address, memo optional; any extra provider fields are preserved in raw) and records it as source = provider_adapter in the LIVE environment. Refuses a malformed event as an adapter contract violation, refuses to run unless app_settings.mode = live (so paper data cannot enter through the adapter), passes the LIVE_DEPOSITS_ENABLED gate and the enforce_environment_gate trigger. No provider, credentials or address generation is part of this step. service_role only.';

-- ---------------------------------------------------------------------------
-- operator path 3: the state machine transitions
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

  IF v_dep.status = 'failed' THEN
    RAISE EXCEPTION 'deposit % is failed (terminal): its confirmations cannot be updated', v_dep.id
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
                    -- an operator hold is a decision, not a chain event: more
                    -- confirmations never release it
                    WHEN v_dep.status = 'under review' THEN 'under review'
                    WHEN v_dep.status = 'confirmed' THEN 'confirmed'
                    WHEN v_dep.required_confirmations > 0
                         AND p_confirmations >= v_dep.required_confirmations THEN 'confirmed'
                    WHEN p_confirmations > 0 THEN 'confirming'
                    ELSE v_dep.status
                  END
   WHERE id = v_dep.id
  RETURNING status INTO v_status;

  RETURN v_status;
END $$;

COMMENT ON FUNCTION public.set_deposit_confirmations(uuid, integer) IS
  'Operator/watcher path: record how many confirmations a deposit now has. Monotonic, refused on a failed deposit. Moves pending -> confirming -> confirmed as the confirmation policy is met (confirmed only from required_confirmations > 0); a deposit under review stays under review however many confirmations arrive. Returns the resulting status. service_role only.';

CREATE OR REPLACE FUNCTION public.confirm_deposit(p_deposit_id uuid)
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

  IF v_dep.status = 'confirmed' THEN
    RETURN 'confirmed';   -- idempotent
  END IF;

  IF v_dep.status = 'failed' THEN
    RAISE EXCEPTION 'deposit % is failed (terminal): it cannot be confirmed', v_dep.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_dep.required_confirmations <= 0 THEN
    RAISE EXCEPTION 'no confirmation policy is configured for deposit % (required_confirmations = 0 on its network configuration): refusing to confirm or credit it',
      v_dep.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_dep.confirmations < v_dep.required_confirmations THEN
    RAISE EXCEPTION 'deposit % has % of the % required confirmations: it cannot be confirmed yet',
      v_dep.id, v_dep.confirmations, v_dep.required_confirmations
      USING ERRCODE = 'check_violation';
  END IF;

  -- also the documented way out of an operator hold
  UPDATE public.deposits SET status = 'confirmed' WHERE id = v_dep.id
  RETURNING status INTO v_status;

  RETURN v_status;
END $$;

COMMENT ON FUNCTION public.confirm_deposit(uuid) IS
  'Operator path: confirm a deposit that has reached its confirmation policy (pending/confirming/under review -> confirmed), releasing an operator hold if one is open. Refuses a deposit below the policy, a network with no confirmation policy (required_confirmations = 0) and a failed deposit. Returns the resulting status. service_role only.';

CREATE OR REPLACE FUNCTION public.set_deposit_under_review(
  p_deposit_id uuid,
  p_reason     text
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

  IF v_dep.status = 'under review' THEN
    RETURN 'under review';   -- idempotent
  END IF;

  IF v_dep.status NOT IN ('pending', 'confirming') THEN
    RAISE EXCEPTION 'deposit % is %: only a pending or confirming deposit can be put under review', v_dep.id, v_dep.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'putting deposit % under operator review requires a reason', v_dep.id
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  UPDATE public.deposits
     SET status = 'under review',
         review_reason = btrim(p_reason)
   WHERE id = v_dep.id
  RETURNING status INTO v_status;

  RETURN v_status;
END $$;

COMMENT ON FUNCTION public.set_deposit_under_review(uuid, text) IS
  'Operator path: put a pending/confirming deposit under operator review (suspicious amount, unmatched address, ...) with a reason. Crediting is refused while the hold is open; resolve it with confirm_deposit() or fail_deposit(). service_role only.';

CREATE OR REPLACE FUNCTION public.fail_deposit(
  p_deposit_id uuid,
  p_reason     text
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

  IF v_dep.status = 'failed' THEN
    RAISE EXCEPTION 'deposit % is failed (terminal): it cannot be failed again', v_dep.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_dep.credited_ledger_transaction_id IS NOT NULL THEN
    RAISE EXCEPTION 'deposit % is already credited (ledger transaction %): it cannot be failed here — reversing a credit needs a compensating ledger transaction, which is not implemented in this step', v_dep.id, v_dep.credited_ledger_transaction_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'failing deposit % requires a reason (it is stored in failed_reason)', v_dep.id
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  -- the one terminal non-credit state: cancelled / orphaned / reorged / rejected all
  -- land here and say which in failed_reason
  UPDATE public.deposits
     SET status = 'failed',
         failed_reason = btrim(p_reason)
   WHERE id = v_dep.id
  RETURNING status INTO v_status;

  RETURN v_status;
END $$;

COMMENT ON FUNCTION public.fail_deposit(uuid, text) IS
  'Operator/watcher path: move a deposit to its single terminal non-credit state, failed, with a mandatory reason (cancelled, orphaned, reorged and rejected fold into this one state — the reason says which). Allowed from pending, confirming, under review and from a confirmed row that has NOT been credited (the only way to reject a deposit that already met its policy). Refused on a credited row: reversing a credit needs a compensating ledger transaction, not implemented yet. service_role only.';

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
  IF v_dep.credited_ledger_transaction_id IS NOT NULL THEN
    RAISE EXCEPTION 'deposit % is already credited by ledger transaction %: a chain transaction can never be credited twice',
      v_dep.id, v_dep.credited_ledger_transaction_id
      USING ERRCODE = 'unique_violation';
  END IF;

  IF v_dep.status = 'failed' THEN
    RAISE EXCEPTION 'deposit % is failed (%) : a failed deposit can never be credited', v_dep.id, v_dep.failed_reason
      USING ERRCODE = 'check_violation';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.deposits d
     WHERE d.environment = v_dep.environment AND d.network = v_dep.network
       AND d.txid = v_dep.txid AND d.log_index = v_dep.log_index
       AND d.credited_ledger_transaction_id IS NOT NULL AND d.id <> v_dep.id
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

  IF v_dep.required_confirmations <= 0 OR v_net.required_confirmations <= 0 THEN
    RAISE EXCEPTION 'no confirmation policy is configured for % on % in % (required_confirmations = %, deposit snapshot %): refusing to credit a deposit nobody set a confirmation policy for',
      v_dep.asset_id, v_dep.network, v_dep.environment, v_net.required_confirmations, v_dep.required_confirmations
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_dep.amount_units < v_net.min_deposit_units THEN
    RAISE EXCEPTION 'deposit % of % base units is below the configured minimum of % for % on %',
      v_dep.id, v_dep.amount_units, v_net.min_deposit_units, v_dep.asset_id, v_dep.network
      USING ERRCODE = 'check_violation';
  END IF;

  -- credit is only allowed from `confirmed`
  IF v_dep.status <> 'confirmed' THEN
    IF v_dep.status = 'under review' THEN
      RAISE EXCEPTION 'deposit % is under review (%): crediting is refused while the operator hold is open — resolve it with confirm_deposit() or fail_deposit()',
        v_dep.id, COALESCE(v_dep.review_reason, 'no reason recorded')
        USING ERRCODE = 'check_violation';
    ELSIF v_dep.status IN ('pending', 'confirming') AND v_dep.confirmations < v_dep.required_confirmations THEN
      RAISE EXCEPTION 'deposit % has % of the % required confirmations: not creditable yet (only a confirmed deposit can be credited)',
        v_dep.id, v_dep.confirmations, v_dep.required_confirmations
        USING ERRCODE = 'check_violation';
    ELSE
      RAISE EXCEPTION 'deposit % is %: only a confirmed deposit can be credited',
        v_dep.id, v_dep.status
        USING ERRCODE = 'check_violation';
    END IF;
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
      'amount_units', v_dep.amount_units,
      'source', v_dep.source
    )
  )
  RETURNING id INTO v_tx;

  PERFORM public.post_entry(v_tx, v_user,  v_dep.amount_units, 'deposit ' || v_dep.txid);
  PERFORM public.post_entry(v_tx, v_clear, -v_dep.amount_units, 'deposit clearing ' || v_dep.txid);

  -- credit data, not a status change: the row stays confirmed
  UPDATE public.deposits
     SET credited_ledger_transaction_id = v_tx,
         credited_at = now()
   WHERE id = v_dep.id;

  RETURN v_tx;
END $$;

COMMENT ON FUNCTION public.credit_deposit(uuid) IS
  'Operator path: credit a confirmed deposit. Posts one immutable deposit_credit ledger transaction (user available += amount, EXTERNAL_DEPOSIT system account -= amount) and writes the credit data (credited_ledger_transaction_id + credited_at) on the still-confirmed row in the same transaction, so the deferred ledger invariants hold or nothing happens. Refuses: an already credited deposit, a failed deposit, a deposit under operator review, a deposit below its confirmation policy, a disabled network, a network with no minimum or no confirmation policy configured, a below-minimum amount and double credits (row lock + explicit guard + ledger idempotency key). service_role only.';

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
         'record_deposit', 'record_provider_deposit', '_deposit_ingest',
         'set_deposit_confirmations', 'confirm_deposit', 'set_deposit_under_review',
         'fail_deposit', 'credit_deposit'
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
