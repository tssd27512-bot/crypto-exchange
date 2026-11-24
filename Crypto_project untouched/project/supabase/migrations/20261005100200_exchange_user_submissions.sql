/*
# Migration 27 — user-facing withdrawal requests and KYC submissions (stage 7)

Purpose
-------
Two client-facing entry points so a signed-in user can REQUEST a withdrawal and
SUBMIT a KYC application without ever holding a service_role permission, without
touching a chain/provider, and without any path to a self-granted "verified":

    request_withdrawal(p_asset, p_network, p_amount_units,
                       p_idempotency_key DEFAULT NULL,
                       p_destination_address DEFAULT NULL)
        RETURNS TABLE (request_id uuid, request_status text, existing boolean)
    cancel_my_withdrawal(p_request_id uuid)
        RETURNS TABLE (request_id uuid, request_status text, released_units numeric)
    submit_my_kyc(p_tier_code text, p_documents jsonb DEFAULT '{}'::jsonb)
        RETURNS TABLE (submission_id uuid, submission_status text, existing boolean)

All three are SECURITY DEFINER with a pinned search_path, granted to
`authenticated` only, and revoked from PUBLIC and `anon`. `service_role` is NOT
granted on them on purpose: the operator/watcher surface stays the functions it
already had (record_withdrawal_request, approve_withdrawal, reject_withdrawal,
fail_withdrawal, submit_kyc, approve_kyc, reject_kyc, record_provider_*).

Nothing here re-implements money. The wrappers call the existing machinery:
`_withdrawal_ingest` (gates + network/amount/destination validation + fee
snapshot), the withdrawal hold pattern (`withdrawal_request` ledger transaction,
available -> locked), `_withdrawal_close` (the single release path, posts
`withdrawal_refund`, locked -> available) and the KYC submission table's own
no-PII trigger and state machine.

Client ownership
----------------
Every wrapper starts from `auth.uid()` and refuses when it is NULL with a
distinct error (`insufficient_privilege`, "... no authenticated user"). The
caller cannot name a user: `user_id` is never a parameter. Every read/cancel
path re-checks `user_id = auth.uid()` inside the function, and the existing
own-row SELECT policies (`withdrawal_requests_select_own`,
`kyc_submissions_select_own`, created by migrations 130/140) already restrict a
client to its own rows — this migration adds NO policy that would widen that.
A cross-user cancel is refused inside `cancel_my_withdrawal` before any money
moves.

Validation
----------
* amounts are integer base units (`bigint`); a fractional, zero or negative
  amount is refused, and the configured per-network minimum/maximum applies;
* the asset must exist, the (asset, network) pair must be a registered,
  ENABLED withdrawal network of the CURRENT environment, and the network's memo
  requirement applies (all inside `_withdrawal_ingest`);
* the KYC tier must exist in `kyc_levels` and be >= 1 (level 0 "unverified" is
  not an application), the document payload must be a JSON object, and the
  existing `kyc_metadata_guard` denylist trigger refuses any personal data in it.

Mode gates
----------
The wrappers inherit every gate the operator path has, because they call the
same code: `assert_withdrawals_enabled()` (live flag), `assert_paper_withdrawals_enabled()`
(paper sandbox switch), `assert_not_in_maintenance('withdrawals')`,
`assert_account_not_restricted(<caller>, 'withdrawals')`, and `assert_kyc_path()`.
No gate is weakened and none is bypassed.

Stage-7 scope decision (flagged, not silent): the two client write paths are
PAPER-ONLY in this stage. While `app_settings.mode = 'live'` the wrappers refuse
with a distinct message, so no live money row and no live KYC application can be
created by a client. Live withdrawals enter through the provider adapter
(`record_provider_withdrawal`) and live KYC through the provider adapter
(`record_provider_kyc_event`) — both already exist and neither is touched here.
Turning the client paths on in live mode is a separate, owner-gated change.

Money rules of a client request
-------------------------------
* REQUESTING HOLDS THE FUNDS. `request_withdrawal` posts one `withdrawal_request`
  ledger transaction (available -= amount+fee, locked += amount+fee, both
  postings in the same transaction) and records it in
  `hold_ledger_transaction_id`, so a pending client request cannot be spent
  twice. An unfunded request is refused and rolls back completely — a request
  row never exists without its hold.
* IDEMPOTENT. `withdrawal_requests.idempotency_key` + UNIQUE (user_id,
  idempotency_key) (partial: NULL keys stay distinct). A retry with the same key
  returns the existing request (`existing = true`) and holds nothing again. The
  hold itself carries the ledger idempotency key `withdrawal_hold:<request id>`,
  the SAME key the approval path uses, so a request can never be held twice even
  under a race (one of the two inserts loses on the unique index).
* CANCEL RELEASES EXACTLY THE HOLD. `cancel_my_withdrawal` is allowed ONLY while
  the request is still `pending` (not approved, not under operator review) and
  posts the existing release transaction through `_withdrawal_close`: locked -=
  amount+fee, available += amount+fee, recorded in
  `released_ledger_transaction_id`. Zero-sum; nothing is invented, nothing is
  rounded. Like `reject_withdrawal`/`fail_withdrawal`, the release path
  deliberately does NOT read the paper sandbox switch or maintenance mode:
  locked funds must always be releasable by their owner.
* APPROVAL STAYS ADMIN-ONLY. `approve_withdrawal()` is still service_role only
  and is the only thing that can move a request forward. Because a client
  request is already held, approval gained ONE additive branch: when the row
  already carries a hold it CONFIRMS that hold instead of posting a second one
  (posting a second one would double-lock, or fail on the ledger idempotency
  key). Every row that has no pre-existing hold — every row the operator path
  and the provider adapter create — takes the byte-identical previous path.
* A NEW TERMINAL STATUS `cancelled` (owner's set, extended by this stage) so a
  user cancel is distinguishable from an operator `rejected`/`failed`. It is
  reachable only from `pending`, only through `_withdrawal_close`, and is
  terminal and immutable exactly like the other two.

KYC honesty
-----------
`submit_my_kyc` inserts ONE row with `status = 'pending'` (the existing state
machine's "awaiting review"; the plan's "pending_review" is that same state —
no new status was invented for KYC), `source = 'user_client'`, `environment =
'paper'`. It never writes `kyc_status.level` (the user's level stays 0 /
unverified), never touches `_kyc_grant_level`, and contains no reference to
`approved`: the only way to `approved` — and so to a level — is the existing
operator decision (`approve_kyc`) or a real provider event
(`record_provider_kyc_event`), both service_role only. The existing audit
trigger records the submission with actor_role 'user' and actor_id = auth.uid().
One OPEN submission per user per tier: a second submission while a previous one
is pending/under review returns the open one (`existing = true`); a resubmission
after a final state creates a new row. Enforced by the function and by the
partial unique index `kyc_submissions_user_open_key`.

What this migration deliberately does NOT do
--------------------------------------------
* No deployment, no blockchain/provider/custody call, no address generation, no
  document upload or storage, no vendor. Every destination address is supplied
  by the caller and is NOT verified (no allow-list; the same position as the
  operator path — see migration 130's header).
* No frontend change: the Withdraw and KYC pages stay disabled this stage.
* No per-tier limits and no KYC gating of money paths (still an owner decision).
* No service_role grant on the new wrappers, and no new grant at all on any
  pre-existing money/admin function.

Safety
------
app_settings is not touched: mode stays 'paper', every LIVE_* flag stays false.
No table is created; the only schema changes are additive columns/indexes, one
new status and one new source value (both supersets of the previous sets), and
replaced function bodies whose previous behaviour is preserved except for the
documented additive branches.
*/

-- ---------------------------------------------------------------------------
-- 1. schema: idempotency key, the `cancelled` status, the `user_client` source
-- ---------------------------------------------------------------------------
ALTER TABLE public.withdrawal_requests
  ADD COLUMN IF NOT EXISTS idempotency_key text;

COMMENT ON COLUMN public.withdrawal_requests.idempotency_key IS
  'Client-supplied idempotency key of a user-submitted request (NULL on the operator and provider-adapter paths). UNIQUE (user_id, idempotency_key): a retry returns the existing request instead of creating — and holding — a second one.';

DO $q$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'withdrawal_requests_idempotency_key_check'
       AND conrelid = 'public.withdrawal_requests'::regclass
  ) THEN
    ALTER TABLE public.withdrawal_requests
      ADD CONSTRAINT withdrawal_requests_idempotency_key_check
      CHECK (idempotency_key IS NULL OR length(btrim(idempotency_key)) BETWEEN 1 AND 200);
  END IF;
END $q$;

CREATE UNIQUE INDEX IF NOT EXISTS withdrawal_requests_idempotency_key
  ON public.withdrawal_requests (user_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;

COMMENT ON INDEX public.withdrawal_requests_idempotency_key IS
  'Idempotency of a client-submitted withdrawal request: at most one request per (user, key). The ledger hold carries withdrawal_hold:<request id>, so even a lost race cannot hold the same request twice.';

-- the status set gains one terminal value; every previous value keeps its meaning
ALTER TABLE public.withdrawal_requests
  DROP CONSTRAINT IF EXISTS withdrawal_requests_status_check;
ALTER TABLE public.withdrawal_requests
  ADD CONSTRAINT withdrawal_requests_status_check CHECK (status IN (
    'pending', 'under review', 'approved', 'processing', 'completed', 'failed',
    'rejected', 'cancelled'
  ));

-- the source set gains the client path; the source<->environment pairing below is
-- untouched, so user_client can only ever be a PAPER row (a live user request is
-- refused by the CHECK, in addition to the mode gate in the wrapper)
ALTER TABLE public.withdrawal_requests
  DROP CONSTRAINT IF EXISTS withdrawal_requests_source_check;
ALTER TABLE public.withdrawal_requests
  ADD CONSTRAINT withdrawal_requests_source_check CHECK (source IN (
    'paper_operator', 'provider_adapter', 'user_client'
  ));

COMMENT ON COLUMN public.withdrawal_requests.source IS
  'Which path produced this row: paper_operator (operator/test harness, paper only), provider_adapter (live chain-provider adapter, live only) or user_client (a signed-in user through request_withdrawal(), paper only). Paired with environment by CHECK.';

-- cancelled is terminal like failed/rejected, so it carries the same closed_at,
-- release pointer and hold-release guarantees
ALTER TABLE public.withdrawal_requests
  DROP CONSTRAINT IF EXISTS withdrawal_requests_closed_at_check;
ALTER TABLE public.withdrawal_requests
  ADD CONSTRAINT withdrawal_requests_closed_at_check CHECK (
    (status IN ('failed', 'rejected', 'cancelled')) = (closed_at IS NOT NULL)
  );

ALTER TABLE public.withdrawal_requests
  DROP CONSTRAINT IF EXISTS withdrawal_requests_released_check;
ALTER TABLE public.withdrawal_requests
  ADD CONSTRAINT withdrawal_requests_released_check CHECK (
    status IN ('failed', 'rejected', 'cancelled')
    OR released_ledger_transaction_id IS NULL
  );

ALTER TABLE public.withdrawal_requests
  DROP CONSTRAINT IF EXISTS withdrawal_requests_hold_released_check;
ALTER TABLE public.withdrawal_requests
  ADD CONSTRAINT withdrawal_requests_hold_released_check CHECK (
    status NOT IN ('failed', 'rejected', 'cancelled')
    OR hold_ledger_transaction_id IS NULL
    OR released_ledger_transaction_id IS NOT NULL
  );

COMMENT ON COLUMN public.withdrawal_requests.status IS
  'pending | under review | approved | processing | completed | failed | rejected | cancelled. approved means the funds are locked (for a user_client row they were locked at request time); completed/failed/rejected/cancelled are terminal and immutable. cancelled is a user cancel of a still-pending request and is reachable only through cancel_my_withdrawal().';

-- the KYC submission source set gains the client path (the pairing CHECK is
-- untouched: user_client is therefore paper-only)
ALTER TABLE public.kyc_submissions
  DROP CONSTRAINT IF EXISTS kyc_submissions_source_check;
ALTER TABLE public.kyc_submissions
  ADD CONSTRAINT kyc_submissions_source_check CHECK (source IN (
    'paper_operator', 'provider_adapter', 'user_client'
  ));

COMMENT ON COLUMN public.kyc_submissions.source IS
  'Which path produced this row: paper_operator (operator/test harness, paper only), provider_adapter (live KYC provider adapter, live only) or user_client (a signed-in user through submit_my_kyc(), paper only). Paired with environment by CHECK.';

-- one OPEN client submission per user per tier; a resubmission after a final
-- state is a new row. Scoped to source = 'user_client' so it can never conflict
-- with operator/adapter rows created before this migration.
CREATE UNIQUE INDEX IF NOT EXISTS kyc_submissions_user_open_key
  ON public.kyc_submissions (user_id, level_sought)
  WHERE source = 'user_client' AND status IN ('pending', 'under review');

COMMENT ON INDEX public.kyc_submissions_user_open_key IS
  'At most one OPEN (pending / under review) KYC application per user per tier on the client path. A retry returns the open row; only a final (approved/rejected) submission can be followed by a new one.';

-- ---------------------------------------------------------------------------
-- 2. the withdrawal state machine learns `cancelled`
--
-- Only the pending -> cancelled edge and the terminal list change. Every other
-- line is the migration-130 body verbatim.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.withdrawal_requests_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_allowed boolean;
BEGIN
  -- terminal rows are immutable: a settled/closed/cancelled withdrawal can never
  -- be edited, re-pointed or moved again
  IF OLD.status IN ('completed', 'failed', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION
      'withdrawal % is % (terminal): a completed, failed, rejected or cancelled withdrawal is immutable',
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

  -- the client idempotency key is write-once too
  IF OLD.idempotency_key IS NOT NULL
     AND NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key THEN
    RAISE EXCEPTION 'the idempotency key of withdrawal % is write-once', OLD.id
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
                   WHEN 'pending'      THEN NEW.status IN ('under review', 'approved', 'rejected', 'failed', 'cancelled')
                   WHEN 'under review' THEN NEW.status IN ('approved', 'rejected', 'failed')
                   WHEN 'approved'     THEN NEW.status IN ('processing', 'failed')
                   WHEN 'processing'   THEN NEW.status IN ('completed', 'failed')
                   ELSE false   -- completed / failed / rejected / cancelled are terminal
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
END $fn$;

COMMENT ON FUNCTION public.withdrawal_requests_before_update() IS
  'Implemented as a trigger: enforces the withdrawal state machine (pending/under review/approved/processing/completed/failed/rejected/cancelled), the immutability of the request identity, of the client idempotency key, of the provider txid and of the hold/settle/release ledger pointers, and the total immutability of a terminal row. cancelled is reachable from pending only, which is the edge cancel_my_withdrawal() uses.';

-- ---------------------------------------------------------------------------
-- 3. _withdrawal_ingest learns the user_client source (paper only)
--
-- Additive: the source list, the environment derivation, the paper-only mode
-- rule and the paper sandbox gate each gain one branch for user_client. Every
-- other line — every existing gate, validation and the fee snapshot — is the
-- migration-150 body verbatim.
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
AS $fn$
DECLARE
  v_asset uuid;
  v_env   text;
  v_mode  text;
  v_net   public.withdrawal_networks;
  v_fee   numeric;
  v_id    uuid;
BEGIN
  IF p_source NOT IN ('paper_operator', 'provider_adapter', 'user_client') THEN
    RAISE EXCEPTION 'unknown withdrawal source %: only paper_operator (paper operator/test path), provider_adapter (live chain-provider path) and user_client (signed-in user) exist', p_source
      USING ERRCODE = 'check_violation';
  END IF;

  v_mode := public.app_mode();
  v_env  := CASE p_source WHEN 'provider_adapter' THEN 'live' ELSE 'paper' END;

  -- the paths are mutually exclusive, in the data and in the mode
  IF p_source = 'paper_operator' AND v_mode <> 'paper' THEN
    RAISE EXCEPTION 'the operator/test withdrawal path is paper-only: app_settings.mode is % (real withdrawals enter through the provider adapter via record_provider_withdrawal())', v_mode
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_source = 'user_client' AND v_mode <> 'paper' THEN
    RAISE EXCEPTION 'user withdrawal requests are not open in live mode: app_settings.mode is % (live withdrawals enter through the provider adapter via record_provider_withdrawal(), after the operator path has approved the request)', v_mode
      USING ERRCODE = 'check_violation';
  END IF;
  IF p_source = 'provider_adapter' AND v_mode <> 'live' THEN
    RAISE EXCEPTION 'the provider adapter path is live-only: app_settings.mode is %, so no adapter event may be recorded (paper data never enters through the adapter)', v_mode
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM public.assert_withdrawals_enabled();

  -- the paper sandbox switch: the paper paths read it
  IF p_source IN ('paper_operator', 'user_client') THEN
    PERFORM public.assert_paper_withdrawals_enabled();
  END IF;

  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %: a withdrawal belongs to exactly one user', p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;
  -- maintenance + withdrawals-restriction gates (20261005100150)
  PERFORM public.assert_not_in_maintenance('withdrawals');
  PERFORM public.assert_account_not_restricted(p_user_id, 'withdrawals');

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
    RAISE EXCEPTION 'a withdrawal needs a destination address (supplied by the caller in paper mode; nothing is generated here)'
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
END $fn$;

COMMENT ON FUNCTION public._withdrawal_ingest(text, uuid, text, text, text, numeric, text, text, text, jsonb) IS
  'Internal (not an entry point): the shared body of the three withdrawal sources. Derives environment from source, refuses the wrong mode for the path (user_client is paper-only), applies the gates (live flag, paper sandbox, maintenance, account restriction), validates the registered/enabled network, the destination, the amount against min/max and the memo requirement, snapshots the fee and writes a pending row. Callers: record_withdrawal_request() (paper operator), record_provider_withdrawal() (live adapter) and request_withdrawal() (signed-in user, paper).';

-- ---------------------------------------------------------------------------
-- 4. approve_withdrawal: confirm a hold that already exists instead of taking a
--    second one (the ONLY new branch; every other line is migration 150 verbatim)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_withdrawal(p_withdrawal_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
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
  -- maintenance + withdrawals-restriction gates (20261005100150)
  PERFORM public.assert_not_in_maintenance('withdrawals');
  PERFORM public.assert_account_not_restricted(v_w.user_id, 'withdrawals');

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

  IF v_w.hold_ledger_transaction_id IS NOT NULL THEN
    -- >>> 20261005100200 (stage 7): a client-submitted request (request_withdrawal)
    -- HOLDS THE FUNDS AT REQUEST TIME, so approval must confirm that hold and never
    -- post a second one. The hold transaction is verified to exist and to be the
    -- withdrawal hold of this request; no money moves here. Every row without a
    -- pre-existing hold (operator path, provider adapter) takes the branch below
    -- unchanged.
    IF NOT EXISTS (
      SELECT 1 FROM public.ledger_transactions t
       WHERE t.id = v_w.hold_ledger_transaction_id
         AND t.type = 'withdrawal_request'
         AND t.reference_type = 'withdrawal_request'
         AND t.reference_id = v_w.id
    ) THEN
      RAISE EXCEPTION 'withdrawal % carries hold_ledger_transaction_id % which is not its withdrawal_request ledger transaction: refusing to approve an unexplained hold',
        v_w.id, v_w.hold_ledger_transaction_id
        USING ERRCODE = 'check_violation';
    END IF;
    v_tx := v_w.hold_ledger_transaction_id;
  ELSE
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
  END IF;

  UPDATE public.withdrawal_requests
     SET status = 'approved',
         approved_at = now(),
         hold_ledger_transaction_id = v_tx
   WHERE id = v_w.id
  RETURNING status INTO v_st;

  RETURN v_st;
END $fn$;

COMMENT ON FUNCTION public.approve_withdrawal(uuid) IS
  'Operator path: approve a pending or under-review withdrawal, which LOCKS the funds: one withdrawal_request ledger transaction debits the user''s available account and credits their locked account with amount+fee (zero-sum, both postings in the same transaction), recorded as hold_ledger_transaction_id. A row that ALREADY carries its hold (a client request from request_withdrawal, held at request time) is approved by confirming that hold — never by holding twice. Refuses an insufficient available balance, wrong-state approvals and — for a paper row — a switched-off paper sandbox. Idempotent on an already-approved row. service_role only.';

-- ---------------------------------------------------------------------------
-- 5. _withdrawal_close learns the `cancelled` outcome (the same release path)
--
-- Additive: 'cancelled' joins the accepted terminal statuses and is restricted to
-- a pending request. The release logic (one balanced withdrawal_refund, locked ->
-- available, recorded in released_ledger_transaction_id) is unchanged.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._withdrawal_close(
  p_withdrawal_id uuid,
  p_status        text,
  p_reason        text
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_w        public.withdrawal_requests;
  v_held     numeric;
  v_locked   uuid;
  v_avail    uuid;
  v_tx       uuid;
  v_st       text;
BEGIN
  IF p_status NOT IN ('failed', 'rejected', 'cancelled') THEN
    RAISE EXCEPTION 'unknown terminal withdrawal status %: only failed and rejected close a request (cancelled is the client''s own release of a still-pending request)', p_status
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

  -- >>> 20261005100200 (stage 7): a user cancel is only legal while the request is
  -- still pending — an operator review, an approval or a broadcast is a lock the
  -- client may not take back on its own.
  IF p_status = 'cancelled' AND v_w.status <> 'pending' THEN
    RAISE EXCEPTION 'withdrawal % is %: a user can only cancel a still-pending request (not one that is under review, approved or processing)',
      v_w.id, v_w.status
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
END $fn$;

COMMENT ON FUNCTION public._withdrawal_close(uuid, text, text) IS
  'Internal (not an entry point): the single release path of the withdrawal layer. Moves a non-terminal request to failed, rejected or cancelled and, if a hold was placed, posts one balanced withdrawal_refund transaction (locked -= amount+fee, available += amount+fee) recording it in released_ledger_transaction_id. cancelled is allowed only from pending (the client cancel). A request that was never approved releases nothing. Does NOT read the paper sandbox switch on purpose: locked funds must always be releasable.';

-- ---------------------------------------------------------------------------
-- 6. assert_kyc_path learns the user_client source (paper only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_kyc_path(p_source text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_mode text;
BEGIN
  IF p_source IS NULL OR p_source NOT IN ('paper_operator', 'provider_adapter', 'user_client') THEN
    RAISE EXCEPTION 'unknown KYC source %: expected paper_operator, provider_adapter or user_client', COALESCE(p_source, 'NULL')
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT mode INTO v_mode FROM public.app_settings WHERE id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'app_settings has no row: the KYC path gate cannot be evaluated'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF p_source = 'paper_operator' AND v_mode = 'live' THEN
    RAISE EXCEPTION
      'the operator (paper) KYC path is refused while the exchange is live (app_settings.mode = live): a live KYC decision must come from the provider adapter (record_provider_kyc_event)'
      USING ERRCODE = 'check_violation';
  END IF;

  -- >>> 20261005100200 (stage 7): a client KYC application is the paper path. While
  -- the exchange is live, an application must enter through the provider adapter, so
  -- no client row can be created that a provider would have to reconcile.
  IF p_source = 'user_client' AND v_mode = 'live' THEN
    RAISE EXCEPTION
      'user KYC submissions are not open while the exchange is live (app_settings.mode = live): a live application enters through the KYC provider adapter (record_provider_kyc_event)'
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_source = 'provider_adapter' AND v_mode <> 'live' THEN
    RAISE EXCEPTION
      'the provider adapter KYC path is live-only: app_settings.mode = % (use the operator path in the paper sandbox)',
      v_mode
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN v_mode;
END $fn$;

COMMENT ON FUNCTION public.assert_kyc_path(text) IS
  'The KYC path gate: refuses the operator/paper and user_client paths while app_settings.mode = live and the provider-adapter path unless mode = live. KYC carries no money, so it has no app_settings flag and the enforce_environment_gate trigger is deliberately not attached to these tables — the mode is the only switch.';

-- ---------------------------------------------------------------------------
-- 7. request_withdrawal — the client entry point (paper only in this stage)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_withdrawal(
  p_asset               text,
  p_network             text,
  p_amount_units        bigint,
  p_idempotency_key     text DEFAULT NULL,
  p_destination_address text DEFAULT NULL
)
RETURNS TABLE (request_id uuid, request_status text, existing boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid     uuid := auth.uid();
  v_key     text;
  v_id      uuid;
  v_st      text;
  v_w       public.withdrawal_requests;
  v_held    numeric;
  v_avail   uuid;
  v_locked  uuid;
  v_balance numeric;
  v_tx      uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'request_withdrawal: no authenticated user (auth.uid() is NULL): a withdrawal request belongs to exactly one signed-in user'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_amount_units IS NULL THEN
    RAISE EXCEPTION 'request_withdrawal: an amount in base units is required (whole units, never a fraction)'
      USING ERRCODE = 'null_value_not_allowed';
  END IF;
  IF p_amount_units <= 0 THEN
    RAISE EXCEPTION 'request_withdrawal: the amount must be a positive whole number of base units (got %)', p_amount_units
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_destination_address IS NULL OR btrim(p_destination_address) = '' THEN
    RAISE EXCEPTION 'request_withdrawal: a destination address is required (nothing is generated for you, and no address is verified here)'
      USING ERRCODE = 'null_value_not_allowed';
  END IF;

  v_key := NULLIF(btrim(COALESCE(p_idempotency_key, '')), '');
  IF v_key IS NOT NULL AND length(v_key) > 200 THEN
    RAISE EXCEPTION 'request_withdrawal: an idempotency key is at most 200 characters (got %)', length(v_key)
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- idempotency: a retry with the same key returns the existing request and moves
  -- no money. Nothing below runs for a known key.
  IF v_key IS NOT NULL THEN
    SELECT w.id, w.status INTO v_id, v_st
      FROM public.withdrawal_requests w
     WHERE w.user_id = v_uid AND w.idempotency_key = v_key;
    IF FOUND THEN
      RETURN QUERY SELECT v_id, v_st, true;
      RETURN;
    END IF;
  END IF;

  BEGIN
    v_id := public._withdrawal_ingest(
      'user_client', v_uid, upper(btrim(COALESCE(p_asset, ''))),
      lower(btrim(COALESCE(p_network, ''))), btrim(p_destination_address),
      p_amount_units::numeric, NULL, NULL, NULL,
      jsonb_build_object('client', 'user_request')
    );

    IF v_key IS NOT NULL THEN
      UPDATE public.withdrawal_requests w SET idempotency_key = v_key WHERE w.id = v_id;
    END IF;

    SELECT * INTO v_w FROM public.withdrawal_requests w WHERE w.id = v_id;

    -- the hold: available -> locked, the same ledger transaction shape the approval
    -- path uses, with the same idempotency key, so this request can never be held twice
    v_held   := v_w.amount_units + v_w.fee_units;
    v_avail  := public.ensure_user_account(v_uid, v_w.asset_id, 'available', v_w.environment);
    v_locked := public.ensure_user_account(v_uid, v_w.asset_id, 'locked',    v_w.environment);

    SELECT COALESCE(b.available_units, 0) INTO v_balance
      FROM public.balances b WHERE b.account_id = v_avail;
    v_balance := COALESCE(v_balance, 0);

    IF v_balance < v_held THEN
      RAISE EXCEPTION 'request_withdrawal: insufficient available balance: % units (amount % + fee %) are required, % available',
        v_held, v_w.amount_units, v_w.fee_units, v_balance
        USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO public.ledger_transactions (
      type, environment, idempotency_key, reference_type, reference_id, description, metadata
    )
    VALUES (
      'withdrawal_request', v_w.environment,
      'withdrawal_hold:' || v_w.id::text,
      'withdrawal_request', v_w.id,
      'withdrawal hold placed by the user request',
      jsonb_build_object(
        'network', v_w.network, 'amount_units', v_w.amount_units,
        'fee_units', v_w.fee_units, 'held_units', v_held,
        'source', v_w.source, 'held_by', 'user_client'
      )
    )
    RETURNING id INTO v_tx;

    PERFORM public.post_entry(v_tx, v_avail,  -v_held, 'withdrawal hold');
    PERFORM public.post_entry(v_tx, v_locked,  v_held, 'withdrawal hold');

    UPDATE public.withdrawal_requests w
       SET hold_ledger_transaction_id = v_tx
     WHERE w.id = v_id;

    RETURN QUERY SELECT v_id, 'pending'::text, false;
  EXCEPTION WHEN unique_violation THEN
    -- a concurrent call with the same key won the unique index: return its request,
    -- hold nothing. Any other unique violation is re-raised.
    IF v_key IS NOT NULL THEN
      SELECT w.id, w.status INTO v_id, v_st
        FROM public.withdrawal_requests w
       WHERE w.user_id = v_uid AND w.idempotency_key = v_key;
      IF v_id IS NOT NULL THEN
        RETURN QUERY SELECT v_id, v_st, true;
        RETURN;
      END IF;
    END IF;
    RAISE;
  END;
END $fn$;

COMMENT ON FUNCTION public.request_withdrawal(text, text, bigint, text, text) IS
  'CLIENT entry point (authenticated only): a signed-in user requests a withdrawal of p_amount_units base units of p_asset on p_network to p_destination_address. user_id is always auth.uid() — never a parameter — and an unauthenticated caller is refused. Paper-only in this stage (refused while app_settings.mode = live). Inherits every gate and validation of _withdrawal_ingest (live flag, paper sandbox, maintenance, account restriction, registered+enabled network, integer min/max, memo requirement, fee snapshot). HOLDS amount+fee on the caller''s available balance in one balanced ledger transaction, so a pending request cannot be spent twice. Idempotent on (caller, p_idempotency_key): a retry returns the existing request with existing = true and holds nothing. The request enters pending and only an operator (approve_withdrawal / reject_withdrawal / fail_withdrawal) can move it forward. Nothing is broadcast, no chain or provider is contacted, and the destination is NOT verified.';

-- ---------------------------------------------------------------------------
-- 8. cancel_my_withdrawal — the client's own release of a pending request
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_my_withdrawal(p_request_id uuid)
RETURNS TABLE (request_id uuid, request_status text, released_units numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid      uuid := auth.uid();
  v_w        public.withdrawal_requests;
  v_st       text;
  v_released numeric := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'cancel_my_withdrawal: no authenticated user (auth.uid() is NULL)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_request_id IS NULL THEN
    RAISE EXCEPTION 'cancel_my_withdrawal: a request id is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_w FROM public.withdrawal_requests w WHERE w.id = p_request_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown withdrawal request %', p_request_id USING ERRCODE = 'no_data_found';
  END IF;

  -- ownership, checked inside the function and not only by RLS
  IF v_w.user_id <> v_uid THEN
    RAISE EXCEPTION 'withdrawal request % does not belong to the caller: a user can only cancel their own request', v_w.id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF v_w.status <> 'pending' THEN
    RAISE EXCEPTION 'withdrawal request % is %: a user can only cancel a still-pending request (an operator review, an approval or a broadcast is a lock the user cannot take back)',
      v_w.id, v_w.status
      USING ERRCODE = 'check_violation';
  END IF;

  -- the release path: NOT gated by the paper sandbox switch or maintenance mode, for
  -- the same reason reject_withdrawal/fail_withdrawal are not — locked funds must
  -- always be releasable by their owner.
  IF v_w.hold_ledger_transaction_id IS NOT NULL THEN
    v_released := v_w.amount_units + v_w.fee_units;
  END IF;

  v_st := public._withdrawal_close(v_w.id, 'cancelled', 'cancelled by the user before operator review');

  RETURN QUERY SELECT v_w.id, v_st, v_released;
END $fn$;

COMMENT ON FUNCTION public.cancel_my_withdrawal(uuid) IS
  'CLIENT entry point (authenticated only): a signed-in user cancels their OWN still-pending withdrawal request. Refuses an unauthenticated caller, another user''s request (ownership is checked inside the function, not only by RLS) and any request that is no longer pending. Releases exactly the hold placed by request_withdrawal (locked -> available, one balanced withdrawal_refund through _withdrawal_close), returns the released amount, and sets the status to the terminal cancelled. Not gated by the paper sandbox switch or maintenance mode: a user can always take their own pending request back. Moves no other money.';

-- ---------------------------------------------------------------------------
-- 9. submit_my_kyc — the client KYC application (paper only in this stage)
--
-- Named submit_my_kyc (not submit_kyc) on purpose: submit_kyc(p_user_id, p_level,
-- ...) is the OPERATOR path and is service_role only. The KYC suite's static ACL
-- probe asserts that no function named submit_kyc is executable by
-- `authenticated`; a second overload under the same name would either break that
-- assertion or force it to be weakened. The client path therefore gets its own
-- name, mirroring my_kyc_status().
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_my_kyc(
  p_tier_code text,
  p_documents jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE (submission_id uuid, submission_status text, existing boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid   uuid := auth.uid();
  v_code  text;
  v_level smallint;
  v_docs  jsonb;
  v_id    uuid;
  v_st    text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'submit_my_kyc: no authenticated user (auth.uid() is NULL): a KYC application belongs to exactly one signed-in user'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_code := lower(btrim(COALESCE(p_tier_code, '')));
  IF v_code = '' THEN
    RAISE EXCEPTION 'submit_my_kyc: a tier code is required (identity, address)'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT l.level INTO v_level FROM public.kyc_levels l WHERE lower(l.name) = v_code;
  IF v_level IS NULL THEN
    RAISE EXCEPTION 'submit_my_kyc: unknown KYC tier % (see kyc_levels: identity, address)', p_tier_code
      USING ERRCODE = 'no_data_found';
  END IF;
  IF v_level < 1 THEN
    RAISE EXCEPTION 'submit_my_kyc: tier % is the default unverified level and cannot be applied for (a submission seeks identity or address)', p_tier_code
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_docs := COALESCE(p_documents, '{}'::jsonb);
  IF jsonb_typeof(v_docs) <> 'object' THEN
    RAISE EXCEPTION 'submit_my_kyc: documents must be a JSON object of opaque references (got %)', jsonb_typeof(v_docs)
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- paper only in this stage: refused while the exchange is live
  PERFORM public.assert_kyc_path('user_client');

  -- one OPEN application per user per tier: a retry returns it, it does not duplicate
  SELECT s.id, s.status INTO v_id, v_st
    FROM public.kyc_submissions s
   WHERE s.user_id = v_uid
     AND s.level_sought = v_level
     AND s.source = 'user_client'
     AND s.status IN ('pending', 'under review')
   ORDER BY s.created_at DESC
   LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN QUERY SELECT v_id, v_st, true;
    RETURN;
  END IF;

  -- the audit trigger records who did this: a user, not an operator and not a provider
  PERFORM set_config('gtvx.actor_role', 'user', true);
  PERFORM set_config('gtvx.actor_id', v_uid::text, true);

  BEGIN
    -- level 0 (unverified) is materialised, never raised: this function cannot grant a level
    PERFORM public.ensure_kyc_status(v_uid);

    INSERT INTO public.kyc_submissions (
      user_id, level_sought, environment, source, status, metadata, raw
    )
    VALUES (
      v_uid, v_level, 'paper', 'user_client', 'pending', v_docs,
      jsonb_build_object('client', 'user_submission')
    )
    RETURNING id INTO v_id;

    RETURN QUERY SELECT v_id, 'pending'::text, false;
  EXCEPTION WHEN unique_violation THEN
    -- a concurrent application for the same tier won kyc_submissions_user_open_key
    SELECT s.id, s.status INTO v_id, v_st
      FROM public.kyc_submissions s
     WHERE s.user_id = v_uid
       AND s.level_sought = v_level
       AND s.source = 'user_client'
       AND s.status IN ('pending', 'under review')
     ORDER BY s.created_at DESC
     LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN QUERY SELECT v_id, v_st, true;
      RETURN;
    END IF;
    RAISE;
  END;
END $fn$;

COMMENT ON FUNCTION public.submit_my_kyc(text, jsonb) IS
  'CLIENT entry point (authenticated only): a signed-in user applies for a KYC tier (identity | address) with a JSON object of OPAQUE references. user_id is always auth.uid(). The row enters status pending — NEVER approved and never a level: only approve_kyc() (operator) or record_provider_kyc_event() (a real provider event) can decide it, and both are service_role only. The existing no-PII denylist trigger refuses any personal data in the payload. One open application per user per tier (a retry returns it with existing = true); a resubmission after a final decision is a new row. Paper only in this stage: refused while app_settings.mode = live. Audited by the existing trigger with actor_role = user and actor_id = auth.uid().';

-- ---------------------------------------------------------------------------
-- 10. grants: the three wrappers are executable by `authenticated` and nobody
--     else. service_role is deliberately NOT granted — it keeps the operator
--     surface it already had, and a user never reaches a service-role permission.
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.request_withdrawal(text, text, bigint, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.request_withdrawal(text, text, bigint, text, text) FROM anon;
REVOKE ALL ON FUNCTION public.request_withdrawal(text, text, bigint, text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public.request_withdrawal(text, text, bigint, text, text) FROM service_role;
GRANT EXECUTE ON FUNCTION public.request_withdrawal(text, text, bigint, text, text) TO authenticated;

REVOKE ALL ON FUNCTION public.cancel_my_withdrawal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cancel_my_withdrawal(uuid) FROM anon;
REVOKE ALL ON FUNCTION public.cancel_my_withdrawal(uuid) FROM authenticated;
REVOKE ALL ON FUNCTION public.cancel_my_withdrawal(uuid) FROM service_role;
GRANT EXECUTE ON FUNCTION public.cancel_my_withdrawal(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.submit_my_kyc(text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.submit_my_kyc(text, jsonb) FROM anon;
REVOKE ALL ON FUNCTION public.submit_my_kyc(text, jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.submit_my_kyc(text, jsonb) FROM service_role;
GRANT EXECUTE ON FUNCTION public.submit_my_kyc(text, jsonb) TO authenticated;

-- the replaced internal/operator functions keep their previous ACL: PUBLIC and the
-- client roles are revoked, service_role keeps it (same pattern as migrations
-- 20261005100130 / …140 / …150)
DO $q$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
         'assert_kyc_path', '_withdrawal_ingest', 'approve_withdrawal', '_withdrawal_close'
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
END $q$;

-- (withdrawal_requests_before_update is a trigger function and keeps the default
-- EXECUTE grant on purpose: PostgreSQL checks EXECUTE with the invoking role.)

-- ---------------------------------------------------------------------------
-- 11. own-row reads
--
-- No new policy is added: migration 130 already created
-- withdrawal_requests_select_own (USING user_id = auth.uid()) and migration 140
-- kyc_submissions_select_own (same shape), both FOR SELECT TO authenticated, and
-- this migration adds no write policy at all. A client therefore reads exactly its
-- own requests and applications and can write only through the three wrappers.
-- The new column and the new statuses need no policy change; the table-level
-- SELECT grant covers the added column.
-- ---------------------------------------------------------------------------
COMMENT ON TABLE public.withdrawal_requests IS
  'One row per withdrawal request: the owner''s state machine (pending/under review/approved/processing/completed/failed/rejected/cancelled), the requested amount, the fee snapshot, the destination supplied by the caller, the provider txid and the three ledger transactions that hold, settle or release the money. Written only by _withdrawal_ingest (operator, provider adapter and user_client paths), the operator transitions (service_role) and cancel_my_withdrawal() (the client''s own release of a pending request) — a client role has no INSERT/UPDATE/DELETE privilege at all. Unique (environment, network, provider_txid) and unique (user_id, idempotency_key).';
