/*
# Migration 10/10 — withdrawal networks, withdrawal state machine, hold/settle/release and
# the provider-adapter contract

Purpose
-------
The database layer of the withdrawal path for BTC / ETH / USDT / SOL: the configuration,
the state machine, the money rules (hold on approval, settle on completion, release on
failure/rejection) and the contract a (future) live blockchain-provider adapter must
satisfy. **No chain integration, no address generation, no whitelist service, no external
provider, no credentials, no seeded data of any kind.** Every destination address in this
step is supplied by the operator; nothing here invents an address, a txid or a fee.

Statuses (the owner's set, 2026-10-18 — these seven and no others)
------------------------------------------------------------------
    pending, under review, approved, processing, completed, failed, rejected

    pending       requested, nothing is locked yet
    under review  operator hold (manual review of the destination/amount); nothing is
                  locked yet
    approved      the request is accepted and the money is LOCKED (available -> locked)
    processing    broadcast/execution in progress (a provider txid may be recorded)
    completed     terminal: the withdrawal was posted through the ledger (settled);
                  the locked amount is consumed and the clearing account carries it
    failed        terminal: the withdrawal will not happen / did not settle; any hold is
                  RELEASED back to available. Always carries failure_reason
    rejected      terminal: an operator refused the request; any hold is RELEASED back
                  to available. Always carries failure_reason

Why `failed` and `rejected` are two states: they say different things about who stopped
it — `rejected` is an operator decision on a request that will never be sent, `failed` is
a withdrawal that went further (approved or even broadcast) and could not be completed.
Both release the hold exactly (see below), so the money outcome is identical.

    state machine (enforced by the withdrawal_requests_before_update trigger)
        pending      --> under review | approved | rejected | failed
        under review --> approved | rejected | failed
        approved     --> processing | failed
        processing   --> completed | failed
        completed    --> (terminal)
        failed       --> (terminal)
        rejected     --> (terminal)

    Ambiguities in the requested machine, flagged rather than decided silently:
    * The requested shape reads "pending -> under review -> approved", which can also be
      read as "review is mandatory". This migration allows BOTH pending -> approved
      (straight through) and pending -> under review -> approved. Whether review is
      mandatory for every withdrawal (or only above a threshold) is an OWNER policy
      decision and is not invented here.
    * approved -> completed (skipping processing) is refused: the requested machine has a
      processing step and completion means "the chain transaction is final". An exchange
      that wants instant withdrawals should still pass through processing.
    * failed is reachable from pending/under review too, so a request that is dropped
      before approval has a terminal state that is not `rejected` (e.g. the user's
      network was disabled while the request was open).
    * Nothing here chooses an OPERATOR WORKFLOW (who reviews, quorum, SLA). That is the
      admin/operator-controls step.

Money rules (hold / settle / release)
-------------------------------------
The hold pattern is the order book's, reused verbatim at the account level:

* APPROVAL LOCKS THE FUNDS. `approve_withdrawal()` posts one `withdrawal_request` ledger
  transaction: the user's `available` account is debited `amount_units + fee_units` and
  the user's `locked` account is credited the same amount (both postings in one
  transaction, so the deferred ledger invariants of migration 3 hold or nothing
  happens). The request carries `hold_ledger_transaction_id`.
* COMPLETION SETTLES. `complete_withdrawal()` posts one `withdrawal_settle` transaction:
  the user's `locked` account is debited `amount_units + fee_units`, the per
  (asset, environment) `WITHDRAWAL_CLEARING` system account is credited `amount_units`
  (the money that left the exchange) and, when the fee is non-zero, the `FEE_INCOME`
  system account is credited `fee_units`. Zero-sum per asset by construction.
* FAILURE / REJECTION RELEASES EXACTLY THE HOLD. `fail_withdrawal()` and
  `reject_withdrawal()` post one `withdrawal_refund` transaction: the user's `locked`
  account is debited and the user's `available` account is credited the full held
  amount, and the release is recorded on the row (`released_ledger_transaction_id`).
  A request that was rejected before approval never locked anything, so it releases
  nothing (`hold_ledger_transaction_id` and `released_ledger_transaction_id` stay NULL).
  In both cases the user's `locked` balance ends at exactly 0 for that request: there is
  no stranded-locked path, because the only debit of the locked account is the release
  or the settlement, and both are terminal.
* A COMPLETED (or failed/rejected) row is IMMUTABLE: the trigger refuses every update of
  a terminal row, the chain identity (user, asset, network, environment, source,
  destination, amount, fee) can never change on any row, and the hold/settle/release
  ledger ids are write-once.

Fee model (exactly this, nothing else)
--------------------------------------
Per (asset, network, environment) in `withdrawal_networks`:

    fee_units = withdrawal_fee_flat_units
                + floor(amount_units * withdrawal_fee_rate_bps / 10000)

i.e. a FLAT fee in base units plus a PROPORTIONAL fee in basis points of the requested
amount, rounded DOWN to a whole base unit (integer arithmetic only, no float). Either one
may be zero; the two are additive. The fee is charged ON TOP of the requested amount: a
withdrawal of 1,000,000 units with a flat fee of 1,000 and 50 bps costs the user
1,000 + 5,000 = 6,000 units of fee, so 1,006,000 units are locked and 1,000,000 leave the
exchange. The fee is SNAPSHOTTED on the request at creation (`fee_units`), so a later
configuration change never changes the money on an existing request.

Minimum/maximum: `min_withdrawal_units` / `max_withdrawal_units` are NOT NULL (a network
cannot be registered without limits — unlike deposits, where NULL means "not configured";
here the request would otherwise have no bound at all). They bound the REQUESTED amount,
not amount+fee.

Paper vs real: two paths, distinguishable in the data
-----------------------------------------------------
`withdrawal_requests.source` + `environment` say which path produced a row, the pairing is
pinned by CHECK and each entry point refuses the other mode:

| source             | environment | entry point                 | who calls it                         |
|--------------------|-------------|-----------------------------|--------------------------------------|
| `paper_operator`   | `paper`     | `record_withdrawal_request()` | operator / test harness (paper only) |
| `provider_adapter` | `live`      | `record_provider_withdrawal()` | the live chain-provider adapter    |

Gating (paper mode vs live), same two-switch shape as deposits
--------------------------------------------------------------
* The LIVE path is double-gated: `assert_withdrawals_enabled()` reads
  `app_settings.withdrawals_enabled` (the DB side of the plan's `LIVE_WITHDRAWALS_ENABLED`)
  and the `enforce_environment_gate` trigger refuses a live row independently (this
  migration extends that trigger's table map with `withdrawal_requests` -> the
  `withdrawals` flag; every other table keeps its previous mapping).
* The PAPER path is gated by `app_settings.paper_withdrawals_enabled` (new column, NOT
  NULL DEFAULT **true** — paper is the non-money sandbox, so it starts open).
  `assert_paper_withdrawals_enabled()` is the only place that switch is read.
  NOTE (deliberate): it gates paper request creation, paper approval (holding money) and
  paper settlement — but NOT `reject_withdrawal()` / `fail_withdrawal()`, so switching the
  sandbox off can never trap funds that are already locked.

Provider adapter contract (the interface the live path depends on)
------------------------------------------------------------------
`record_provider_withdrawal(p_event jsonb) RETURNS uuid`; nothing else in this layer reads
provider-specific data.

    { "network":             "bitcoin",       -- required, text (withdrawal_networks.network)
      "asset_symbol":        "BTC",           -- required, text (assets.symbol)
      "user_id":             "<uuid>",        -- required, owner resolved by the adapter
      "destination_address": "<chain addr>",  -- required, supplied by the operator/adapter
      "amount_units":        100000,          -- required, base units (whole number > 0)
      "destination_tag":     null,            -- optional, memo/tag where the network needs one
      "memo":                null,            -- optional, free text
      "provider_txid":       "<tx hash>",     -- optional at record time
      ... any further provider fields are preserved verbatim in withdrawal_requests.raw }

A missing required key, a non-object event, a non-numeric amount or a blank destination is
refused as an *adapter contract violation* (`invalid_parameter_value`) and NOTHING is
recorded. The adapter itself (broadcasting, key management, signing, polling) is NOT
implemented in this step.

Deliberately NOT implemented in this step (flagged for the owner)
-----------------------------------------------------------------
* Destination Address Whitelisting / allow-lists per user, address-format validation per
  chain, travel-rule data, and "first withdrawal to a new address needs a delay". The only
  destination validation here is: non-blank, no whitespace, 4..200 chars, and the
  (asset, network) pair must be a registered withdrawal network. **Whitelisting is a
  deliberate future decision** — the column and the transition path it needs (an operator
  hold via `under review`) exist, the policy does not.
* A `withdrawal_release` ledger transaction type: the ledger's type set (migration 3)
  already contains `withdrawal_request`, `withdrawal_settle` and `withdrawal_refund` but
  has no `withdrawal_release`, and adding one means altering that CHECK. The hold release
  therefore posts as `withdrawal_refund` and says what it is in `description`/`metadata`
  (`reason`, `released_units`). Flagged, not invented.
* Fee accounting beyond `FEE_INCOME` (e.g. network fee vs service fee split, fee refunds).
*/

-- ---------------------------------------------------------------------------
-- withdrawal_networks — supported (asset, network) withdrawal configuration
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.withdrawal_networks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  network text NOT NULL,
  environment text NOT NULL DEFAULT 'paper',
  chain_id bigint,
  requires_memo boolean NOT NULL DEFAULT false,
  min_withdrawal_units numeric(38, 0) NOT NULL,
  max_withdrawal_units numeric(38, 0) NOT NULL,
  withdrawal_fee_flat_units numeric(38, 0) NOT NULL DEFAULT 0,
  withdrawal_fee_rate_bps integer NOT NULL DEFAULT 0,
  withdrawal_enabled boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT withdrawal_networks_network_check CHECK (network ~ '^[a-z0-9][a-z0-9._-]{1,31}$'),
  CONSTRAINT withdrawal_networks_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT withdrawal_networks_min_units_check CHECK (
    min_withdrawal_units > 0 AND min_withdrawal_units = trunc(min_withdrawal_units)
  ),
  CONSTRAINT withdrawal_networks_max_units_check CHECK (
    max_withdrawal_units > 0 AND max_withdrawal_units = trunc(max_withdrawal_units)
    AND max_withdrawal_units >= min_withdrawal_units
  ),
  CONSTRAINT withdrawal_networks_flat_fee_check CHECK (
    withdrawal_fee_flat_units >= 0 AND withdrawal_fee_flat_units = trunc(withdrawal_fee_flat_units)
  ),
  CONSTRAINT withdrawal_networks_rate_check CHECK (withdrawal_fee_rate_bps BETWEEN 0 AND 10000)
);

-- the (asset, network, environment) triple is the configuration key and the target of
-- the composite FK from withdrawal_requests
CREATE UNIQUE INDEX IF NOT EXISTS withdrawal_networks_key
  ON public.withdrawal_networks (asset_id, network, environment);

DROP TRIGGER IF EXISTS withdrawal_networks_set_updated_at ON public.withdrawal_networks;
CREATE TRIGGER withdrawal_networks_set_updated_at
  BEFORE UPDATE ON public.withdrawal_networks
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

COMMENT ON TABLE public.withdrawal_networks IS
  'Which (asset, network) pairs can be withdrawn from, per environment: minimum/maximum requested amount, the two-part fee model (flat + basis points), the memo/tag requirement and the withdrawal_enabled switch. Operator configuration — never seeded, and a withdrawal can only be requested on a registered, enabled network.';
COMMENT ON COLUMN public.withdrawal_networks.network IS
  'Chain/network identifier as it appears on the chain: bitcoin, ethereum, tron, solana, ... (USDT exists on several, so the asset symbol alone is not enough). Distinct from assets.chain, which is the asset''s home chain.';
COMMENT ON COLUMN public.withdrawal_networks.min_withdrawal_units IS
  'Smallest REQUESTED amount (not amount+fee) in base units. NOT NULL: a withdrawal network without limits cannot be registered.';
COMMENT ON COLUMN public.withdrawal_networks.max_withdrawal_units IS
  'Largest REQUESTED amount (not amount+fee) in base units. NOT NULL, and never below the minimum.';
COMMENT ON COLUMN public.withdrawal_networks.withdrawal_fee_flat_units IS
  'Flat part of the withdrawal fee, in base units, charged on top of the requested amount. 0 = no flat fee.';
COMMENT ON COLUMN public.withdrawal_networks.withdrawal_fee_rate_bps IS
  'Proportional part of the withdrawal fee in basis points (10000 = 100%) of the requested amount, rounded DOWN to whole base units. 0 = no proportional fee. Combined fee = flat + floor(amount * rate_bps / 10000).';
COMMENT ON COLUMN public.withdrawal_networks.requires_memo IS
  'When true, every withdrawal on this network must carry a destination tag/memo.';

-- ---------------------------------------------------------------------------
-- withdrawal_requests — one row per withdrawal request, its state and its money
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.withdrawal_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  asset_id uuid NOT NULL,
  network text NOT NULL,
  environment text NOT NULL,
  source text NOT NULL DEFAULT 'paper_operator',
  destination_address text NOT NULL,
  destination_tag text,
  memo text,
  amount_units numeric(38, 0) NOT NULL,
  fee_units numeric(38, 0) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'pending',
  provider_txid text,
  hold_ledger_transaction_id uuid REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  settled_ledger_transaction_id uuid REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  released_ledger_transaction_id uuid REFERENCES public.ledger_transactions(id) ON DELETE RESTRICT,
  failure_reason text,
  review_reason text,
  raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  requested_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  processing_at timestamptz,
  completed_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT withdrawal_requests_destination_check CHECK (
    length(btrim(destination_address)) BETWEEN 4 AND 200 AND destination_address !~ '\s'
  ),
  CONSTRAINT withdrawal_requests_amount_check CHECK (
    amount_units > 0 AND amount_units = trunc(amount_units)
  ),
  CONSTRAINT withdrawal_requests_fee_check CHECK (
    fee_units >= 0 AND fee_units = trunc(fee_units)
  ),
  CONSTRAINT withdrawal_requests_txid_check CHECK (
    provider_txid IS NULL OR length(btrim(provider_txid)) BETWEEN 1 AND 140
  ),
  CONSTRAINT withdrawal_requests_status_check CHECK (status IN (
    'pending', 'under review', 'approved', 'processing', 'completed', 'failed', 'rejected'
  )),
  -- which path produced the row is part of the row, and the two paths cannot mix
  CONSTRAINT withdrawal_requests_source_check CHECK (source IN ('paper_operator', 'provider_adapter')),
  CONSTRAINT withdrawal_requests_source_environment_check CHECK (
    (source = 'provider_adapter') = (environment = 'live')
  ),
  -- a completed withdrawal always says which chain transaction settled it
  CONSTRAINT withdrawal_requests_completed_txid_check CHECK (
    status <> 'completed' OR provider_txid IS NOT NULL
  ),
  -- the money data of a request is a function of its status, both ways
  CONSTRAINT withdrawal_requests_hold_check CHECK (
    status NOT IN ('approved', 'processing', 'completed')
    OR hold_ledger_transaction_id IS NOT NULL
  ),
  CONSTRAINT withdrawal_requests_settled_check CHECK (
    (status = 'completed') = (settled_ledger_transaction_id IS NOT NULL)
  ),
  CONSTRAINT withdrawal_requests_released_check CHECK (
    status IN ('failed', 'rejected') OR released_ledger_transaction_id IS NULL
  ),
  -- a hold can only disappear by being released (never by editing the row)
  CONSTRAINT withdrawal_requests_hold_released_check CHECK (
    status NOT IN ('failed', 'rejected')
    OR hold_ledger_transaction_id IS NULL
    OR released_ledger_transaction_id IS NOT NULL
  ),
  CONSTRAINT withdrawal_requests_approved_at_check CHECK (
    (status IN ('approved', 'processing', 'completed')) = (approved_at IS NOT NULL)
  ),
  CONSTRAINT withdrawal_requests_processing_at_check CHECK (
    (status IN ('processing', 'completed')) = (processing_at IS NOT NULL)
  ),
  CONSTRAINT withdrawal_requests_completed_at_check CHECK (
    (status = 'completed') = (completed_at IS NOT NULL)
  ),
  CONSTRAINT withdrawal_requests_closed_at_check CHECK (
    (status IN ('failed', 'rejected')) = (closed_at IS NOT NULL)
  ),
  CONSTRAINT withdrawal_requests_failure_reason_check CHECK (
    status NOT IN ('failed', 'rejected')
    OR (failure_reason IS NOT NULL AND btrim(failure_reason) <> '')
  ),
  CONSTRAINT withdrawal_requests_network_fkey
    FOREIGN KEY (asset_id, network, environment)
    REFERENCES public.withdrawal_networks (asset_id, network, environment)
    ON UPDATE RESTRICT ON DELETE RESTRICT
);

-- guard #1 of the idempotency: one provider txid per environment/network settles ONE
-- withdrawal, ever — a replayed or duplicated broadcast cannot post a second settlement
CREATE UNIQUE INDEX IF NOT EXISTS withdrawal_requests_provider_txid_key
  ON public.withdrawal_requests (environment, network, provider_txid)
  WHERE provider_txid IS NOT NULL;

CREATE INDEX IF NOT EXISTS withdrawal_requests_user_idx
  ON public.withdrawal_requests (user_id, requested_at DESC);
CREATE INDEX IF NOT EXISTS withdrawal_requests_status_idx
  ON public.withdrawal_requests (environment, status, requested_at DESC);
CREATE INDEX IF NOT EXISTS withdrawal_requests_hold_idx
  ON public.withdrawal_requests (hold_ledger_transaction_id);
CREATE INDEX IF NOT EXISTS withdrawal_requests_settled_idx
  ON public.withdrawal_requests (settled_ledger_transaction_id);
CREATE INDEX IF NOT EXISTS withdrawal_requests_source_idx
  ON public.withdrawal_requests (source, status, requested_at DESC);

DROP TRIGGER IF EXISTS withdrawal_requests_environment_gate ON public.withdrawal_requests;
CREATE TRIGGER withdrawal_requests_environment_gate
  BEFORE INSERT ON public.withdrawal_requests
  FOR EACH ROW EXECUTE FUNCTION public.enforce_environment_gate();

COMMENT ON TABLE public.withdrawal_requests IS
  'One row per withdrawal request: the owner''s seven-state machine, the requested amount, the fee snapshot, the destination supplied by the operator, the provider txid and the three ledger transactions that hold, settle or release the money. Written only by record_withdrawal_request() (paper operator/test path), record_provider_withdrawal() (live provider-adapter path) and the operator transitions (service_role) — a client role has no write path, or a user could pay themselves. Unique (environment, network, provider_txid).';
COMMENT ON COLUMN public.withdrawal_requests.source IS
  'Which path produced this row: paper_operator (operator/test harness, paper only) or provider_adapter (live chain-provider adapter, live only). Paired with environment by CHECK.';
COMMENT ON COLUMN public.withdrawal_requests.status IS
  'pending | under review | approved | processing | completed | failed | rejected. approved means the funds are locked; completed/failed/rejected are terminal and immutable.';
COMMENT ON COLUMN public.withdrawal_requests.amount_units IS
  'Requested amount in base units — the money that leaves the exchange. The fee is separate (fee_units) and is locked on top of it.';
COMMENT ON COLUMN public.withdrawal_requests.fee_units IS
  'Fee snapshot at request time, in base units: withdrawal_fee_flat_units + floor(amount * withdrawal_fee_rate_bps / 10000). amount_units + fee_units is what is locked on approval and settled on completion.';
COMMENT ON COLUMN public.withdrawal_requests.provider_txid IS
  'The chain transaction that broadcasts/settles this withdrawal. Write-once; UNIQUE (environment, network, provider_txid), so a transaction can never settle two withdrawals. Required before completion.';
COMMENT ON COLUMN public.withdrawal_requests.hold_ledger_transaction_id IS
  'The withdrawal_request ledger transaction that locked amount+fee (available -> locked) at approval. Write-once.';
COMMENT ON COLUMN public.withdrawal_requests.settled_ledger_transaction_id IS
  'The withdrawal_settle ledger transaction that consumed the hold and credited the WITHDRAWAL_CLEARING account (plus FEE_INCOME). Write-once, and only ever present on a completed row.';
COMMENT ON COLUMN public.withdrawal_requests.released_ledger_transaction_id IS
  'The withdrawal_refund ledger transaction that returned the hold to available on failure/rejection. Write-once. The ledger has no withdrawal_release type (see the migration header), so the release posts as withdrawal_refund and names itself in description/metadata.';
COMMENT ON COLUMN public.withdrawal_requests.failure_reason IS
  'Why the request is failed or rejected. Required whenever status is failed or rejected.';
COMMENT ON COLUMN public.withdrawal_requests.destination_address IS
  'Destination supplied by the operator (paper) or the adapter (live). Nothing here generates or verifies a chain address, and no allow-list is implemented in this step.';

-- ---------------------------------------------------------------------------
-- immutability + state machine of a withdrawal request
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.withdrawal_requests_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_allowed boolean;
BEGIN
  -- terminal rows are immutable: a settled/closed withdrawal can never be edited,
  -- re-pointed or moved again
  IF OLD.status IN ('completed', 'failed', 'rejected') THEN
    RAISE EXCEPTION
      'withdrawal % is % (terminal): a completed, failed or rejected withdrawal is immutable',
      OLD.id, OLD.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.user_id     <> OLD.user_id
     OR NEW.asset_id <> OLD.asset_id
     OR NEW.network  <> OLD.network
     OR NEW.environment <> OLD.environment
     OR NEW.source   <> OLD.source
     OR NEW.destination_address IS DISTINCT FROM OLD.destination_address
     OR NEW.destination_tag IS DISTINCT FROM OLD.destination_tag
     OR NEW.amount_units <> OLD.amount_units
     OR NEW.fee_units <> OLD.fee_units THEN
    RAISE EXCEPTION
      'the identity of withdrawal % is immutable (user, asset, network, environment, source, destination, amount and fee can never change: reject it and create a new request instead)',
      OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  IF OLD.provider_txid IS NOT NULL AND NEW.provider_txid IS DISTINCT FROM OLD.provider_txid THEN
    RAISE EXCEPTION 'the provider txid of withdrawal % is write-once (% -> %)',
      OLD.id, OLD.provider_txid, NEW.provider_txid
      USING ERRCODE = 'check_violation';
  END IF;

  -- the state machine; every unlisted transition raises
  IF NEW.status <> OLD.status THEN
    v_allowed := CASE OLD.status
                   WHEN 'pending'      THEN NEW.status IN ('under review', 'approved', 'rejected', 'failed')
                   WHEN 'under review' THEN NEW.status IN ('approved', 'rejected', 'failed')
                   WHEN 'approved'     THEN NEW.status IN ('processing', 'failed')
                   WHEN 'processing'   THEN NEW.status IN ('completed', 'failed')
                   ELSE false   -- completed / failed / rejected are terminal
                 END;
    IF NOT v_allowed THEN
      RAISE EXCEPTION 'illegal withdrawal status transition on withdrawal %: % -> % (% is terminal or the step is not part of the state machine)',
        OLD.id, OLD.status, NEW.status, OLD.status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  -- the three money pointers are write-once
  IF OLD.hold_ledger_transaction_id IS NOT NULL
     AND NEW.hold_ledger_transaction_id IS DISTINCT FROM OLD.hold_ledger_transaction_id THEN
    RAISE EXCEPTION 'the hold ledger transaction of withdrawal % is immutable', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.settled_ledger_transaction_id IS NOT NULL
     AND NEW.settled_ledger_transaction_id IS DISTINCT FROM OLD.settled_ledger_transaction_id THEN
    RAISE EXCEPTION 'the settlement ledger transaction of withdrawal % is immutable', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  IF OLD.released_ledger_transaction_id IS NOT NULL
     AND NEW.released_ledger_transaction_id IS DISTINCT FROM OLD.released_ledger_transaction_id THEN
    RAISE EXCEPTION 'the release ledger transaction of withdrawal % is immutable', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS withdrawal_requests_before_update ON public.withdrawal_requests;
CREATE TRIGGER withdrawal_requests_before_update
  BEFORE UPDATE ON public.withdrawal_requests
  FOR EACH ROW EXECUTE FUNCTION public.withdrawal_requests_before_update();

COMMENT ON FUNCTION public.withdrawal_requests_before_update() IS
  'Implemented as a trigger: enforces the withdrawal state machine (pending/under review/approved/processing/completed/failed/rejected), the immutability of the request identity, of the provider txid and of the hold/settle/release ledger pointers, and the total immutability of a terminal row. Financial statuses are only reachable through the SECURITY DEFINER entry points below — anon/authenticated have no UPDATE privilege on public.withdrawal_requests at all.';

-- ---------------------------------------------------------------------------
-- the environment gate: teach enforce_environment_gate about withdrawal_requests
--
-- Migration 1 maps the table name `withdrawals` to app_settings.withdrawals_enabled and
-- every other money table to the trading flag. The withdrawal table is named
-- `withdrawal_requests`, so without this branch a live withdrawal row would be gated by
-- live_trading_enabled. The function is replaced with ONE added branch; every existing
-- mapping (deposits/withdrawals/trading) is byte-for-byte the previous behaviour.
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
                 WHEN 'withdrawal_requests' THEN 'withdrawals'
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

-- ---------------------------------------------------------------------------
-- the two switches
-- ---------------------------------------------------------------------------
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS paper_withdrawals_enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.app_settings.paper_withdrawals_enabled IS
  'Paper-sandbox withdrawal switch, default true. Gates paper request creation, paper approval (holding money) and paper settlement with a distinct message; it deliberately does NOT gate reject_withdrawal()/fail_withdrawal(), so switching the sandbox off can never trap funds that are already locked. The live path is gated by mode = live AND withdrawals_enabled instead.';

CREATE OR REPLACE FUNCTION public.assert_withdrawals_enabled()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_mode text;
  v_flag boolean;
BEGIN
  SELECT mode, withdrawals_enabled
    INTO v_mode, v_flag
    FROM public.app_settings
   WHERE id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'app_settings has no row: the withdrawal gate cannot be evaluated'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_mode = 'live' AND NOT COALESCE(v_flag, false) THEN
    RAISE EXCEPTION
      'live withdrawals are disabled: app_settings.mode = live but withdrawals_enabled = false; refusing to move funds'
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN v_mode;
END $$;

COMMENT ON FUNCTION public.assert_withdrawals_enabled() IS
  'Reads the single app_settings row and raises when a withdrawal write is not allowed (live mode with withdrawals_enabled = false). Returns the mode withdrawals are written in. Called by every withdrawal entry point and transition; the withdrawal_requests table carries enforce_environment_gate as the independent second gate.';

CREATE OR REPLACE FUNCTION public.assert_paper_withdrawals_enabled()
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_paper boolean;
BEGIN
  SELECT paper_withdrawals_enabled
    INTO v_paper
    FROM public.app_settings
   WHERE id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'app_settings has no row: the paper withdrawal gate cannot be evaluated'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT COALESCE(v_paper, false) THEN
    RAISE EXCEPTION
      'paper withdrawals are disabled: app_settings.paper_withdrawals_enabled = false; refusing to record or settle paper withdrawals (the paper sandbox switch, independent of the live withdrawals_enabled gate — releases are still allowed)'
      USING ERRCODE = 'check_violation';
  END IF;
END $$;

COMMENT ON FUNCTION public.assert_paper_withdrawals_enabled() IS
  'Reads app_settings.paper_withdrawals_enabled and raises when paper withdrawals are switched off. Called by the paper path only: _withdrawal_ingest (paper source), approve_withdrawal() and complete_withdrawal() of a paper row. Deliberately NOT called by the release paths (reject/fail) — locked funds must always be releasable.';

-- ---------------------------------------------------------------------------
-- operator path 1: register a withdrawal network (no data seeded)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_withdrawal_network(
  p_asset_symbol           text,
  p_network                text,
  p_min_withdrawal_units   numeric,
  p_max_withdrawal_units   numeric,
  p_fee_flat_units         numeric DEFAULT 0,
  p_fee_rate_bps           integer DEFAULT 0,
  p_requires_memo          boolean DEFAULT false,
  p_chain_id               bigint  DEFAULT NULL,
  p_withdrawal_enabled     boolean DEFAULT false
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

  IF p_min_withdrawal_units IS NULL OR p_max_withdrawal_units IS NULL THEN
    RAISE EXCEPTION 'withdrawal network %/% needs both a minimum and a maximum (% / %): a network without limits cannot be registered',
      p_asset_symbol, p_network, p_min_withdrawal_units, p_max_withdrawal_units
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  INSERT INTO public.withdrawal_networks AS wn (
    asset_id, network, environment, chain_id, requires_memo, min_withdrawal_units,
    max_withdrawal_units, withdrawal_fee_flat_units, withdrawal_fee_rate_bps,
    withdrawal_enabled
  )
  VALUES (
    v_asset, p_network, v_env, p_chain_id, COALESCE(p_requires_memo, false),
    p_min_withdrawal_units, p_max_withdrawal_units, COALESCE(p_fee_flat_units, 0),
    COALESCE(p_fee_rate_bps, 0), COALESCE(p_withdrawal_enabled, false)
  )
  ON CONFLICT (asset_id, network, environment) DO UPDATE
     SET chain_id                 = EXCLUDED.chain_id,
         requires_memo            = EXCLUDED.requires_memo,
         min_withdrawal_units     = EXCLUDED.min_withdrawal_units,
         max_withdrawal_units     = EXCLUDED.max_withdrawal_units,
         withdrawal_fee_flat_units = EXCLUDED.withdrawal_fee_flat_units,
         withdrawal_fee_rate_bps  = EXCLUDED.withdrawal_fee_rate_bps,
         withdrawal_enabled       = EXCLUDED.withdrawal_enabled
  RETURNING wn.id INTO v_id;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION public.register_withdrawal_network(text, text, numeric, numeric, numeric, integer, boolean, bigint, boolean) IS
  'Operator path: create or reconfigure an (asset, network) withdrawal configuration in the current environment (app_mode()): min/max requested amount, flat fee in base units, proportional fee in basis points, memo requirement, enabled switch. Upsert by (asset, network, environment). No withdrawal is created. service_role only.';

-- ---------------------------------------------------------------------------
-- fee model, in one place: flat + floor(amount * bps / 10000)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._withdrawal_fee_units(
  p_asset_id      uuid,
  p_network       text,
  p_environment   text,
  p_amount_units  numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_net public.withdrawal_networks;
BEGIN
  SELECT * INTO v_net
    FROM public.withdrawal_networks
   WHERE asset_id = p_asset_id AND network = p_network AND environment = p_environment;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'withdrawal network % is not registered for asset % in %',
      p_network, p_asset_id, p_environment
      USING ERRCODE = 'no_data_found';
  END IF;
  IF p_amount_units IS NULL OR p_amount_units <= 0 THEN
    RAISE EXCEPTION 'withdrawal amount must be positive (got %)', p_amount_units
      USING ERRCODE = 'check_violation';
  END IF;

  -- integer division floors, which is exactly the documented rounding
  RETURN v_net.withdrawal_fee_flat_units
         + floor((p_amount_units * v_net.withdrawal_fee_rate_bps) / 10000);
END $$;

COMMENT ON FUNCTION public._withdrawal_fee_units(uuid, text, text, numeric) IS
  'The whole fee model in one place: withdrawal_fee_flat_units + floor(amount_units * withdrawal_fee_rate_bps / 10000), in base units. Internal; quote_withdrawal_fee() is the readable wrapper.';

CREATE OR REPLACE FUNCTION public.quote_withdrawal_fee(
  p_asset_symbol text,
  p_network      text,
  p_amount_units numeric
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_asset uuid;
BEGIN
  SELECT id INTO v_asset FROM public.assets WHERE symbol = p_asset_symbol;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'unknown asset symbol %', p_asset_symbol USING ERRCODE = 'no_data_found';
  END IF;
  RETURN public._withdrawal_fee_units(v_asset, p_network, public.app_mode(), p_amount_units);
END $$;

COMMENT ON FUNCTION public.quote_withdrawal_fee(text, text, numeric) IS
  'Read-only fee preview in the current environment: flat + floor(amount * bps / 10000). Moves no money; readable by authenticated users so a client can show the fee before a request is created.';

-- ---------------------------------------------------------------------------
-- operator path 2: record a withdrawal request (the two sources)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._withdrawal_ingest(
  p_source              text,
  p_user_id             uuid,
  p_asset_symbol        text,
  p_network             text,
  p_destination_address text,
  p_amount_units        numeric,
  p_destination_tag     text,
  p_memo                text,
  p_provider_txid       text,
  p_raw                 jsonb
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
  v_net   public.withdrawal_networks;
  v_fee   numeric;
  v_id    uuid;
BEGIN
  IF p_source NOT IN ('paper_operator', 'provider_adapter') THEN
    RAISE EXCEPTION 'unknown withdrawal source %: only paper_operator (paper operator/test path) and provider_adapter (live chain-provider path) exist', p_source
      USING ERRCODE = 'check_violation';
  END IF;

  v_mode := public.app_mode();
  v_env  := CASE p_source WHEN 'provider_adapter' THEN 'live' ELSE 'paper' END;

  -- the two paths are mutually exclusive, in the data and in the mode
  IF p_source = 'paper_operator' AND v_mode <> 'paper' THEN
    RAISE EXCEPTION 'the operator/test withdrawal path is paper-only: app_settings.mode is % (real withdrawals enter through the provider adapter via record_provider_withdrawal())', v_mode
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_source = 'provider_adapter' AND v_mode <> 'live' THEN
    RAISE EXCEPTION 'the provider adapter path is live-only: app_settings.mode is %, so no adapter event may be recorded (paper data never enters through the adapter)', v_mode
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM public.assert_withdrawals_enabled();

  -- the paper sandbox switch: only the paper path reads it
  IF p_source = 'paper_operator' THEN
    PERFORM public.assert_paper_withdrawals_enabled();
  END IF;

  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %: a withdrawal belongs to exactly one user', p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_asset FROM public.assets WHERE symbol = p_asset_symbol;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'unknown asset symbol %', p_asset_symbol USING ERRCODE = 'no_data_found';
  END IF;

  -- "the asset matches": the (asset, network) pair must be a registered withdrawal
  -- network. The address string itself is NOT parsed or verified in this step (no chain
  -- integration, no allow-list) — see the migration header.
  SELECT * INTO v_net
    FROM public.withdrawal_networks
   WHERE asset_id = v_asset AND network = p_network AND environment = v_env;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'network % is not a registered withdrawal network for % in %: call register_withdrawal_network() first',
      p_network, p_asset_symbol, v_env
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT v_net.withdrawal_enabled THEN
    RAISE EXCEPTION 'withdrawals are not enabled for % on % in %: enable the network first',
      p_asset_symbol, p_network, v_env
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_destination_address IS NULL OR btrim(p_destination_address) = '' THEN
    RAISE EXCEPTION 'a withdrawal needs a destination address (supplied by the operator in paper mode; nothing is generated here)'
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  IF p_amount_units IS NULL OR p_amount_units <= 0 OR p_amount_units <> trunc(p_amount_units) THEN
    RAISE EXCEPTION 'withdrawal amount must be a positive whole number of base units (got %)', p_amount_units
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_amount_units < v_net.min_withdrawal_units THEN
    RAISE EXCEPTION 'withdrawal of % units is below the minimum of % for % on %',
      p_amount_units, v_net.min_withdrawal_units, p_asset_symbol, p_network
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_amount_units > v_net.max_withdrawal_units THEN
    RAISE EXCEPTION 'withdrawal of % units is above the maximum of % for % on %',
      p_amount_units, v_net.max_withdrawal_units, p_asset_symbol, p_network
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_net.requires_memo AND (p_destination_tag IS NULL OR btrim(p_destination_tag) = '') THEN
    RAISE EXCEPTION 'network % requires a destination tag/memo on every withdrawal', p_network
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  IF p_provider_txid IS NOT NULL AND btrim(p_provider_txid) = '' THEN
    RAISE EXCEPTION 'a provider txid, when given, cannot be blank'
      USING ERRCODE = 'check_violation';
  END IF;

  v_fee := public._withdrawal_fee_units(v_asset, p_network, v_env, p_amount_units);

  INSERT INTO public.withdrawal_requests (
    user_id, asset_id, network, environment, source, destination_address, destination_tag,
    memo, amount_units, fee_units, status, provider_txid, raw
  )
  VALUES (
    p_user_id, v_asset, p_network, v_env, p_source, btrim(p_destination_address),
    p_destination_tag, p_memo, p_amount_units, v_fee, 'pending',
    CASE WHEN p_provider_txid IS NULL THEN NULL ELSE btrim(p_provider_txid) END,
    COALESCE(p_raw, '{}'::jsonb)
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION public._withdrawal_ingest(text, uuid, text, text, text, numeric, text, text, text, jsonb) IS
  'Internal (not an entry point): the shared body of the two withdrawal sources. Derives environment from source, refuses the wrong mode for the path, applies the gates, validates the registered/enabled network, the destination, the amount against min/max and the memo requirement, snapshots the fee and writes a pending row. Callers: record_withdrawal_request() (paper) and record_provider_withdrawal() (live adapter).';

CREATE OR REPLACE FUNCTION public.record_withdrawal_request(
  p_user_id              uuid,
  p_asset_symbol         text,
  p_network              text,
  p_destination_address  text,
  p_amount_units         numeric,
  p_destination_tag      text DEFAULT NULL,
  p_memo                 text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  RETURN public._withdrawal_ingest(
    'paper_operator', p_user_id, p_asset_symbol, p_network, p_destination_address,
    p_amount_units, p_destination_tag, p_memo, NULL, '{}'::jsonb
  );
END $$;

COMMENT ON FUNCTION public.record_withdrawal_request(uuid, text, text, text, numeric, text, text) IS
  'Paper operator/test path: create a pending withdrawal request for a user as source = paper_operator in the paper environment. The destination address is supplied by the operator — nothing is generated, and nothing here claims the address was verified. Refused while app_settings.mode = live, and while the paper sandbox switch is off. No money moves until approve_withdrawal(). service_role only.';

CREATE OR REPLACE FUNCTION public.record_provider_withdrawal(p_event jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing text;
  v_user    uuid;
  v_amount  numeric;
BEGIN
  IF p_event IS NULL OR jsonb_typeof(p_event) <> 'object' THEN
    RAISE EXCEPTION 'provider adapter contract violation: the event must be a JSON object (got %)',
      COALESCE(jsonb_typeof(p_event), 'NULL')
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT string_agg(k, ', ' ORDER BY k)
    INTO v_missing
    FROM unnest(ARRAY['network', 'asset_symbol', 'user_id', 'destination_address', 'amount_units']) AS k
   WHERE NOT (p_event ? k);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'provider adapter contract violation: event is missing required key(s) % (required: network, asset_symbol, user_id, destination_address, amount_units; optional: destination_tag, memo, provider_txid)',
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

  RETURN public._withdrawal_ingest(
    'provider_adapter', v_user, p_event->>'asset_symbol', p_event->>'network',
    p_event->>'destination_address', v_amount, p_event->>'destination_tag',
    p_event->>'memo', p_event->>'provider_txid', p_event
  );
END $$;

COMMENT ON FUNCTION public.record_provider_withdrawal(jsonb) IS
  'Live chain-provider adapter path (the documented adapter contract): takes ONE normalised provider event as JSON (network, asset_symbol, user_id, destination_address, amount_units required; destination_tag, memo, provider_txid optional; any extra provider fields are preserved in raw) and records it as source = provider_adapter in the LIVE environment. Refuses a malformed event as an adapter contract violation and records nothing. Refuses to run unless app_settings.mode = live, passes the LIVE_WITHDRAWALS_ENABLED gate and the enforce_environment_gate trigger. No provider, credentials or address generation is part of this step. service_role only.';

-- ---------------------------------------------------------------------------
-- operator path 3: the state machine transitions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_withdrawal_under_review(
  p_withdrawal_id uuid,
  p_reason        text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_w  public.withdrawal_requests;
  v_st text;
BEGIN
  PERFORM public.assert_withdrawals_enabled();

  SELECT * INTO v_w FROM public.withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown withdrawal %', p_withdrawal_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_w.status = 'under review' THEN
    RETURN 'under review';   -- idempotent
  END IF;

  IF v_w.status <> 'pending' THEN
    RAISE EXCEPTION 'withdrawal % is %: only a pending withdrawal can be put under review', v_w.id, v_w.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'putting withdrawal % under operator review requires a reason', v_w.id
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  UPDATE public.withdrawal_requests
     SET status = 'under review',
         review_reason = btrim(p_reason)
   WHERE id = v_w.id
  RETURNING status INTO v_st;

  RETURN v_st;
END $$;

COMMENT ON FUNCTION public.set_withdrawal_under_review(uuid, text) IS
  'Operator path: put a pending withdrawal under operator review (suspicious destination, amount, ...) with a reason. Nothing is locked yet; resolve it with approve_withdrawal(), reject_withdrawal() or fail_withdrawal(). service_role only.';

CREATE OR REPLACE FUNCTION public.approve_withdrawal(p_withdrawal_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_w        public.withdrawal_requests;
  v_st       text;
  v_held     numeric;
  v_avail    uuid;
  v_locked   uuid;
  v_available numeric;
  v_tx       uuid;
BEGIN
  PERFORM public.assert_withdrawals_enabled();

  SELECT * INTO v_w FROM public.withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown withdrawal %', p_withdrawal_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_w.status = 'approved' THEN
    RETURN 'approved';   -- idempotent, and the hold was already placed
  END IF;

  IF v_w.status NOT IN ('pending', 'under review') THEN
    RAISE EXCEPTION 'withdrawal % is %: only a pending or under-review withdrawal can be approved', v_w.id, v_w.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- a paper approval holds money, so the paper sandbox switch applies
  IF v_w.environment = 'paper' THEN
    PERFORM public.assert_paper_withdrawals_enabled();
  END IF;

  v_held := v_w.amount_units + v_w.fee_units;
  v_avail  := public.ensure_user_account(v_w.user_id, v_w.asset_id, 'available', v_w.environment);
  v_locked := public.ensure_user_account(v_w.user_id, v_w.asset_id, 'locked',    v_w.environment);

  SELECT COALESCE(b.available_units, 0) INTO v_available
    FROM public.balances b WHERE b.account_id = v_avail;
  v_available := COALESCE(v_available, 0);

  IF v_available < v_held THEN
    RAISE EXCEPTION 'insufficient available balance for withdrawal %: % units (amount % + fee %) are required, % available',
      v_w.id, v_held, v_w.amount_units, v_w.fee_units, v_available
      USING ERRCODE = 'check_violation';
  END IF;

  -- the hold: available -> locked, one balanced ledger transaction
  INSERT INTO public.ledger_transactions (
    type, environment, idempotency_key, reference_type, reference_id, description, metadata
  )
  VALUES (
    'withdrawal_request', v_w.environment,
    'withdrawal_hold:' || v_w.id::text,
    'withdrawal_request', v_w.id, 'withdrawal hold placed',
    jsonb_build_object(
      'network', v_w.network, 'amount_units', v_w.amount_units,
      'fee_units', v_w.fee_units, 'held_units', v_held, 'source', v_w.source
    )
  )
  RETURNING id INTO v_tx;

  PERFORM public.post_entry(v_tx, v_avail,  -v_held, 'withdrawal hold');
  PERFORM public.post_entry(v_tx, v_locked,  v_held, 'withdrawal hold');

  UPDATE public.withdrawal_requests
     SET status = 'approved',
         approved_at = now(),
         hold_ledger_transaction_id = v_tx
   WHERE id = v_w.id
  RETURNING status INTO v_st;

  RETURN v_st;
END $$;

COMMENT ON FUNCTION public.approve_withdrawal(uuid) IS
  'Operator path: approve a pending or under-review withdrawal, which LOCKS the funds: one withdrawal_request ledger transaction debits the user''s available account and credits their locked account with amount+fee (zero-sum, both postings in the same transaction), recorded as hold_ledger_transaction_id. Refuses an insufficient available balance, wrong-state approvals and — for a paper row — a switched-off paper sandbox. Idempotent on an already-approved row. service_role only.';

CREATE OR REPLACE FUNCTION public.start_withdrawal_processing(
  p_withdrawal_id uuid,
  p_provider_txid text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_w  public.withdrawal_requests;
  v_st text;
BEGIN
  PERFORM public.assert_withdrawals_enabled();

  SELECT * INTO v_w FROM public.withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown withdrawal %', p_withdrawal_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_w.status <> 'approved' THEN
    RAISE EXCEPTION 'withdrawal % is %: only an approved withdrawal can start processing', v_w.id, v_w.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_provider_txid IS NULL OR btrim(p_provider_txid) = '' THEN
    RAISE EXCEPTION 'starting processing of withdrawal % requires the provider txid it was broadcast in', v_w.id
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  -- guard #2 of the idempotency: an explicit, readable refusal before the unique index
  IF EXISTS (
    SELECT 1 FROM public.withdrawal_requests w
     WHERE w.environment = v_w.environment AND w.network = v_w.network
       AND w.provider_txid = btrim(p_provider_txid) AND w.id <> v_w.id
  ) THEN
    RAISE EXCEPTION 'provider txid % on % has already been used by another withdrawal in %: a chain transaction can never settle two withdrawals',
      p_provider_txid, v_w.network, v_w.environment
      USING ERRCODE = 'unique_violation';
  END IF;

  UPDATE public.withdrawal_requests
     SET status = 'processing',
         processing_at = now(),
         provider_txid = btrim(p_provider_txid)
   WHERE id = v_w.id
  RETURNING status INTO v_st;

  RETURN v_st;
END $$;

COMMENT ON FUNCTION public.start_withdrawal_processing(uuid, text) IS
  'Operator/provider path: approved -> processing, recording the provider txid the withdrawal was broadcast in (write-once, unique per environment+network). Refuses a missing txid and a txid already used by another withdrawal. service_role only.';

CREATE OR REPLACE FUNCTION public.complete_withdrawal(
  p_withdrawal_id uuid,
  p_provider_txid text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_w        public.withdrawal_requests;
  v_txid     text;
  v_held     numeric;
  v_locked   uuid;
  v_clear    uuid;
  v_fee_acct uuid;
  v_tx       uuid;
BEGIN
  PERFORM public.assert_withdrawals_enabled();

  SELECT * INTO v_w FROM public.withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown withdrawal %', p_withdrawal_id USING ERRCODE = 'no_data_found';
  END IF;

  -- a paper settlement moves money, so the paper sandbox switch applies
  IF v_w.environment = 'paper' THEN
    PERFORM public.assert_paper_withdrawals_enabled();
  END IF;

  -- guard #2 of the idempotency: explicit refusal before the constraints fire
  IF v_w.settled_ledger_transaction_id IS NOT NULL THEN
    RAISE EXCEPTION 'withdrawal % is already settled by ledger transaction %: a withdrawal can never be posted twice',
      v_w.id, v_w.settled_ledger_transaction_id
      USING ERRCODE = 'unique_violation';
  END IF;

  IF v_w.status <> 'processing' THEN
    RAISE EXCEPTION 'withdrawal % is %: only a processing withdrawal can be completed (approved -> processing -> completed)', v_w.id, v_w.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_provider_txid IS NOT NULL AND v_w.provider_txid IS NOT NULL
     AND btrim(p_provider_txid) <> v_w.provider_txid THEN
    RAISE EXCEPTION 'withdrawal % was broadcast in provider txid %: it cannot be settled by a different txid (%)',
      v_w.id, v_w.provider_txid, p_provider_txid
      USING ERRCODE = 'check_violation';
  END IF;

  v_txid := COALESCE(v_w.provider_txid, NULLIF(btrim(COALESCE(p_provider_txid, '')), ''));
  IF v_txid IS NULL THEN
    RAISE EXCEPTION 'completing withdrawal % requires the provider txid that settled it', v_w.id
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.withdrawal_requests w
     WHERE w.environment = v_w.environment AND w.network = v_w.network
       AND w.provider_txid = v_txid AND w.id <> v_w.id
  ) THEN
    RAISE EXCEPTION 'provider txid % on % has already been used by another withdrawal in %: a chain transaction can never settle two withdrawals',
      v_txid, v_w.network, v_w.environment
      USING ERRCODE = 'unique_violation';
  END IF;

  v_held   := v_w.amount_units + v_w.fee_units;
  v_locked := public.ensure_user_account(v_w.user_id, v_w.asset_id, 'locked', v_w.environment);
  v_clear  := public.system_account_id('WITHDRAWAL_CLEARING', v_w.asset_id, v_w.environment);

  -- guard #3 of the idempotency: the ledger's own unique idempotency_key, keyed on the
  -- per-environment provider txid
  INSERT INTO public.ledger_transactions (
    type, environment, idempotency_key, reference_type, reference_id, description, metadata
  )
  VALUES (
    'withdrawal_settle', v_w.environment,
    'withdrawal_settle:' || v_w.environment || ':' || v_w.network || ':' || v_txid,
    'withdrawal_request', v_w.id, 'withdrawal settled',
    jsonb_build_object(
      'network', v_w.network, 'provider_txid', v_txid,
      'destination_address', v_w.destination_address,
      'amount_units', v_w.amount_units, 'fee_units', v_w.fee_units,
      'held_units', v_held, 'source', v_w.source
    )
  )
  RETURNING id INTO v_tx;

  PERFORM public.post_entry(v_tx, v_locked, -v_held, 'withdrawal settled: hold consumed');
  PERFORM public.post_entry(v_tx, v_clear,   v_w.amount_units, 'withdrawal clearing ' || v_txid);
  IF v_w.fee_units > 0 THEN
    v_fee_acct := public.system_account_id('FEE_INCOME', v_w.asset_id, v_w.environment);
    PERFORM public.post_entry(v_tx, v_fee_acct, v_w.fee_units, 'withdrawal fee ' || v_txid);
  END IF;

  UPDATE public.withdrawal_requests
     SET status = 'completed',
         processing_at = COALESCE(processing_at, now()),
         completed_at = now(),
         provider_txid = v_txid,
         settled_ledger_transaction_id = v_tx
   WHERE id = v_w.id;

  RETURN v_tx;
END $$;

COMMENT ON FUNCTION public.complete_withdrawal(uuid, text) IS
  'Operator/provider path: processing -> completed. Posts ONE immutable withdrawal_settle ledger transaction (locked account -= amount+fee, WITHDRAWAL_CLEARING system account += amount, FEE_INCOME += fee when non-zero) and writes the settlement data on the row in the same transaction, so the deferred ledger invariants hold or nothing happens. Refuses: an already settled withdrawal, a withdrawal that is not processing, a missing or conflicting provider txid, a txid already used by another withdrawal, and — for a paper row — a switched-off paper sandbox. service_role only.';

-- internal: the one release path shared by reject_withdrawal() and fail_withdrawal()
CREATE OR REPLACE FUNCTION public._withdrawal_close(
  p_withdrawal_id uuid,
  p_status        text,
  p_reason        text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_w        public.withdrawal_requests;
  v_held     numeric;
  v_locked   uuid;
  v_avail    uuid;
  v_tx       uuid;
  v_st       text;
BEGIN
  IF p_status NOT IN ('failed', 'rejected') THEN
    RAISE EXCEPTION 'unknown terminal withdrawal status %: only failed and rejected close a request', p_status
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'closing withdrawal % as % requires a reason (it is stored in failure_reason)', p_withdrawal_id, p_status
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  SELECT * INTO v_w FROM public.withdrawal_requests WHERE id = p_withdrawal_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown withdrawal %', p_withdrawal_id USING ERRCODE = 'no_data_found';
  END IF;

  IF v_w.status NOT IN ('pending', 'under review', 'approved', 'processing') THEN
    RAISE EXCEPTION 'withdrawal % is % (terminal): it cannot be closed again', v_w.id, v_w.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- release exactly the hold, if one was placed (the order book's release pattern)
  IF v_w.hold_ledger_transaction_id IS NOT NULL THEN
    IF v_w.settled_ledger_transaction_id IS NOT NULL THEN
      RAISE EXCEPTION 'withdrawal % is already settled: reversing a settlement needs a compensating ledger transaction, which is not implemented in this step', v_w.id
        USING ERRCODE = 'check_violation';
    END IF;

    v_held   := v_w.amount_units + v_w.fee_units;
    v_locked := public.ensure_user_account(v_w.user_id, v_w.asset_id, 'locked',    v_w.environment);
    v_avail  := public.ensure_user_account(v_w.user_id, v_w.asset_id, 'available', v_w.environment);

    INSERT INTO public.ledger_transactions (
      type, environment, idempotency_key, reference_type, reference_id, description, metadata
    )
    VALUES (
      'withdrawal_refund', v_w.environment,
      'withdrawal_release:' || v_w.id::text,
      'withdrawal_request', v_w.id,
      format('release %s units of the hold on withdrawal %s (%s: %s)',
             v_held, v_w.id, p_status, btrim(p_reason)),
      jsonb_build_object(
        'network', v_w.network, 'released_units', v_held,
        'amount_units', v_w.amount_units, 'fee_units', v_w.fee_units,
        'reason', btrim(p_reason), 'closed_as', p_status, 'source', v_w.source
      )
    )
    RETURNING id INTO v_tx;

    PERFORM public.post_entry(v_tx, v_locked, -v_held, 'withdrawal hold released');
    PERFORM public.post_entry(v_tx, v_avail,   v_held, 'withdrawal hold released back to available');
  END IF;

  UPDATE public.withdrawal_requests
     SET status = p_status,
         failure_reason = btrim(p_reason),
         closed_at = now(),
         released_ledger_transaction_id = v_tx
   WHERE id = v_w.id
  RETURNING status INTO v_st;

  RETURN v_st;
END $$;

COMMENT ON FUNCTION public._withdrawal_close(uuid, text, text) IS
  'Internal (not an entry point): the single release path of the withdrawal layer. Moves a non-terminal request to failed or rejected and, if a hold was placed, posts one balanced withdrawal_refund transaction (locked -= amount+fee, available += amount+fee) recording it in released_ledger_transaction_id. A request that was never approved releases nothing. Does NOT read the paper sandbox switch on purpose: locked funds must always be releasable.';

CREATE OR REPLACE FUNCTION public.reject_withdrawal(
  p_withdrawal_id uuid,
  p_reason        text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.assert_withdrawals_enabled();
  RETURN public._withdrawal_close(p_withdrawal_id, 'rejected', p_reason);
END $$;

COMMENT ON FUNCTION public.reject_withdrawal(uuid, text) IS
  'Operator path: refuse a pending, under-review, approved or processing withdrawal (status rejected, mandatory reason). Any hold is released back to available exactly. Not gated by the paper sandbox switch, so funds can never be trapped. service_role only.';

CREATE OR REPLACE FUNCTION public.fail_withdrawal(
  p_withdrawal_id uuid,
  p_reason        text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.assert_withdrawals_enabled();
  RETURN public._withdrawal_close(p_withdrawal_id, 'failed', p_reason);
END $$;

COMMENT ON FUNCTION public.fail_withdrawal(uuid, text) IS
  'Operator/watcher path: a withdrawal that went further and could not be completed (broadcast failed, dropped, reversed) becomes failed with a mandatory reason, and any hold is released back to available exactly. Not gated by the paper sandbox switch. service_role only.';

-- ---------------------------------------------------------------------------
-- RLS and privileges
-- ---------------------------------------------------------------------------
ALTER TABLE public.withdrawal_networks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawal_requests ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['withdrawal_networks', 'withdrawal_requests'] LOOP
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

-- No DELETE for anybody: a withdrawal row is evidence, and configuration is
-- disabled (withdrawal_enabled) rather than deleted.
DROP POLICY IF EXISTS withdrawal_networks_select_authenticated ON public.withdrawal_networks;
CREATE POLICY withdrawal_networks_select_authenticated ON public.withdrawal_networks
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS withdrawal_requests_select_own ON public.withdrawal_requests;
CREATE POLICY withdrawal_requests_select_own ON public.withdrawal_requests
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

-- No INSERT/UPDATE/DELETE policy for anon or authenticated: client writes are
-- denied by RLS regardless of any future privilege grant.

-- ---------------------------------------------------------------------------
-- function ACLs — same pattern as 20261005100100 / 20261005100120: PUBLIC and the
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
         'assert_withdrawals_enabled', 'assert_paper_withdrawals_enabled',
         'register_withdrawal_network', '_withdrawal_fee_units',
         'quote_withdrawal_fee', '_withdrawal_ingest',
         'record_withdrawal_request', 'record_provider_withdrawal',
         'set_withdrawal_under_review', 'approve_withdrawal',
         'start_withdrawal_processing', 'complete_withdrawal',
         '_withdrawal_close', 'reject_withdrawal', 'fail_withdrawal'
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

-- the one read-only exception: a signed-in user may preview a fee (moves no money)
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.quote_withdrawal_fee(text, text, numeric) TO authenticated;
  END IF;
END $$;
-- (withdrawal_requests_before_update is a trigger function and keeps the default
-- EXECUTE grant on purpose: PostgreSQL checks EXECUTE with the invoking role.)
