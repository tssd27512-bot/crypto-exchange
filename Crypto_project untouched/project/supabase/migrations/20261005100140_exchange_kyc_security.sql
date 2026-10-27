/*
# Migration 11 — KYC tier model, submission state machine, provider-adapter contract and
# the security audit log

Purpose
-------
The database layer of identity verification (step 8 of the build order): the TIER MODEL,
the per-user KYC status, the submission state machine with its two separated paths (operator
/ provider adapter) and an append-only security audit log.

**Provider-agnostic by design.** No vendor is integrated, selected or referenced: no SDK, no
endpoint, no credential, no API key, no polling job and no seeded provider row. The vendor
choice is the owner's open decision (plan, open decision #1). Everything here is the shape a
future vendor adapter has to fit into.

**No personal data in the database.** This is a hard rule, not a preference:

*        NOT stored here: names, dates of birth, e-mail/phone, postal addresses, national ID
         or passport numbers, documents (images/PDFs/base64), selfies, signatures, bank details.
*        ONLY stored here: opaque REFERENCES to whatever the vendor holds — a document id, a
         content hash, a vendor "applicant id" — inside `kyc_submissions.metadata` (jsonb) and
         `kyc_submissions.provider_reference`. The document bytes live wherever the future
         vendor stores them; the storage location is part of the vendor decision and is
         deliberately NOT decided in this migration.
*        The rule is ENFORCED, not just documented: `public.kyc_metadata_guard` (trigger) walks
         `metadata`/`raw` recursively and refuses a denylisted key (name, dob, email, address,
         passport, id_number, document_image, selfie, iban, ... see `_kyc_pii_key_path`), so a
         careless operator or a careless adapter cannot turn this table into a PII store.

Tier model (`kyc_levels`)
-------------------------
    level 0  unverified      the default every user starts at (see `kyc_status`)
    level 1  identity        an identity document was verified by an operator or a provider
    level 2  address         identity + proof of address verified

Levels 0-2 are SEEDED (reference data: level, name, description). **No numeric limit is
invented**: withdrawal caps, deposit caps, trading caps or any other per-tier limit are an
OWNER decision (they depend on the custody model and the vendor) and are therefore NOT part of
this schema. There is no `max_withdrawal_units` column, no `limits` jsonb and no implied
policy. Nothing in the money layers reads KYC — **no money path is gated on KYC in this
migration** (`app_settings.kyc_required_for_trading` already exists and is untouched).

Per-user status (`kyc_status`)
-----------------------------
One row per user, materialised at level 0 on first reference (`ensure_kyc_status`,
`my_kyc_status`). The level is **only** changeable upwards and **only** to a level that has an
approved submission: the `kyc_status_before_update` trigger refuses any other level change, so
"the level follows approvals" is a database invariant and not just an entry-point convention.
Downgrade / expiry / re-verification-after-sanctions-hit are NOT implemented here (flagged
for the owner — a downgrade needs a policy for what happens to open orders and locked funds).

Submission state machine (`kyc_submissions`)
-------------------------------------------
    pending        submitted, waiting for a decision
    under review   an operator/provider review is in progress
    approved       terminal: the level was granted (kyc_status.level updated atomically)
    rejected       terminal: refused; the user's level is unchanged; resubmission = new row

        pending      --> under review | approved | rejected
        under review --> approved | rejected
        approved     --> (terminal)      rejected --> (terminal)

    As with withdrawals, the requested "pending -> under review -> approved" shape can be read
    as "review is mandatory"; BOTH pending -> approved and pending -> under review -> approved
    are allowed, and whether review is mandatory (or only above a threshold) is an OWNER policy
    decision that is not invented here.

    Resubmission is always a NEW row: an approved/rejected row is immutable (trigger), so a
    user who failed level 1 submits again at level 1 and a new submission id is created. The
    old row stays as evidence.

Paper vs live: two paths, distinguishable in the data
-----------------------------------------------------
| source             | environment | entry point                    | who calls it                     |
|--------------------|-------------|--------------------------------|----------------------------------|
| `paper_operator`   | `paper`     | submit_kyc / approve_kyc / ...  | operator or test harness, paper  |
| `provider_adapter` | `live`      | record_provider_kyc_event()     | the live KYC provider adapter    |

The pairing is pinned by CHECK (exactly as in the deposit/withdrawal layers) and each path is
refused outside its mode by `assert_kyc_path()`: the operator path raises while
`app_settings.mode = 'live'`, the adapter path raises unless `mode = 'live'`.

NOTE (deliberate): KYC is NOT a money path, so it has NO `app_settings` flag and the
`enforce_environment_gate` trigger is deliberately NOT attached to these tables (that trigger
maps unknown tables to the trading flag and a live KYC row must not require live trading).
The path gate is `app_settings.mode` alone. **No app_settings column is added or changed by
this migration.**

Provider adapter contract
-------------------------
`record_provider_kyc_event(p_event jsonb) RETURNS uuid` — the only interface a future vendor
adapter implements. Nothing else in this layer reads provider-specific data.

    { "event_type":           "approve" | "reject" | "under_review",  -- required
      "user_id":              "<uuid>",                               -- required
      "submission_reference": "<vendor submission/applicant id>",     -- required, idempotency key
      "provider":             "<vendor name>",                        -- optional
      "level_sought":         1,                                      -- required only when the
                                                                      --   event CREATES the row
      "reason":               "<free text>",                          -- optional
      "metadata":             { ... references only, no PII ... },    -- optional
      ... any further provider fields are preserved verbatim in raw }

A missing required key, a non-object event, an unknown `event_type` or a non-uuid `user_id` is
refused as an *adapter contract violation* (`invalid_parameter_value`) and NOTHING is recorded.
Idempotency is the pair (provider, provider_reference), UNIQUE: replaying a terminal event
(approve/reject) for a reference that already reached its decision raises and records nothing —
a replayed vendor callback can never grant a second level. The adapter itself (HTTP client,
signature verification, polling, webhook handling, document upload) is NOT implemented here.

Security audit log (`security_audit_log`)
----------------------------------------
Append-only (the ledger's `reject_mutation` pattern): UPDATE and DELETE are refused by trigger
for every role including the owner, and by privilege for anon/authenticated/service_role. One
row per KYC submission status change and per KYC level change, written by the AFTER triggers
(`kyc_submissions_audit`, `kyc_status_audit`) — so both paths are audited, including a change
made by a privileged role that bypasses the entry points. The actor comes from the
transaction-local settings `gtvx.actor_role` / `gtvx.actor_id`, which the entry points set:
`operator` for the paper/operator path, `provider_adapter` for the vendor path, `system`
when nothing set it. No operator identity system exists yet (step 9 admin/operator controls),
so `actor_id` is NULL on the operator path — flagged, not faked.

This step is a FOCUSED security architecture, not a general security log: it covers KYC and
any future caller can add its own actions. AML/sanctions/PEP screening, session/device
tracking, rate limiting and login history are explicitly out of scope (see below).

Deliberately NOT implemented in this step (flagged for the owner)
-----------------------------------------------------------------
* Per-tier limits (withdrawal/deposit/trading caps), and gating any money path on KYC.
* Vendor selection, document upload/storage, address verification, liveness checks.
* AML / sanctions / PEP screening (provider-dependent; needs a vendor and a policy).
* Level downgrade, expiry or re-verification; what happens to open orders on a downgrade.
* Operator identity/authentication, review quorum, SLA, and who may approve — step 9.
* Enforcement on the trading/deposit/withdrawal paths: this migration only records trust.
*/

-- ---------------------------------------------------------------------------
-- kyc_levels — the tier model (reference data; NO limits are invented here)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kyc_levels (
  level smallint PRIMARY KEY,
  name text NOT NULL UNIQUE,
  description text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kyc_levels_level_check CHECK (level >= 0),
  CONSTRAINT kyc_levels_name_check CHECK (length(btrim(name)) BETWEEN 1 AND 60),
  CONSTRAINT kyc_levels_description_check CHECK (length(btrim(description)) BETWEEN 1 AND 500)
);

-- The three tiers of the plan's step 8. Names/descriptions only: NO numeric limit, NO
-- provider, NO document requirement list — those are owner/vendor decisions.
INSERT INTO public.kyc_levels (level, name, description) VALUES
  (0, 'unverified', 'Default for every user. No identity check has been performed.'),
  (1, 'identity',   'Identity verified: an identity document was checked by an operator or a KYC provider.'),
  (2, 'address',    'Identity and address verified: identity plus proof of address were checked.')
ON CONFLICT (level) DO NOTHING;

COMMENT ON TABLE public.kyc_levels IS
  'The KYC tier model: level 0 unverified (default), 1 identity, 2 address. Reference data only. Deliberately carries NO per-tier limits (withdrawal/deposit/trading caps) — those are an owner decision that depends on the custody model and the vendor, and no money path is gated on KYC in this migration.';
COMMENT ON COLUMN public.kyc_levels.level IS
  'Tier number. 0 is the unverified default a user holds before any approved submission. Only these rows may be referenced by kyc_status.level / kyc_submissions.level_sought.';

-- ---------------------------------------------------------------------------
-- kyc_submissions — one row per application, provider-agnostic, no PII
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kyc_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  level_sought smallint NOT NULL REFERENCES public.kyc_levels(level) ON DELETE RESTRICT,
  environment text NOT NULL DEFAULT 'paper',
  source text NOT NULL DEFAULT 'paper_operator',
  status text NOT NULL DEFAULT 'pending',
  provider text,
  provider_reference text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  raw jsonb NOT NULL DEFAULT '{}'::jsonb,
  review_reason text,
  decision_reason text,
  under_review_at timestamptz,
  decided_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kyc_submissions_level_check CHECK (level_sought >= 1),
  CONSTRAINT kyc_submissions_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT kyc_submissions_status_check CHECK (status IN ('pending', 'under review', 'approved', 'rejected')),
  CONSTRAINT kyc_submissions_source_check CHECK (source IN ('paper_operator', 'provider_adapter')),
  -- which path produced the row is part of the row, and the two paths cannot mix
  CONSTRAINT kyc_submissions_source_environment_check CHECK (
    (source = 'provider_adapter') = (environment = 'live')
  ),
  -- the idempotency pair travels together: a provider reference without a provider name
  -- would be unmatchable (and would defeat the unique index below, because NULLs are
  -- distinct in a unique index)
  CONSTRAINT kyc_submissions_provider_pair_check CHECK (
    (provider IS NULL) = (provider_reference IS NULL)
  ),
  CONSTRAINT kyc_submissions_provider_check CHECK (
    provider IS NULL OR (length(btrim(provider)) BETWEEN 1 AND 60 AND provider !~ '\s')
  ),
  CONSTRAINT kyc_submissions_provider_reference_check CHECK (
    provider_reference IS NULL OR length(btrim(provider_reference)) BETWEEN 1 AND 200
  ),
  -- no PII: only opaque references, so metadata and raw must be JSON objects
  CONSTRAINT kyc_submissions_metadata_check CHECK (jsonb_typeof(metadata) = 'object'),
  CONSTRAINT kyc_submissions_raw_check CHECK (jsonb_typeof(raw) = 'object'),
  CONSTRAINT kyc_submissions_decided_at_check CHECK (
    (status IN ('approved', 'rejected')) = (decided_at IS NOT NULL)
  ),
  CONSTRAINT kyc_submissions_under_review_at_check CHECK (
    status <> 'under review' OR under_review_at IS NOT NULL
  ),
  CONSTRAINT kyc_submissions_rejected_reason_check CHECK (
    status <> 'rejected' OR (decision_reason IS NOT NULL AND btrim(decision_reason) <> '')
  )
);

-- idempotency of the provider adapter: one provider reference identifies ONE submission,
-- ever — a replayed vendor callback cannot create a second application
CREATE UNIQUE INDEX IF NOT EXISTS kyc_submissions_provider_reference_key
  ON public.kyc_submissions (provider, provider_reference)
  WHERE provider_reference IS NOT NULL;

CREATE INDEX IF NOT EXISTS kyc_submissions_user_idx
  ON public.kyc_submissions (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS kyc_submissions_status_idx
  ON public.kyc_submissions (environment, status, created_at DESC);
CREATE INDEX IF NOT EXISTS kyc_submissions_source_idx
  ON public.kyc_submissions (source, status, created_at DESC);
CREATE INDEX IF NOT EXISTS kyc_submissions_level_idx
  ON public.kyc_submissions (user_id, level_sought, status);

COMMENT ON TABLE public.kyc_submissions IS
  'One row per KYC application: the level sought, the provider-agnostic state machine (pending | under review | approved | rejected), the path that produced it (source + environment) and the (provider, provider_reference) idempotency pair. Deliberately contains NO personal data: metadata/raw hold opaque references only (document ids, content hashes, vendor applicant ids) and a denylist trigger refuses PII keys. Written only by the entry points (service_role) — a client role has no write path. Resubmission is a new row; approved/rejected rows are immutable.';
COMMENT ON COLUMN public.kyc_submissions.metadata IS
  'Opaque references to what the vendor holds (document id, content hash, applicant id) — NEVER names, dates of birth, e-mail/phone, addresses, document numbers or document bytes. Enforced by the kyc_metadata_guard trigger (_kyc_pii_key_path denylist). Document storage belongs to the future vendor integration and is not decided here.';
COMMENT ON COLUMN public.kyc_submissions.provider_reference IS
  'The provider''s own identifier for this application. Write-once; UNIQUE (provider, provider_reference) — the idempotency key of the adapter contract. NULL on the operator path until a vendor exists.';
COMMENT ON COLUMN public.kyc_submissions.source IS
  'Which path produced this row: paper_operator (operator/test harness, paper only) or provider_adapter (live KYC provider adapter, live only). Paired with environment by CHECK.';
COMMENT ON COLUMN public.kyc_submissions.status IS
  'pending | under review | approved | rejected. approved (the level was granted) and rejected are terminal and immutable; the user''s level only ever moves on approved.';
COMMENT ON COLUMN public.kyc_submissions.decision_reason IS
  'Why the submission was rejected (mandatory when rejected) or a note recorded on approval. Free text written by an operator/adapter — never paste personal data here (the audit log copies it).';

-- ---------------------------------------------------------------------------
-- kyc_status — one row per user, materialised at level 0 (unverified)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kyc_status (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
  level smallint NOT NULL DEFAULT 0 REFERENCES public.kyc_levels(level) ON DELETE RESTRICT,
  provider text,
  level_changed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT kyc_status_provider_check CHECK (
    provider IS NULL OR (length(btrim(provider)) BETWEEN 1 AND 60 AND provider !~ '\s')
  )
);

COMMENT ON TABLE public.kyc_status IS
  'Per-user KYC level, one row per user, created at level 0 (unverified) on first reference. The level moves UP only, and only to a level that has an approved kyc_submissions row (kyc_status_before_update trigger): "the level follows approvals" is a database invariant, not an entry-point convention. provider is NULL until a vendor is selected.';
COMMENT ON COLUMN public.kyc_status.level IS
  'Current verified tier (kyc_levels.level). Changed only by approve_kyc() / record_provider_kyc_event(), atomically with the approval and with a security_audit_log row.';
COMMENT ON COLUMN public.kyc_status.provider IS
  'Which provider verified the current level, once a vendor exists. NULL while verification is operator-only (paper sandbox) or before the owner chooses a vendor.';

-- ---------------------------------------------------------------------------
-- security_audit_log — append-only security audit trail
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.security_audit_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  at timestamptz NOT NULL DEFAULT now(),
  actor_role text NOT NULL DEFAULT 'system',
  actor_id uuid,
  subject_user_id uuid REFERENCES auth.users(id) ON DELETE RESTRICT,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT security_audit_log_actor_role_check CHECK (
    actor_role IN ('system', 'operator', 'provider_adapter', 'user')
  ),
  CONSTRAINT security_audit_log_action_check CHECK (length(btrim(action)) BETWEEN 3 AND 120),
  CONSTRAINT security_audit_log_entity_type_check CHECK (length(btrim(entity_type)) BETWEEN 1 AND 60),
  CONSTRAINT security_audit_log_details_check CHECK (jsonb_typeof(details) = 'object')
);

CREATE INDEX IF NOT EXISTS security_audit_log_subject_idx
  ON public.security_audit_log (subject_user_id, at DESC);
CREATE INDEX IF NOT EXISTS security_audit_log_action_idx
  ON public.security_audit_log (action, at DESC);
CREATE INDEX IF NOT EXISTS security_audit_log_entity_idx
  ON public.security_audit_log (entity_type, entity_id);

-- append-only, exactly like the ledger: the trigger refuses UPDATE/DELETE for EVERY role,
-- including the table owner and service_role
DROP TRIGGER IF EXISTS security_audit_log_immutable ON public.security_audit_log;
CREATE TRIGGER security_audit_log_immutable
  BEFORE UPDATE OR DELETE ON public.security_audit_log
  FOR EACH ROW EXECUTE FUNCTION public.reject_mutation();

COMMENT ON TABLE public.security_audit_log IS
  'Append-only security audit trail (the ledger''s immutability pattern: UPDATE and DELETE are refused by trigger for every role and by privilege for the client roles). One row per KYC submission status change and per KYC level change, written by the AFTER triggers so BOTH paths are covered. Users may read their own rows (subject_user_id = auth.uid()); service_role reads all; anon has nothing. actor_id is NULL when the actor is the provider adapter or "system" — there is no operator identity system yet (step 9).';
COMMENT ON COLUMN public.security_audit_log.actor_role IS
  'system | operator | provider_adapter | user — taken from the transaction-local setting gtvx.actor_role, which the entry points set; defaults to system.';
COMMENT ON COLUMN public.security_audit_log.details IS
  'Structured context of the change (from/to status, from/to level, source, provider, reason). Never personal data.';

-- ---------------------------------------------------------------------------
-- no-PII guard: a recursive denylist over the jsonb that reaches this schema
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._kyc_pii_key_path(p_value jsonb, p_path text DEFAULT '')
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_key text;
  v_val jsonb;
  v_hit text;
  -- Exact (case-insensitive) key names that would turn this schema into a PII store.
  -- Exact match on purpose: 'document_id' is a reference and allowed, 'passport_number' is not.
  v_deny constant text[] := ARRAY[
    'name', 'full_name', 'first_name', 'last_name', 'middle_name', 'maiden_name',
    'dob', 'date_of_birth', 'birth_date', 'birthdate',
    'email', 'email_address', 'phone', 'phone_number', 'mobile',
    'address', 'address_line1', 'address_line2', 'street', 'street_address',
    'postal_code', 'postcode', 'zip', 'zip_code', 'city', 'town', 'country',
    'ssn', 'social_security_number', 'tax_id', 'tin', 'national_id', 'national_id_number',
    'id_number', 'id_document_number', 'document_number', 'passport', 'passport_number',
    'drivers_license', 'driver_license', 'licence_number',
    'document_image', 'document_images', 'document_file', 'document_files',
    'document_front', 'document_back', 'front_image', 'back_image', 'scan', 'scan_image',
    'selfie', 'selfie_image', 'photo', 'signature', 'signature_image',
    'iban', 'bank_account', 'account_number', 'card_number', 'routing_number'
  ];
BEGIN
  IF p_value IS NULL THEN
    RETURN NULL;
  END IF;

  IF jsonb_typeof(p_value) = 'object' THEN
    FOR v_key, v_val IN SELECT key, value FROM jsonb_each(p_value) LOOP
      IF lower(btrim(v_key)) = ANY (v_deny) THEN
        RETURN CASE WHEN p_path = '' THEN v_key ELSE p_path || '.' || v_key END;
      END IF;
      v_hit := public._kyc_pii_key_path(
        v_val, CASE WHEN p_path = '' THEN v_key ELSE p_path || '.' || v_key END);
      IF v_hit IS NOT NULL THEN
        RETURN v_hit;
      END IF;
    END LOOP;
  ELSIF jsonb_typeof(p_value) = 'array' THEN
    FOR v_val IN SELECT value FROM jsonb_array_elements(p_value) LOOP
      v_hit := public._kyc_pii_key_path(v_val, p_path);
      IF v_hit IS NOT NULL THEN
        RETURN v_hit;
      END IF;
    END LOOP;
  END IF;

  RETURN NULL;
END $$;

COMMENT ON FUNCTION public._kyc_pii_key_path(jsonb, text) IS
  'Returns the dotted path of the first personal-data key found in a jsonb value (recursively through objects and arrays), or NULL. Exact, case-insensitive key match against a denylist of names, dates of birth, contact details, postal addresses, identity/bank document numbers and document/selfie images. Used by kyc_metadata_guard to keep PII out of the database.';

CREATE OR REPLACE FUNCTION public.kyc_metadata_guard()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_hit text;
BEGIN
  v_hit := public._kyc_pii_key_path(NEW.metadata, 'metadata');
  IF v_hit IS NOT NULL THEN
    RAISE EXCEPTION
      'KYC submission refused: % carries personal data (%). This schema stores opaque references only (document id, content hash, provider applicant id); names, dates of birth, contact details, addresses, document numbers and document images must stay with the KYC provider. See the migration header.',
      'metadata', v_hit
      USING ERRCODE = 'check_violation';
  END IF;

  v_hit := public._kyc_pii_key_path(NEW.raw, 'raw');
  IF v_hit IS NOT NULL THEN
    RAISE EXCEPTION
      'KYC submission refused: % carries personal data (%). Only opaque references and provider identifiers may be stored; a provider adapter must strip PII before it reaches the database.',
      'raw', v_hit
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS kyc_submissions_pii_guard ON public.kyc_submissions;
CREATE TRIGGER kyc_submissions_pii_guard
  BEFORE INSERT OR UPDATE ON public.kyc_submissions
  FOR EACH ROW EXECUTE FUNCTION public.kyc_metadata_guard();

COMMENT ON FUNCTION public.kyc_metadata_guard() IS
  'Trigger: refuses an INSERT/UPDATE of kyc_submissions whose metadata or raw contains a denylisted personal-data key. Enforces the no-PII-in-the-database rule instead of merely documenting it.';

-- ---------------------------------------------------------------------------
-- submission state machine + terminal immutability
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kyc_submissions_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_allowed boolean;
BEGIN
  -- approved/rejected are terminal: the decision and its evidence can never be edited
  IF OLD.status IN ('approved', 'rejected') THEN
    RAISE EXCEPTION
      'KYC submission % is % (terminal): an approved or rejected submission is immutable — submit a new application instead',
      OLD.id, OLD.status
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.user_id <> OLD.user_id
     OR NEW.level_sought <> OLD.level_sought
     OR NEW.environment <> OLD.environment
     OR NEW.source <> OLD.source THEN
    RAISE EXCEPTION
      'the identity of KYC submission % is immutable (user, level sought, environment and source can never change: reject it and submit a new application)',
      OLD.id
      USING ERRCODE = 'check_violation';
  END IF;

  -- the provider idempotency pair is write-once
  IF OLD.provider_reference IS NOT NULL
     AND (NEW.provider_reference IS DISTINCT FROM OLD.provider_reference
          OR NEW.provider IS DISTINCT FROM OLD.provider) THEN
    RAISE EXCEPTION 'the provider reference of KYC submission % is write-once (% -> %)',
      OLD.id, OLD.provider_reference, NEW.provider_reference
      USING ERRCODE = 'check_violation';
  END IF;

  -- the state machine; every unlisted transition raises
  IF NEW.status <> OLD.status THEN
    v_allowed := CASE OLD.status
                   WHEN 'pending'      THEN NEW.status IN ('under review', 'approved', 'rejected')
                   WHEN 'under review' THEN NEW.status IN ('approved', 'rejected')
                   ELSE false
                 END;
    IF NOT v_allowed THEN
      RAISE EXCEPTION 'illegal KYC status transition on submission %: % -> % (% is terminal or the step is not part of the state machine)',
        OLD.id, OLD.status, NEW.status, OLD.status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS kyc_submissions_before_update ON public.kyc_submissions;
CREATE TRIGGER kyc_submissions_before_update
  BEFORE UPDATE ON public.kyc_submissions
  FOR EACH ROW EXECUTE FUNCTION public.kyc_submissions_before_update();

COMMENT ON FUNCTION public.kyc_submissions_before_update() IS
  'Trigger: enforces the KYC submission state machine (pending -> under review|approved|rejected, under review -> approved|rejected), the immutability of the submission identity, of the provider idempotency pair, and the total immutability of an approved/rejected row. Statuses are only reachable through the SECURITY DEFINER entry points: anon/authenticated have no UPDATE privilege at all.';

-- ---------------------------------------------------------------------------
-- the per-user status: level follows approvals, upwards only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kyc_status_before_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.user_id <> OLD.user_id THEN
    RAISE EXCEPTION 'the owner of a kyc_status row is immutable (% -> %)', OLD.user_id, NEW.user_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.level <> OLD.level THEN
    IF NEW.level < OLD.level THEN
      RAISE EXCEPTION
        'kyc_status level can only move up: % -> % (a downgrade/expiry policy is an owner decision and is not implemented)',
        OLD.level, NEW.level
        USING ERRCODE = 'check_violation';
    END IF;

    -- the invariant: a level exists because an approved submission granted it
    IF NOT EXISTS (
      SELECT 1 FROM public.kyc_submissions s
       WHERE s.user_id = NEW.user_id
         AND s.level_sought = NEW.level
         AND s.status = 'approved'
    ) THEN
      RAISE EXCEPTION
        'kyc_status level cannot move to % for user %: no approved submission grants that level (levels change only through approve_kyc() / record_provider_kyc_event())',
        NEW.level, NEW.user_id
        USING ERRCODE = 'check_violation';
    END IF;

    NEW.level_changed_at := now();
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS kyc_status_before_update ON public.kyc_status;
CREATE TRIGGER kyc_status_before_update
  BEFORE UPDATE ON public.kyc_status
  FOR EACH ROW EXECUTE FUNCTION public.kyc_status_before_update();

COMMENT ON FUNCTION public.kyc_status_before_update() IS
  'Trigger: a kyc_status row cannot change owner, cannot be downgraded, and can only move to a level that has an approved kyc_submissions row for that user. Makes "the level follows approvals, atomically" a database invariant.';

-- ---------------------------------------------------------------------------
-- the audit triggers (both paths, one row per status change / level change)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kyc_submissions_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor text;
  v_actor_id uuid;
  v_action text;
BEGIN
  v_actor := COALESCE(NULLIF(current_setting('gtvx.actor_role', true), ''), 'system');
  v_actor_id := NULLIF(current_setting('gtvx.actor_id', true), '')::uuid;

  IF TG_OP = 'INSERT' THEN
    INSERT INTO public.security_audit_log (
      actor_role, actor_id, subject_user_id, action, entity_type, entity_id, details
    ) VALUES (
      v_actor, v_actor_id, NEW.user_id, 'kyc.submission.submitted', 'kyc_submission', NEW.id,
      jsonb_build_object(
        'status', NEW.status, 'level_sought', NEW.level_sought, 'source', NEW.source,
        'environment', NEW.environment, 'provider', NEW.provider,
        'provider_reference', NEW.provider_reference
      )
    );

    -- a row that is created already decided (the provider adapter's straight-through
    -- approve) is TWO events: the submission and the decision. Both must be audited, or
    -- "every approved submission has an approval audit row" would not hold.
    IF NEW.status <> 'pending' THEN
      INSERT INTO public.security_audit_log (
        actor_role, actor_id, subject_user_id, action, entity_type, entity_id, details
      ) VALUES (
        v_actor, v_actor_id, NEW.user_id,
        'kyc.submission.' || replace(NEW.status, ' ', '_'), 'kyc_submission', NEW.id,
        jsonb_build_object(
          'from', 'none', 'to', NEW.status, 'level_sought', NEW.level_sought,
          'source', NEW.source, 'environment', NEW.environment, 'provider', NEW.provider,
          'provider_reference', NEW.provider_reference, 'reason', NEW.decision_reason
        )
      );
    END IF;
    RETURN NULL;
  END IF;

  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NULL;   -- an update that did not change the status is not a security event
  END IF;

  v_action := 'kyc.submission.' || replace(NEW.status, ' ', '_');
  INSERT INTO public.security_audit_log (
    actor_role, actor_id, subject_user_id, action, entity_type, entity_id, details
  ) VALUES (
    v_actor, v_actor_id, NEW.user_id, v_action, 'kyc_submission', NEW.id,
    jsonb_build_object(
      'from', OLD.status, 'to', NEW.status, 'level_sought', NEW.level_sought,
      'source', NEW.source, 'environment', NEW.environment, 'provider', NEW.provider,
      'provider_reference', NEW.provider_reference, 'reason', NEW.decision_reason
    )
  );
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS kyc_submissions_audit ON public.kyc_submissions;
CREATE TRIGGER kyc_submissions_audit
  AFTER INSERT OR UPDATE ON public.kyc_submissions
  FOR EACH ROW EXECUTE FUNCTION public.kyc_submissions_audit();

COMMENT ON FUNCTION public.kyc_submissions_audit() IS
  'Trigger: writes one security_audit_log row per KYC submission creation and per status change (kyc.submission.submitted / .under_review / .approved / .rejected), with the actor taken from the transaction-local gtvx.actor_role/gtvx.actor_id set by the entry points. Fires for BOTH paths and for a privileged update that bypasses the entry points.';

CREATE OR REPLACE FUNCTION public.kyc_status_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_actor text;
  v_actor_id uuid;
BEGIN
  IF NEW.level IS NOT DISTINCT FROM OLD.level
     AND NEW.provider IS NOT DISTINCT FROM OLD.provider THEN
    RETURN NULL;   -- not a security event
  END IF;

  v_actor := COALESCE(NULLIF(current_setting('gtvx.actor_role', true), ''), 'system');
  v_actor_id := NULLIF(current_setting('gtvx.actor_id', true), '')::uuid;

  INSERT INTO public.security_audit_log (
    actor_role, actor_id, subject_user_id, action, entity_type, entity_id, details
  ) VALUES (
    v_actor, v_actor_id, NEW.user_id, 'kyc.level.changed', 'kyc_status', NEW.user_id,
    jsonb_build_object(
      'from_level', OLD.level, 'to_level', NEW.level,
      'provider_before', OLD.provider, 'provider_after', NEW.provider
    )
  );
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS kyc_status_audit ON public.kyc_status;
CREATE TRIGGER kyc_status_audit
  AFTER UPDATE ON public.kyc_status
  FOR EACH ROW EXECUTE FUNCTION public.kyc_status_audit();

COMMENT ON FUNCTION public.kyc_status_audit() IS
  'Trigger: writes exactly one security_audit_log row (kyc.level.changed) per KYC level/provider change on a user''s status, with the actor from gtvx.actor_role/gtvx.actor_id. Both the operator path and the provider-adapter path are covered.';

-- ---------------------------------------------------------------------------
-- the two paths and their mode gate
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_kyc_path(p_source text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_mode text;
BEGIN
  IF p_source IS NULL OR p_source NOT IN ('paper_operator', 'provider_adapter') THEN
    RAISE EXCEPTION 'unknown KYC source %: expected paper_operator or provider_adapter', COALESCE(p_source, 'NULL')
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

  IF p_source = 'provider_adapter' AND v_mode <> 'live' THEN
    RAISE EXCEPTION
      'the provider adapter KYC path is live-only: app_settings.mode = % (use the operator path in the paper sandbox)',
      v_mode
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN v_mode;
END $$;

COMMENT ON FUNCTION public.assert_kyc_path(text) IS
  'The KYC path gate: refuses the operator/paper path while app_settings.mode = live and the provider-adapter path unless mode = live. KYC carries no money, so it has no app_settings flag and the enforce_environment_gate trigger is deliberately not attached to these tables — the mode is the only switch.';

-- ---------------------------------------------------------------------------
-- per-user status materialisation (level 0 on first reference)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_kyc_status(p_user_id uuid)
RETURNS public.kyc_status
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.kyc_status;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'ensure_kyc_status: user id is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO public.kyc_status (user_id, level)
  VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;

  SELECT * INTO v_row FROM public.kyc_status WHERE user_id = p_user_id;
  RETURN v_row;
END $$;

COMMENT ON FUNCTION public.ensure_kyc_status(uuid) IS
  'Materialises the one-row-per-user KYC status at level 0 (unverified) and returns it. Idempotent: a second call returns the existing row untouched. Called by my_kyc_status() and by every level-changing entry point before it moves the level. service_role only (my_kyc_status is the client-facing entry point).';

CREATE OR REPLACE FUNCTION public.my_kyc_status()
RETURNS TABLE (level smallint, provider text, level_changed_at timestamptz, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_row public.kyc_status;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'my_kyc_status: no authenticated user (auth.uid() is NULL)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  v_row := public.ensure_kyc_status(v_uid);

  RETURN QUERY SELECT v_row.level, v_row.provider, v_row.level_changed_at, v_row.updated_at;
END $$;

COMMENT ON FUNCTION public.my_kyc_status() IS
  'The client-facing read entry point: returns the caller''s own KYC level (materialising the level-0 row on first reference) and nothing else. The ONE KYC function granted to authenticated; a signed-in user can also read their own kyc_status/kyc_submissions rows directly through RLS.';

-- ---------------------------------------------------------------------------
-- operator path: submit / under review / approve / reject
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.submit_kyc(
  p_user_id uuid,
  p_level integer,
  p_metadata jsonb DEFAULT '{}'::jsonb,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'submit_kyc: user id is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_level IS NULL OR p_level < 1 THEN
    RAISE EXCEPTION 'submit_kyc: level % cannot be applied for (level 0 unverified is the default; a submission seeks a level >= 1)', COALESCE(p_level::text, 'NULL')
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.kyc_levels WHERE level = p_level) THEN
    RAISE EXCEPTION 'submit_kyc: unknown KYC level %', p_level
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_metadata IS NOT NULL AND jsonb_typeof(p_metadata) <> 'object' THEN
    RAISE EXCEPTION 'submit_kyc: metadata must be a JSON object of opaque references (got %)', jsonb_typeof(p_metadata)
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  PERFORM public.assert_kyc_path('paper_operator');

  PERFORM set_config('gtvx.actor_role', 'operator', true);

  INSERT INTO public.kyc_submissions (
    user_id, level_sought, environment, source, status, metadata, review_reason
  ) VALUES (
    p_user_id, p_level, 'paper', 'paper_operator', 'pending',
    COALESCE(p_metadata, '{}'::jsonb), p_note
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION public.submit_kyc(uuid, integer, jsonb, text) IS
  'Operator/test path: record a pending KYC application for a user who seeks p_level, source = paper_operator in the paper environment. metadata carries opaque references ONLY (document id / hash) — the kyc_metadata_guard trigger refuses personal-data keys. Refused while app_settings.mode = live. Grants no level: only approve_kyc() does. service_role only.';

CREATE OR REPLACE FUNCTION public.set_kyc_under_review(p_submission_id uuid, p_reason text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_s public.kyc_submissions;
  v_st text;
BEGIN
  SELECT * INTO v_s FROM public.kyc_submissions WHERE id = p_submission_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown KYC submission %', p_submission_id USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM public.assert_kyc_path(v_s.source);

  IF v_s.status = 'under review' THEN
    RETURN 'under review';   -- idempotent
  END IF;
  IF v_s.status <> 'pending' THEN
    RAISE EXCEPTION 'KYC submission % is %: only a pending submission can be put under review', v_s.id, v_s.status
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM set_config('gtvx.actor_role', 'operator', true);

  UPDATE public.kyc_submissions
     SET status = 'under review',
         under_review_at = now(),
         review_reason = COALESCE(p_reason, review_reason)
   WHERE id = v_s.id
  RETURNING status INTO v_st;

  RETURN v_st;
END $$;

COMMENT ON FUNCTION public.set_kyc_under_review(uuid, text) IS
  'Operator path: put a pending KYC submission under review with an optional reason. Granting a level is NOT possible here — only approve_kyc(). Idempotent on an already-under-review row. service_role only.';

CREATE OR REPLACE FUNCTION public.approve_kyc(p_submission_id uuid, p_note text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_s public.kyc_submissions;
  v_cur public.kyc_status;
  v_st text;
BEGIN
  SELECT * INTO v_s FROM public.kyc_submissions WHERE id = p_submission_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown KYC submission %', p_submission_id USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM public.assert_kyc_path(v_s.source);

  IF v_s.status = 'approved' THEN
    RETURN 'approved';   -- idempotent: the level was already granted
  END IF;
  IF v_s.status NOT IN ('pending', 'under review') THEN
    RAISE EXCEPTION 'KYC submission % is %: only a pending or under-review submission can be approved', v_s.id, v_s.status
      USING ERRCODE = 'check_violation';
  END IF;

  v_cur := public.ensure_kyc_status(v_s.user_id);
  IF v_cur.level > v_s.level_sought THEN
    RAISE EXCEPTION 'KYC submission % asks for level %, but user % is already at level %: a downgrade is not implemented (owner decision)',
      v_s.id, v_s.level_sought, v_s.user_id, v_cur.level
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM set_config('gtvx.actor_role', 'operator', true);

  -- one transaction: the approval and the level it grants either both happen or neither
  UPDATE public.kyc_submissions
     SET status = 'approved',
         decided_at = now(),
         decision_reason = COALESCE(p_note, decision_reason)
   WHERE id = v_s.id
  RETURNING status INTO v_st;

  IF v_cur.level < v_s.level_sought THEN
    UPDATE public.kyc_status
       SET level = v_s.level_sought,
           provider = COALESCE(v_cur.provider, v_s.provider)
     WHERE user_id = v_s.user_id;
  END IF;

  RETURN v_st;
END $$;

COMMENT ON FUNCTION public.approve_kyc(uuid, text) IS
  'Operator path: approve a pending or under-review KYC submission, which GRANTS THE LEVEL: one transaction sets the submission to approved (terminal) and raises kyc_status.level to level_sought, with two security_audit_log rows (kyc.submission.approved + kyc.level.changed). Refuses an approval below the user''s current level (no downgrade). Idempotent on an already-approved row. service_role only.';

CREATE OR REPLACE FUNCTION public.reject_kyc(p_submission_id uuid, p_reason text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_s public.kyc_submissions;
  v_st text;
BEGIN
  IF p_reason IS NULL OR btrim(p_reason) = '' THEN
    RAISE EXCEPTION 'reject_kyc: a reason is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT * INTO v_s FROM public.kyc_submissions WHERE id = p_submission_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown KYC submission %', p_submission_id USING ERRCODE = 'no_data_found';
  END IF;

  PERFORM public.assert_kyc_path(v_s.source);

  IF v_s.status = 'rejected' THEN
    RETURN 'rejected';   -- idempotent
  END IF;
  IF v_s.status NOT IN ('pending', 'under review') THEN
    RAISE EXCEPTION 'KYC submission % is %: only a pending or under-review submission can be rejected', v_s.id, v_s.status
      USING ERRCODE = 'check_violation';
  END IF;

  PERFORM set_config('gtvx.actor_role', 'operator', true);

  UPDATE public.kyc_submissions
     SET status = 'rejected', decided_at = now(), decision_reason = p_reason
   WHERE id = v_s.id
  RETURNING status INTO v_st;

  -- deliberately nothing happens to kyc_status: a rejection never moves the level
  RETURN v_st;
END $$;

COMMENT ON FUNCTION public.reject_kyc(uuid, text) IS
  'Operator path: reject a pending or under-review KYC submission with a mandatory reason. The user''s level is UNCHANGED (a rejection grants and removes nothing); the row is terminal, so a resubmission is a new row. Idempotent on an already-rejected row. service_role only.';

-- ---------------------------------------------------------------------------
-- provider adapter contract
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_provider_kyc_event(p_event jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_missing  text;
  v_event    text;
  v_user     uuid;
  v_ref      text;
  v_provider text;
  v_reason   text;
  v_meta     jsonb;
  v_level    smallint;
  v_target   text;
  v_s        public.kyc_submissions;
  v_id       uuid;
  v_matches  integer;
BEGIN
  IF p_event IS NULL OR jsonb_typeof(p_event) <> 'object' THEN
    RAISE EXCEPTION 'provider adapter contract violation: the event must be a JSON object (got %)',
      COALESCE(jsonb_typeof(p_event), 'NULL')
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT string_agg(k, ', ' ORDER BY k)
    INTO v_missing
    FROM unnest(ARRAY['event_type', 'user_id', 'submission_reference']) AS k
   WHERE NOT (p_event ? k);
  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'provider adapter contract violation: event is missing required key(s) % (required: event_type, user_id, submission_reference; optional: provider, level_sought, reason, metadata)',
      v_missing
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_event := lower(btrim(COALESCE(p_event->>'event_type', '')));
  IF v_event NOT IN ('approve', 'reject', 'under_review') THEN
    RAISE EXCEPTION 'provider adapter contract violation: unknown event_type % (expected approve, reject or under_review)',
      COALESCE(p_event->>'event_type', 'NULL')
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  BEGIN
    v_user := (p_event->>'user_id')::uuid;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'provider adapter contract violation: user_id is not a uuid (got %)', p_event->>'user_id'
      USING ERRCODE = 'invalid_parameter_value';
  END;

  v_ref := btrim(COALESCE(p_event->>'submission_reference', ''));
  IF v_ref = '' THEN
    RAISE EXCEPTION 'provider adapter contract violation: submission_reference is blank (it is the idempotency key of the adapter contract)'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  v_provider := NULLIF(btrim(COALESCE(p_event->>'provider', '')), '');
  v_reason   := NULLIF(btrim(COALESCE(p_event->>'reason', '')), '');
  v_meta     := p_event->'metadata';

  IF v_meta IS NOT NULL AND jsonb_typeof(v_meta) <> 'object' THEN
    RAISE EXCEPTION 'provider adapter contract violation: metadata must be a JSON object (got %)', jsonb_typeof(v_meta)
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_event ? 'level_sought' AND p_event->>'level_sought' IS NOT NULL THEN
    BEGIN
      v_level := (p_event->>'level_sought')::smallint;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'provider adapter contract violation: level_sought is not an integer (got %)', p_event->>'level_sought'
        USING ERRCODE = 'invalid_parameter_value';
    END;
  END IF;

  PERFORM public.assert_kyc_path('provider_adapter');

  v_target := CASE v_event
                WHEN 'approve'      THEN 'approved'
                WHEN 'reject'       THEN 'rejected'
                ELSE 'under review'
              END;

  -- idempotency: the (provider, provider_reference) pair identifies ONE application.
  -- A provider name is optional, but an ambiguous match is refused rather than guessed.
  SELECT count(*) INTO v_matches
    FROM public.kyc_submissions s
   WHERE s.provider_reference = v_ref
     AND (v_provider IS NULL OR s.provider = v_provider);

  IF v_matches > 1 THEN
    RAISE EXCEPTION 'provider adapter contract violation: submission_reference % matches % submissions — include the provider name to disambiguate',
      v_ref, v_matches
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_matches = 0 THEN
    -- nothing known for this reference yet: the event creates the application
    IF v_event = 'reject' THEN
      RAISE EXCEPTION 'provider adapter contract violation: cannot reject unknown submission_reference % (the application must be recorded before it can be refused)', v_ref
        USING ERRCODE = 'no_data_found';
    END IF;
    IF v_level IS NULL THEN
      RAISE EXCEPTION 'provider adapter contract violation: level_sought is required when the event creates the submission (reference % is unknown)', v_ref
        USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_level < 1 OR NOT EXISTS (SELECT 1 FROM public.kyc_levels WHERE level = v_level) THEN
      RAISE EXCEPTION 'provider adapter contract violation: level_sought % is not a known KYC level >= 1', v_level
        USING ERRCODE = 'invalid_parameter_value';
    END IF;

    PERFORM set_config('gtvx.actor_role', 'provider_adapter', true);

    INSERT INTO public.kyc_submissions (
      user_id, level_sought, environment, source, status, provider, provider_reference,
      metadata, raw, decision_reason, under_review_at, decided_at
    ) VALUES (
      v_user, v_level, 'live', 'provider_adapter', v_target, v_provider, v_ref,
      COALESCE(v_meta, '{}'::jsonb), p_event,
      CASE WHEN v_target = 'rejected' THEN COALESCE(v_reason, 'rejected by the provider')
           WHEN v_target = 'approved' THEN v_reason
           ELSE NULL END,
      CASE WHEN v_target = 'under review' THEN now() ELSE NULL END,
      CASE WHEN v_target IN ('approved', 'rejected') THEN now() ELSE NULL END
    )
    RETURNING id INTO v_id;

    IF v_target = 'approved' THEN
      PERFORM public._kyc_grant_level(v_user, v_level, v_provider);
    END IF;

    RETURN v_id;
  END IF;

  -- a known application: apply the transition, refusing replays and no-ops
  SELECT * INTO v_s FROM public.kyc_submissions WHERE provider_reference = v_ref
    AND (v_provider IS NULL OR provider = v_provider)
    FOR UPDATE;

  IF v_s.user_id <> v_user THEN
    RAISE EXCEPTION 'provider adapter contract violation: submission_reference % belongs to another user than user_id says', v_ref
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF v_s.status IN ('approved', 'rejected') THEN
    RAISE EXCEPTION 'provider adapter contract violation: submission % (%) already reached its terminal status % — a replayed provider event is refused and nothing is recorded',
      v_s.id, v_ref, v_s.status
      USING ERRCODE = 'unique_violation';
  END IF;

  IF v_s.status = v_target THEN
    RAISE EXCEPTION 'provider adapter contract violation: submission % is already % — duplicate provider event refused', v_s.id, v_target
      USING ERRCODE = 'unique_violation';
  END IF;

  PERFORM set_config('gtvx.actor_role', 'provider_adapter', true);

  UPDATE public.kyc_submissions
     SET status = v_target,
         raw = p_event,
         metadata = COALESCE(v_meta, metadata),
         under_review_at = CASE WHEN v_target = 'under review' THEN now() ELSE under_review_at END,
         decided_at = CASE WHEN v_target IN ('approved', 'rejected') THEN now() ELSE decided_at END,
         decision_reason = CASE WHEN v_reason IS NOT NULL THEN v_reason ELSE decision_reason END
   WHERE id = v_s.id;

  IF v_target = 'approved' THEN
    PERFORM public._kyc_grant_level(v_s.user_id, v_s.level_sought, COALESCE(v_provider, v_s.provider));
  END IF;

  RETURN v_s.id;
END $$;

COMMENT ON FUNCTION public.record_provider_kyc_event(jsonb) IS
  'The documented KYC provider-adapter contract (the only interface a future vendor implements): takes ONE normalised provider event as JSON (event_type approve|reject|under_review, user_id and submission_reference required; provider, level_sought, reason, metadata optional; any extra provider fields are preserved in raw) and applies it as source = provider_adapter in the LIVE environment. An unknown submission_reference creates the application (level_sought then required); a known one is transitioned. Refuses malformed events, unknown event types, non-uuid user ids, ambiguous references, terminal replays and duplicate events as adapter contract violations, recording nothing. Refused unless app_settings.mode = live. No vendor, credential or document store is part of this step. service_role only.';

-- internal helper shared by the two approval paths (not granted to any client role)
CREATE OR REPLACE FUNCTION public._kyc_grant_level(p_user_id uuid, p_level integer, p_provider text)
RETURNS smallint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_cur smallint;
BEGIN
  v_cur := (public.ensure_kyc_status(p_user_id)).level;

  IF v_cur > p_level THEN
    RAISE EXCEPTION 'cannot grant KYC level % to user %: they are already at level % (a downgrade is not implemented)',
      p_level, p_user_id, v_cur
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_cur < p_level THEN
    UPDATE public.kyc_status
       SET level = p_level::smallint,
           provider = COALESCE(NULLIF(btrim(COALESCE(p_provider, '')), ''), provider)
     WHERE user_id = p_user_id;
  END IF;

  RETURN p_level;
END $$;

COMMENT ON FUNCTION public._kyc_grant_level(uuid, integer, text) IS
  'Internal: raises a user''s kyc_status.level to p_level after an approved submission, refusing a level the user already exceeded (no downgrade). Called by approve_kyc() and record_provider_kyc_event() inside the approving transaction, so the approval, the level change and both audit rows commit together.';

-- ---------------------------------------------------------------------------
-- RLS and privileges
-- ---------------------------------------------------------------------------
ALTER TABLE public.kyc_levels ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kyc_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.kyc_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.security_audit_log ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['kyc_levels', 'kyc_submissions', 'kyc_status', 'security_audit_log'] LOOP
    -- anonymous visitors: nothing at all, not even the tier model
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
    END IF;

    -- signed-in users: read-only, and only what an RLS policy allows
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM authenticated', t);
      EXECUTE format('GRANT SELECT ON public.%I TO authenticated', t);
    END IF;

    -- the server side writes; the audit log is INSERT-only forever
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM service_role', t);
      IF t = 'security_audit_log' THEN
        EXECUTE format('GRANT SELECT, INSERT ON public.%I TO service_role', t);
      ELSE
        EXECUTE format('GRANT SELECT, INSERT, UPDATE ON public.%I TO service_role', t);
      END IF;
      IF t = 'security_audit_log' THEN
        EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON public.%I FROM service_role', t);
      END IF;
    END IF;

    -- NO DELETE for anybody on any of these tables: applications and audit rows are
    -- evidence, and the tier model is reference data.
    EXECUTE format('REVOKE DELETE, TRUNCATE ON public.%I FROM PUBLIC', t);
  END LOOP;
END $$;

DROP POLICY IF EXISTS kyc_levels_select_authenticated ON public.kyc_levels;
CREATE POLICY kyc_levels_select_authenticated ON public.kyc_levels
  FOR SELECT TO authenticated
  USING (true);

DROP POLICY IF EXISTS kyc_submissions_select_own ON public.kyc_submissions;
CREATE POLICY kyc_submissions_select_own ON public.kyc_submissions
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS kyc_status_select_own ON public.kyc_status;
CREATE POLICY kyc_status_select_own ON public.kyc_status
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

DROP POLICY IF EXISTS security_audit_log_select_own ON public.security_audit_log;
CREATE POLICY security_audit_log_select_own ON public.security_audit_log
  FOR SELECT TO authenticated
  USING (subject_user_id = auth.uid());

-- No INSERT/UPDATE/DELETE policy for anon or authenticated anywhere: client writes are
-- denied by RLS regardless of any future privilege grant.

-- ---------------------------------------------------------------------------
-- function ACLs — same pattern as 20261005100100 / …120 / …130: PUBLIC and the client
-- roles are revoked explicitly and only service_role gets it back, plus the ONE documented
-- client entry point (my_kyc_status).
--
-- This block runs LAST on purpose: it resolves every signature, so every function above
-- must already exist when the migration reaches it.
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
         'assert_kyc_path', '_kyc_pii_key_path',
         'ensure_kyc_status', 'my_kyc_status',
         'submit_kyc', 'set_kyc_under_review', 'approve_kyc', 'reject_kyc',
         'record_provider_kyc_event', '_kyc_grant_level'
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

-- the one client-facing exception: a signed-in user may read their OWN KYC level
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.my_kyc_status() TO authenticated;
  END IF;
END $$;
-- (kyc_submissions_before_update, kyc_status_before_update, kyc_submissions_audit,
--  kyc_status_audit and kyc_metadata_guard are trigger functions and keep the default
--  EXECUTE grant on purpose: PostgreSQL checks EXECUTE with the invoking role.)
