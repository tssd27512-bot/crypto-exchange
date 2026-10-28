/*
# 20261005100150 — exchange admin / operator control plane (stage 2, part 1)

DB layer + functions + tests for the operator control plane. Built ON TOP of the
existing admin stack (admin_users + verify_password/update_admin_password, used by
the admin-chat edge function) and on the step-8 security layer (security_audit_log,
kyc_status/kyc_submissions, the gtvx.actor_role/gtvx.actor_id transaction-locals).
Nothing here is deployed and no LIVE_* flag is touched.

## What this migration adds

### 1. Operator identity (closes the NULL-actor gap from PR #6)
- `admin_users` gains `operator_role` (FK to operator_roles, DEFAULT 'readonly'),
  `auth_user_id` (unique, FK to auth.users), `is_active`, `display_name`,
  `updated_at`. `username`/`password_hash` are untouched, so the admin-chat login
  keeps working. **Privilege is not given away**: the pre-existing `admin` row
  becomes a READ-ONLY operator until the owner promotes it explicitly.
- `resolve_operator(p_operator_id)` is how a production request identifies the
  operator:
    * JWT caller (auth.uid() NOT NULL): resolved ONLY through
      `admin_users.auth_user_id = auth.uid()`. A caller may not act as somebody
      else, and a JWT that maps to no operator row is refused. For this path the
      edge function does nothing special — it forwards the caller's JWT.
    * service_role caller (auth.uid() IS NULL): the explicit `p_operator_id`, else
      the transaction-local `gtvx.operator_id` that an edge function sets after it
      has verified the admin session. This is the expected production wiring for
      the admin panel (edge function verifies admin login → calls the RPC with the
      service key → passes the operator id). **The edge function itself is NOT
      part of this step.**
  The GUC is only honoured when auth.uid() is NULL, so a signed-in customer cannot
  `set_config('gtvx.operator_id', …)` their way into an operator identity.
- `assert_operator(action, p_operator_id)` is the guard: resolve + permission
  matrix check + refuses deactivated operators + stamps gtvx.actor_role='operator'
  and gtvx.actor_id, so the audit rows (including the ones the PR #6 KYC triggers
  write) record a REAL actor_id instead of NULL.
- `log_operator_action(...)` writes one `security_audit_log` row per operator
  action with actor_role='operator' and a NON-NULL actor_id; it REFUSES to write a
  row when no actor can be resolved, so an anonymous operator action is impossible
  rather than being recorded as NULL.

### 2. Roles + permission matrix (data, not code)
`operator_roles` (superadmin/compliance/support/readonly) and
`operator_permissions` (one row per role × action, 44 rows). `operator_can()` reads
a cell, `operator_can_do()` reads it for the calling operator. Deny by default.
Every admin function in this migration starts with `assert_operator(...)`.

### 3. Sensitive-action audit
Every admin function writes a `security_audit_log` row with action, entity and a
`before`/`after` summary in `details`. Read RPCs are audited too
(admin.<thing>.<read>); the high-volume `v_admin_*` views are NOT audited per row
(flagged, documented in SCHEMA.md).

### 4. Account restrictions + risk flags, ENFORCED in the money paths
- `account_restrictions` (user, scope trading|deposits|withdrawals, reason,
  set_at/set_by, cleared_at/cleared_by/cleared_reason; one ACTIVE row per
  user+scope; rows are never deleted).
- `risk_flags` (user, flag_type, severity low|medium|high|critical, note,
  created_by, resolved_at/by/note). ADVISORY ONLY — flags block nothing.
- `assert_account_not_restricted(user, scope)` is called from the five money-path
  entry points, which are re-created below VERBATIM except for the injected guards.

### 5. KYC review actions
`admin_kyc_set_under_review` / `admin_kyc_approve` / `admin_kyc_reject` are thin,
authorised wrappers over the PR #6 functions (`set_kyc_under_review`,
`approve_kyc`, `reject_kyc`). They REUSE the state machine — they do not duplicate
it — and add the kyc.decide permission check, real actor identity and their own
admin.kyc.* audit row.

### 6. Money-path monitoring + read-only inspection
Role-scoped views `v_admin_users`, `v_admin_balances`, `v_admin_open_orders`,
`v_admin_deposits`, `v_admin_withdrawals`, `v_admin_trades`, `v_admin_kyc_queue`,
`v_admin_restrictions`, `v_admin_risk_flags`, `v_admin_security_events`,
`v_admin_operators`, plus paginated RPCs `admin_list_users`,
`admin_user_overview`, `admin_list_security_events`.
**Administrators can never create customer money**: no function in this migration
inserts a `balances` row, posts a ledger entry or calls `post_entry`; the tests
assert that statically over `pg_proc.prosrc`.

### 7. Markets / fees / network configuration (superadmin)
`admin_upsert_market`, `admin_set_market_fees`, `admin_set_market_status`,
`admin_register_deposit_network`, `admin_register_withdrawal_network`. The last two
WRAP the existing register_* functions so fees/min/max logic is not duplicated.

### 8. System settings — maintenance mode
`app_settings` gains `maintenance_mode` (NOT NULL DEFAULT false), `maintenance_note`,
`maintenance_set_at`, `maintenance_set_by`. `admin_set_maintenance()` is the only
writer. While ON, `assert_not_in_maintenance()` inside the entry points refuses
trading / deposits / withdrawals with a distinct message. mode stays paper and
every LIVE_* flag is untouched.

## Money-path changes (the ONLY existing functions this migration re-creates)
Each is copied byte-for-byte from its defining migration and gains exactly the
guard lines marked `>>> 20261005100150`:

| function | added |
|---|---|
| `place_order`            | `assert_not_in_maintenance('trading')`, `assert_account_not_restricted(<resolved user>, 'trading')` |
| `_deposit_ingest`        | `assert_not_in_maintenance('deposits')`, `assert_account_not_restricted(p_user_id, 'deposits')` |
| `credit_deposit`         | `assert_not_in_maintenance('deposits')`, `assert_account_not_restricted(v_dep.user_id, 'deposits')` |
| `_withdrawal_ingest`     | `assert_not_in_maintenance('withdrawals')`, `assert_account_not_restricted(p_user_id, 'withdrawals')` |
| `approve_withdrawal`     | `assert_not_in_maintenance('withdrawals')`, `assert_account_not_restricted(v_w.user_id, 'withdrawals')` |

Deliberately NOT gated: `cancel_order`, `close_order`, `release_order_remainder`
and `reject_withdrawal`/`fail_withdrawal` — see SCHEMA.md (maintenance must never
trap funds).

## Deliberately out of scope
Edge functions (operator session verification), the admin frontend, AML/sanctions
screening, KYC-gated money paths, per-tier limits, operator MFA. The parked
`feat/admin-auth-hardening` branch (signed admin tokens, rate limiting) is a
separate PR: when it lands, `resolve_operator()`'s service_role path is the hook it
should feed, and nothing here needs to change.

## Conventions
Function bodies in this file use `$fn$` dollar quotes rather than `$$` so that a
toolchain which mangles `$$` cannot silently corrupt them. The lifted money-path
functions keep their original `$$` delimiters because they are copied verbatim.
*/

SET search_path = public, pg_temp;

-- ===========================================================================
-- 1. MAINTENANCE MODE (app_settings) — additive columns + the gate helper
-- ===========================================================================
-- The flag is added with DEFAULT false and never flipped by this migration, so
-- applying it changes no behaviour: the paper/live switches and every LIVE_*
-- flag keep their values.
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS maintenance_mode boolean NOT NULL DEFAULT false;
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS maintenance_note text;
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS maintenance_set_at timestamptz;
ALTER TABLE public.app_settings
  ADD COLUMN IF NOT EXISTS maintenance_set_by uuid;

DO $fn$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.app_settings'::regclass
       AND conname = 'app_settings_maintenance_set_by_fkey'
  ) THEN
    ALTER TABLE public.app_settings
      ADD CONSTRAINT app_settings_maintenance_set_by_fkey
      FOREIGN KEY (maintenance_set_by) REFERENCES public.admin_users(id) ON DELETE SET NULL;
  END IF;
END $fn$;

COMMENT ON COLUMN public.app_settings.maintenance_mode IS
  'Operator-controlled maintenance switch, default false. When true, place_order(), the deposit entry points and the withdrawal entry points refuse with "the exchange is in maintenance mode: ...". Cancelling/closing an order and rejecting/failing an existing withdrawal stay allowed on purpose, so maintenance can never trap a customer''s funds.';
COMMENT ON COLUMN public.app_settings.maintenance_note IS 'Operator-supplied reason shown in the refusal message while maintenance_mode is true.';
COMMENT ON COLUMN public.app_settings.maintenance_set_by IS 'admin_users.id of the operator who last flipped maintenance_mode (NULL until an operator does).';

CREATE OR REPLACE FUNCTION public.maintenance_mode()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT COALESCE((SELECT maintenance_mode FROM public.app_settings WHERE id), false)
$fn$;

COMMENT ON FUNCTION public.maintenance_mode() IS
  'True while an operator has the exchange in maintenance mode. Reads app_settings.maintenance_mode (added in this migration, default false).';

CREATE OR REPLACE FUNCTION public.assert_not_in_maintenance(p_area text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_note text;
BEGIN
  IF p_area IS NULL OR btrim(p_area) = '' THEN
    RAISE EXCEPTION 'assert_not_in_maintenance: an area is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT maintenance_note INTO v_note FROM public.app_settings WHERE id;
  IF public.maintenance_mode() THEN
    RAISE EXCEPTION
      'the exchange is in maintenance mode: % is temporarily unavailable (app_settings.maintenance_mode = true, operator note: %)',
      p_area, COALESCE(v_note, 'none')
      USING ERRCODE = 'check_violation';
  END IF;
END $fn$;

COMMENT ON FUNCTION public.assert_not_in_maintenance(text) IS
  'Raises a distinct "the exchange is in maintenance mode: <area> is temporarily unavailable" error while app_settings.maintenance_mode is true. Called by the trading/deposit/withdrawal entry points added in this migration; a no-op (one extra read of a one-row table) while the flag is false.';

-- ===========================================================================
-- 2. OPERATOR IDENTITY
-- ===========================================================================
-- Operators are ROWS IN admin_users (the table the admin-chat edge function has
-- used since the original admin migrations). It is extended additively; the
-- username/password_hash columns the edge function depends on are untouched.
--
-- Privilege is NOT given away silently: the new operator_role column defaults to
-- 'readonly', so the pre-existing 'admin' row can read the operator views and
-- nothing else until the owner promotes it explicitly (see the NOTICE at the end
-- of this section).
CREATE TABLE IF NOT EXISTS public.operator_roles (
  code text PRIMARY KEY,
  rank smallint NOT NULL,
  description text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT operator_roles_code_check CHECK (code IN ('superadmin', 'compliance', 'support', 'readonly'))
);

INSERT INTO public.operator_roles (code, rank, description) VALUES
  ('superadmin', 40, 'Full operator control: markets, fees, settings/maintenance, operator roster. Never touches customer money.'),
  ('compliance', 30, 'KYC review and decisions, restrictions, risk flags, security events, user/account inspection. No configuration writes.'),
  ('support',    20, 'Read-only user/account/order/money inspection to answer customer questions. No decisions, no writes.'),
  ('readonly',   10, 'Auditor: read everything including the security audit trail, write nothing.')
ON CONFLICT (code) DO NOTHING;

ALTER TABLE public.admin_users
  ADD COLUMN IF NOT EXISTS operator_role text NOT NULL DEFAULT 'readonly';
ALTER TABLE public.admin_users
  ADD COLUMN IF NOT EXISTS auth_user_id uuid;
ALTER TABLE public.admin_users
  ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true;
ALTER TABLE public.admin_users
  ADD COLUMN IF NOT EXISTS display_name text;
ALTER TABLE public.admin_users
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

DO $fn$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.admin_users'::regclass
       AND conname = 'admin_users_operator_role_fkey'
  ) THEN
    ALTER TABLE public.admin_users
      ADD CONSTRAINT admin_users_operator_role_fkey
      FOREIGN KEY (operator_role) REFERENCES public.operator_roles(code) ON DELETE RESTRICT;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.admin_users'::regclass
       AND conname = 'admin_users_auth_user_id_fkey'
  ) THEN
    ALTER TABLE public.admin_users
      ADD CONSTRAINT admin_users_auth_user_id_fkey
      FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
  END IF;
END $fn$;

-- one operator row per auth user: the production identity mapping
CREATE UNIQUE INDEX IF NOT EXISTS admin_users_auth_user_id_key
  ON public.admin_users (auth_user_id)
  WHERE auth_user_id IS NOT NULL;

COMMENT ON COLUMN public.admin_users.operator_role IS
  'Operator role code (operator_roles.code). Defaults to readonly: a pre-existing admin_users row is an operator with read-only visibility until the owner promotes it explicitly.';
COMMENT ON COLUMN public.admin_users.auth_user_id IS
  'The auth.users.id this operator signs in as. This is the production identity mapping: an edge function that has verified the admin session passes the operator id (service_role), and a JWT-holding operator is resolved through this column. NULL = server-side operator with no login user.';
COMMENT ON COLUMN public.admin_users.is_active IS
  'Deactivated operators keep their rows (and their audit history) but every admin function refuses them.';
COMMENT ON TABLE public.admin_users IS
  'Operator roster + the legacy admin-chat login (username/password_hash). Extended in 20261005100150 with operator_role/auth_user_id/is_active/display_name. Password hashes remain service_role-only.';

-- ---------------------------------------------------------------------------
-- the permission matrix, as data
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.operator_permissions (
  role_code text NOT NULL REFERENCES public.operator_roles(code) ON DELETE CASCADE,
  action text NOT NULL,
  allowed boolean NOT NULL,
  PRIMARY KEY (role_code, action),
  CONSTRAINT operator_permissions_action_check CHECK (length(btrim(action)) BETWEEN 3 AND 60)
);

INSERT INTO public.operator_permissions (role_code, action, allowed) VALUES
  --                                     superadmin compliance support readonly
  ('superadmin', 'users.read',          true),
  ('superadmin', 'users.read.pii',      true),
  ('superadmin', 'kyc.read',            true),
  ('superadmin', 'kyc.decide',          true),
  ('superadmin', 'security.read',       true),
  ('superadmin', 'money.read',          true),
  ('superadmin', 'restrictions.write',  true),
  ('superadmin', 'risk.write',          true),
  ('superadmin', 'markets.write',       true),
  ('superadmin', 'settings.write',      true),
  ('superadmin', 'operators.write',     true),

  ('compliance', 'users.read',          true),
  ('compliance', 'users.read.pii',      true),
  ('compliance', 'kyc.read',            true),
  ('compliance', 'kyc.decide',          true),
  ('compliance', 'security.read',       true),
  ('compliance', 'money.read',          true),
  ('compliance', 'restrictions.write',  true),
  ('compliance', 'risk.write',          true),
  ('compliance', 'markets.write',       false),
  ('compliance', 'settings.write',      false),
  ('compliance', 'operators.write',     false),

  ('support',    'users.read',          true),
  ('support',    'users.read.pii',      false),
  ('support',    'kyc.read',            true),
  ('support',    'kyc.decide',          false),
  ('support',    'security.read',       false),
  ('support',    'money.read',          true),
  ('support',    'restrictions.write',  false),
  ('support',    'risk.write',          false),
  ('support',    'markets.write',       false),
  ('support',    'settings.write',      false),
  ('support',    'operators.write',     false),

  ('readonly',   'users.read',          true),
  ('readonly',   'users.read.pii',      false),
  ('readonly',   'kyc.read',            true),
  ('readonly',   'kyc.decide',          false),
  ('readonly',   'security.read',       true),
  ('readonly',   'money.read',          true),
  ('readonly',   'restrictions.write',  false),
  ('readonly',   'risk.write',          false),
  ('readonly',   'markets.write',       false),
  ('readonly',   'settings.write',      false),
  ('readonly',   'operators.write',     false)
ON CONFLICT (role_code, action) DO NOTHING;

COMMENT ON TABLE public.operator_permissions IS
  'The operator permission matrix, one row per (role, action). assert_operator() is the only reader that matters: every admin function calls it before doing anything. Changing a cell is an owner decision.';

CREATE OR REPLACE FUNCTION public.operator_can(p_role text, p_action text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT COALESCE((
    SELECT p.allowed
      FROM public.operator_permissions p
      JOIN public.operator_roles r ON r.code = p.role_code
     WHERE p.role_code = p_role AND p.action = p_action
  ), false)
$fn$;

COMMENT ON FUNCTION public.operator_can(text, text) IS
  'Looks up one cell of the operator permission matrix. Unknown role or action = false (deny by default).';

-- ---------------------------------------------------------------------------
-- operator resolution: HOW A PRODUCTION REQUEST IDENTIFIES THE OPERATOR
-- ---------------------------------------------------------------------------
-- Two paths, and the second is deliberately NOT available to signed-in users:
--
--   (a) auth.uid() is NOT NULL  (a JWT-holding caller, e.g. a future admin
--       frontend). The operator is resolved ONLY through
--       admin_users.auth_user_id = auth.uid(). A caller may not name somebody
--       else's operator id. If the JWT subject maps to no operator row the call
--       is refused — a random signed-in customer is not an operator.
--
--   (b) auth.uid() IS NULL  (service_role / an edge function, which is how the
--       admin panel is expected to call this: the edge function verifies the
--       admin session, then calls the RPC with service_role and passes
--       p_operator_id). The explicit id is used, else the transaction-local
--       gtvx.operator_id the edge function set. This is the only path where an
--       explicit operator id is honoured, and it requires the service key —
--       which a customer never has.
--
-- The transaction-local GUC is therefore never trusted for a JWT-holding
-- caller: an authenticated user cannot `select set_config('gtvx.operator_id', …)`
-- their way into an operator identity.
CREATE OR REPLACE FUNCTION public.resolve_operator(p_operator_id uuid DEFAULT NULL)
RETURNS public.admin_users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_op  public.admin_users;
BEGIN
  IF v_uid IS NOT NULL THEN
    SELECT * INTO v_op FROM public.admin_users WHERE auth_user_id = v_uid;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'signed-in user % is not a registered operator', v_uid
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF p_operator_id IS NOT NULL AND p_operator_id <> v_op.id THEN
      RAISE EXCEPTION 'a JWT-holding operator may only act as themselves (claimed %, actual %)',
        p_operator_id, v_op.id
        USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF NOT v_op.is_active THEN
      RAISE EXCEPTION 'operator % is deactivated', v_op.username USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN v_op;
  END IF;

  IF p_operator_id IS NULL THEN
    SELECT * INTO v_op
      FROM public.admin_users
     WHERE id = NULLIF(current_setting('gtvx.operator_id', true), '')::uuid;
  ELSE
    SELECT * INTO v_op FROM public.admin_users WHERE id = p_operator_id;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no operator identity: no auth.uid() and no known operator id was supplied (server-side calls must pass p_operator_id or set gtvx.operator_id)'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT v_op.is_active THEN
    RAISE EXCEPTION 'operator % is deactivated', v_op.username USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN v_op;
END $fn$;

COMMENT ON FUNCTION public.resolve_operator(uuid) IS
  'Resolves the CALLING operator: through admin_users.auth_user_id when a JWT is present (a caller cannot name somebody else), or from the explicit p_operator_id / gtvx.operator_id GUC on the service_role path. Raises insufficient_privilege when there is no operator identity or the operator is deactivated.';

CREATE OR REPLACE FUNCTION public.current_operator_id()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_id  uuid;
BEGIN
  IF v_uid IS NOT NULL THEN
    SELECT id INTO v_id FROM public.admin_users WHERE auth_user_id = v_uid AND is_active;
    RETURN v_id;
  END IF;
  SELECT id INTO v_id
    FROM public.admin_users
   WHERE id = NULLIF(current_setting('gtvx.operator_id', true), '')::uuid
     AND is_active;
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.current_operator_id() IS
  'The calling operator id, or NULL when the caller is not an operator. Used by the role-scoped admin views; unlike resolve_operator() it returns NULL instead of raising.';

CREATE OR REPLACE FUNCTION public.current_operator_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT operator_role FROM public.admin_users WHERE id = public.current_operator_id()
$fn$;

COMMENT ON FUNCTION public.current_operator_role() IS
  'Role code of the calling operator, NULL when the caller is not one. This is what the v_admin_* views filter on, so a non-operator (including every ordinary signed-in customer) sees zero rows.';

CREATE OR REPLACE FUNCTION public.operator_can_do(p_action text)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT public.operator_can(public.current_operator_role(), p_action)
$fn$;

COMMENT ON FUNCTION public.operator_can_do(text) IS
  'True when the CALLING operator may perform p_action. Used inside the role-scoped admin views.';

-- ---------------------------------------------------------------------------
-- THE GUARD: every admin function starts with this
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_operator(p_action text, p_operator_id uuid DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op   public.admin_users;
  v_role text;
BEGIN
  IF p_action IS NULL OR btrim(p_action) = '' THEN
    RAISE EXCEPTION 'assert_operator: an action is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  v_op := public.resolve_operator(p_operator_id);
  IF NOT public.operator_can(v_op.operator_role, p_action) THEN
    RAISE EXCEPTION 'operator % (role %) is not permitted to perform % (permission matrix denies it)',
      v_op.username, v_op.operator_role, p_action
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  -- actor identity for the security_audit_log rows this call will write, including
  -- the rows the PR #6 KYC triggers write on behalf of the operator
  PERFORM set_config('gtvx.actor_role', 'operator', true);
  PERFORM set_config('gtvx.actor_id', v_op.id::text, true);
  PERFORM set_config('gtvx.operator_id', v_op.id::text, true);
  RETURN v_op.id;
END $fn$;

COMMENT ON FUNCTION public.assert_operator(text, uuid) IS
  'Server-side authorisation + actor resolution for every admin function: resolves the calling operator, checks the permission matrix for p_action (deny by default), refuses deactivated operators, and stamps gtvx.actor_role/gtvx.actor_id so the audit trail records a real actor. Returns the operator id.';

CREATE OR REPLACE FUNCTION public.log_operator_action(
  p_action           text,
  p_entity_type      text,
  p_entity_id        uuid DEFAULT NULL,
  p_subject_user_id  uuid DEFAULT NULL,
  p_details          jsonb DEFAULT '{}'::jsonb,
  p_actor_id         uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_actor    uuid;
  v_role     text;
  v_username text;
  v_id       uuid;
BEGIN
  v_actor := COALESCE(p_actor_id, NULLIF(current_setting('gtvx.actor_id', true), '')::uuid);
  IF v_actor IS NULL THEN
    RAISE EXCEPTION
      'refusing to write an operator audit row for % without an actor identity: every operator action must name who did it',
      p_action
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT operator_role, username INTO v_role, v_username
    FROM public.admin_users WHERE id = v_actor;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'refusing to write an operator audit row for unknown operator % (%)', v_actor, p_action
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO public.security_audit_log (
    actor_role, actor_id, subject_user_id, action, entity_type, entity_id, details
  ) VALUES (
    'operator', v_actor, p_subject_user_id, p_action, p_entity_type, p_entity_id,
    COALESCE(p_details, '{}'::jsonb)
      || jsonb_build_object('operator_role', v_role, 'operator_username', v_username)
  ) RETURNING id INTO v_id;
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.log_operator_action(text, text, uuid, uuid, jsonb, uuid) IS
  'Writes one security_audit_log row with actor_role = operator and a NON-NULL actor_id (this is the NULL-actor gap from PR #6 closed). Refuses to write anything if no actor can be resolved, so an anonymous operator action is impossible rather than silently recorded. Called by every admin function in this migration.';

-- ===========================================================================
-- 3. ACCOUNT RESTRICTIONS + RISK FLAGS
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.account_restrictions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  scope text NOT NULL,
  reason text NOT NULL,
  active boolean NOT NULL DEFAULT true,
  set_at timestamptz NOT NULL DEFAULT now(),
  set_by uuid NOT NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  cleared_at timestamptz,
  cleared_by uuid REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  cleared_reason text,
  CONSTRAINT account_restrictions_scope_check CHECK (scope IN ('trading', 'deposits', 'withdrawals')),
  CONSTRAINT account_restrictions_reason_check CHECK (length(btrim(reason)) BETWEEN 3 AND 500),
  CONSTRAINT account_restrictions_cleared_check CHECK (
    (active AND cleared_at IS NULL AND cleared_by IS NULL AND cleared_reason IS NULL)
    OR (NOT active AND cleared_at IS NOT NULL AND cleared_by IS NOT NULL)
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS account_restrictions_active_key
  ON public.account_restrictions (user_id, scope) WHERE active;
CREATE INDEX IF NOT EXISTS account_restrictions_user_idx
  ON public.account_restrictions (user_id, set_at DESC);

COMMENT ON TABLE public.account_restrictions IS
  'Operator-set restrictions, one active row per (user, scope) where scope is trading|deposits|withdrawals. Enforced inside the money paths themselves (place_order, _deposit_ingest, credit_deposit, _withdrawal_ingest, approve_withdrawal), not in a frontend. Clearing sets active = false and keeps the row: the history is never deleted.';
COMMENT ON COLUMN public.account_restrictions.set_by IS 'admin_users.id of the operator who set the restriction (NOT NULL: an anonymous restriction is impossible).';
COMMENT ON COLUMN public.account_restrictions.cleared_by IS 'admin_users.id of the operator who cleared it; NULL while the restriction is active.';

CREATE TABLE IF NOT EXISTS public.risk_flags (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  flag_type text NOT NULL,
  severity text NOT NULL,
  note text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid NOT NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  resolved_at timestamptz,
  resolved_by uuid REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  resolution_note text,
  CONSTRAINT risk_flags_type_check CHECK (flag_type ~ '^[a-z][a-z0-9_.]{2,39}$'),
  CONSTRAINT risk_flags_severity_check CHECK (severity IN ('low', 'medium', 'high', 'critical')),
  CONSTRAINT risk_flags_note_check CHECK (length(btrim(note)) BETWEEN 3 AND 500),
  CONSTRAINT risk_flags_resolution_check CHECK (
    (resolved_at IS NULL AND resolved_by IS NULL) OR (resolved_at IS NOT NULL AND resolved_by IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS risk_flags_user_idx ON public.risk_flags (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS risk_flags_open_idx ON public.risk_flags (severity, created_at DESC) WHERE resolved_at IS NULL;

COMMENT ON TABLE public.risk_flags IS
  'Advisory operator annotations on a user (type, severity, note). ADVISORY ONLY: a risk flag blocks nothing by itself; enforcement is account_restrictions. Flags are resolved, never deleted.';

CREATE OR REPLACE FUNCTION public.assert_account_not_restricted(p_user_id uuid, p_scope text)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_r public.account_restrictions;
BEGIN
  IF p_scope IS NULL OR p_scope NOT IN ('trading', 'deposits', 'withdrawals') THEN
    RAISE EXCEPTION 'assert_account_not_restricted: unknown scope % (trading|deposits|withdrawals)', p_scope
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_user_id IS NULL THEN
    RETURN;   -- identity is resolved (and refused) by the caller; never guess a user here
  END IF;
  SELECT * INTO v_r
    FROM public.account_restrictions
   WHERE user_id = p_user_id AND scope = p_scope AND active;
  IF FOUND THEN
    RAISE EXCEPTION
      'user % is restricted from % by an operator: % (restriction %, set %)',
      p_user_id, p_scope, v_r.reason, v_r.id, v_r.set_at
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END $fn$;

COMMENT ON FUNCTION public.assert_account_not_restricted(uuid, text) IS
  'Raises insufficient_privilege when the user has an ACTIVE restriction for the given scope. Called by the five money-path entry points as of 20261005100150. One indexed lookup per call; a no-op while the table is empty.';

-- ---------------------------------------------------------------------------
-- operator RPCs: restrictions
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_restriction(
  p_user_id    uuid,
  p_scope      text,
  p_reason     text,
  p_operator_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_scope  text := lower(btrim(COALESCE(p_scope, '')));
  v_before jsonb;
  v_id     uuid;
BEGIN
  v_op := public.assert_operator('restrictions.write', p_operator_id);
  IF v_scope NOT IN ('trading', 'deposits', 'withdrawals') THEN
    RAISE EXCEPTION 'unknown restriction scope % (trading|deposits|withdrawals)', COALESCE(p_scope, 'NULL')
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) < 3 THEN
    RAISE EXCEPTION 'a restriction requires a reason (at least 3 characters)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %: a restriction belongs to exactly one user', p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;
  SELECT jsonb_build_object('id', r.id, 'active', r.active, 'reason', r.reason, 'set_at', r.set_at)
    INTO v_before
    FROM public.account_restrictions r
   WHERE r.user_id = p_user_id AND r.scope = v_scope AND r.active;
  IF v_before IS NOT NULL THEN
    RAISE EXCEPTION 'user % is already restricted from % (restriction %): clear it before setting a new one',
      p_user_id, v_scope, v_before->>'id'
      USING ERRCODE = 'unique_violation';
  END IF;

  INSERT INTO public.account_restrictions (user_id, scope, reason, set_by)
  VALUES (p_user_id, v_scope, btrim(p_reason), v_op)
  RETURNING id INTO v_id;

  PERFORM public.log_operator_action(
    'admin.restriction.set', 'account_restriction', v_id, p_user_id,
    jsonb_build_object(
      'before', COALESCE(v_before, 'null'::jsonb),
      'after', jsonb_build_object('id', v_id, 'scope', v_scope, 'reason', btrim(p_reason), 'active', true,
                                  'set_by', v_op, 'set_at', now())
    ), v_op);
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.admin_set_restriction(uuid, text, text, uuid) IS
  'Operator action (restrictions.write): restrict one user in one scope. Refuses a second active restriction in the same scope. Writes an admin.restriction.set audit row with before/after.';

CREATE OR REPLACE FUNCTION public.admin_clear_restriction(
  p_restriction_id uuid,
  p_reason         text DEFAULT NULL,
  p_operator_id    uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_r      public.account_restrictions;
  v_before jsonb;
BEGIN
  v_op := public.assert_operator('restrictions.write', p_operator_id);
  SELECT * INTO v_r FROM public.account_restrictions WHERE id = p_restriction_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown restriction %', p_restriction_id USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT v_r.active THEN
    RAISE EXCEPTION 'restriction % was already cleared at %', v_r.id, v_r.cleared_at
      USING ERRCODE = 'check_violation';
  END IF;
  v_before := jsonb_build_object('active', true, 'reason', v_r.reason, 'scope', v_r.scope);

  UPDATE public.account_restrictions
     SET active = false, cleared_at = now(), cleared_by = v_op,
         cleared_reason = NULLIF(btrim(COALESCE(p_reason, '')), '')
   WHERE id = v_r.id;

  PERFORM public.log_operator_action(
    'admin.restriction.cleared', 'account_restriction', v_r.id, v_r.user_id,
    jsonb_build_object(
      'before', v_before,
      'after', jsonb_build_object('active', false, 'cleared_by', v_op, 'cleared_at', now(),
                                  'cleared_reason', NULLIF(btrim(COALESCE(p_reason, '')), ''))
    ), v_op);
  RETURN v_r.id;
END $fn$;

COMMENT ON FUNCTION public.admin_clear_restriction(uuid, text, uuid) IS
  'Operator action (restrictions.write): deactivate a restriction. The row is kept (append-only history), and an admin.restriction.cleared audit row records who cleared it and why.';

CREATE OR REPLACE FUNCTION public.admin_add_risk_flag(
  p_user_id     uuid,
  p_flag_type   text,
  p_severity    text,
  p_note        text,
  p_operator_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op uuid;
  v_id uuid;
BEGIN
  v_op := public.assert_operator('risk.write', p_operator_id);
  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %: a risk flag belongs to exactly one user', p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;
  INSERT INTO public.risk_flags (user_id, flag_type, severity, note, created_by)
  VALUES (p_user_id, lower(btrim(COALESCE(p_flag_type, ''))), lower(btrim(COALESCE(p_severity, ''))),
          btrim(COALESCE(p_note, '')), v_op)
  RETURNING id INTO v_id;

  PERFORM public.log_operator_action(
    'admin.risk_flag.added', 'risk_flag', v_id, p_user_id,
    jsonb_build_object(
      'before', 'null'::jsonb,
      'after', jsonb_build_object('flag_type', lower(btrim(COALESCE(p_flag_type, ''))),
                                  'severity', lower(btrim(COALESCE(p_severity, ''))),
                                  'note', btrim(COALESCE(p_note, '')), 'active', true)
    ), v_op);
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.admin_add_risk_flag(uuid, text, text, text, uuid) IS
  'Operator action (risk.write): attach an advisory risk flag (type/severity/note) to a user. Flags block nothing by themselves. Writes an admin.risk_flag.added audit row.';

CREATE OR REPLACE FUNCTION public.admin_resolve_risk_flag(
  p_flag_id     uuid,
  p_note        text DEFAULT NULL,
  p_operator_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op uuid;
  v_f  public.risk_flags;
BEGIN
  v_op := public.assert_operator('risk.write', p_operator_id);
  SELECT * INTO v_f FROM public.risk_flags WHERE id = p_flag_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown risk flag %', p_flag_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_f.resolved_at IS NOT NULL THEN
    RAISE EXCEPTION 'risk flag % was already resolved at %', v_f.id, v_f.resolved_at
      USING ERRCODE = 'check_violation';
  END IF;
  UPDATE public.risk_flags
     SET resolved_at = now(), resolved_by = v_op,
         resolution_note = NULLIF(btrim(COALESCE(p_note, '')), '')
   WHERE id = v_f.id;

  PERFORM public.log_operator_action(
    'admin.risk_flag.resolved', 'risk_flag', v_f.id, v_f.user_id,
    jsonb_build_object(
      'before', jsonb_build_object('flag_type', v_f.flag_type, 'severity', v_f.severity, 'resolved_at', v_f.resolved_at),
      'after', jsonb_build_object('resolved_at', now(), 'resolved_by', v_op,
                                  'resolution_note', NULLIF(btrim(COALESCE(p_note, '')), ''))
    ), v_op);
  RETURN v_f.id;
END $fn$;

COMMENT ON FUNCTION public.admin_resolve_risk_flag(uuid, text, uuid) IS
  'Operator action (risk.write): resolve a risk flag with an optional note. Flags are never deleted. Writes an admin.risk_flag.resolved audit row.';

-- ===========================================================================
-- 4. MONEY-PATH GUARDS - the five entry points, re-created VERBATIM except
--    for the marked guard lines (see the table in the header comment).
--    cancel_order / close_order / release_order_remainder / reject_withdrawal /
--    fail_withdrawal are deliberately NOT gated: maintenance must never trap funds.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.place_order(
  p_market_symbol   text,
  p_side            text,
  p_type            text,
  p_qty_units       numeric,
  p_price_units     numeric DEFAULT NULL,
  p_tif             text    DEFAULT 'gtc',
  p_client_order_id text    DEFAULT NULL,
  p_user_id         uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_env    text;
  v_user   uuid;
  v_market public.markets;
  v_side   text := lower(btrim(coalesce(p_side, '')));
  v_type   text := lower(btrim(coalesce(p_type, 'limit')));
  v_tif    text := lower(btrim(coalesce(p_tif, 'gtc')));
  v_qty    numeric;
  v_price  numeric;
  v_client text := nullif(btrim(coalesce(p_client_order_id, '')), '');
  v_order_id  uuid;
  v_existing  uuid;
  v_ns        integer;
  v_should_rest boolean;
  v_fillable  numeric;
  v_gross     numeric;
  v_hold      numeric := 0;
  v_fee_cap   numeric := 0;
  v_max_bps   integer;
  v_hold_asset       uuid;
  v_hold_account     uuid;
  v_available_account uuid;
  v_available  numeric;
  v_tx        uuid;
  v_fills     jsonb;
  v_order     public.orders;
BEGIN
  -- mode gate: throws unless trading is enabled for the current mode
  v_env  := public.assert_trading_enabled();
  -- identity: never from the request body
  v_user := public.resolve_order_actor(p_user_id);
  -- >>> 20261005100150 (admin operations): maintenance + trading-restriction gates.
  -- Additive: one read of the one-row app_settings table and one indexed lookup on
  -- account_restrictions. Behaviour is unchanged while maintenance_mode = false and
  -- no active 'trading' restriction exists for this user.
  PERFORM public.assert_not_in_maintenance('trading');
  PERFORM public.assert_account_not_restricted(v_user, 'trading');

  -- ---- boundary validation: integers only, rejected loudly, never rounded ----
  IF v_side NOT IN ('buy', 'sell') THEN
    RAISE EXCEPTION 'side must be buy or sell (got %)', coalesce(p_side, 'NULL')
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_type NOT IN ('limit', 'market') THEN
    RAISE EXCEPTION 'type must be limit or market (got %)', coalesce(p_type, 'NULL')
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_tif NOT IN ('gtc', 'ioc', 'fok') THEN
    RAISE EXCEPTION 'time_in_force must be gtc, ioc or fok (got %)', coalesce(p_tif, 'NULL')
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_qty_units IS NULL THEN
    RAISE EXCEPTION 'qty_units is required (integer base units)'
      USING ERRCODE = 'check_violation';
  END IF;

  v_qty := p_qty_units;
  IF v_qty <> trunc(v_qty) THEN
    RAISE EXCEPTION 'qty_units must be a whole number of base units, got %: fractional amounts are rejected, not rounded', p_qty_units
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_qty <= 0 THEN
    RAISE EXCEPTION 'qty_units must be > 0 (got %)', v_qty USING ERRCODE = 'check_violation';
  END IF;

  IF p_price_units IS NOT NULL THEN
    v_price := p_price_units;
    IF v_price <> trunc(v_price) THEN
      RAISE EXCEPTION 'price_units must be a whole number of quote base units, got %: fractional amounts are rejected, not rounded', p_price_units
        USING ERRCODE = 'check_violation';
    END IF;
    IF v_price <= 0 THEN
      RAISE EXCEPTION 'price_units must be > 0 (got %)', v_price USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  IF v_type = 'limit' AND v_price IS NULL THEN
    RAISE EXCEPTION 'a limit order requires price_units'
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_type = 'market' AND v_price IS NOT NULL THEN
    RAISE EXCEPTION 'a market order must not carry price_units (got %); the fill price comes from the book', v_price
      USING ERRCODE = 'check_violation';
  END IF;

  -- ---- market configuration ----
  SELECT * INTO v_market
    FROM public.markets
   WHERE symbol = p_market_symbol AND environment = v_env;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown market % in the % environment (app_settings.mode)', coalesce(p_market_symbol, 'NULL'), v_env
      USING ERRCODE = 'no_data_found';
  END IF;

  IF NOT v_market.is_active OR v_market.status <> 'trading' THEN
    RAISE EXCEPTION 'market % is not trading (status %, is_active %)', v_market.symbol, v_market.status, v_market.is_active
      USING ERRCODE = 'check_violation';
  END IF;

  v_ns := v_market.notional_scale;

  IF v_price IS NOT NULL AND v_market.price_tick_units > 0
     AND mod(v_price, v_market.price_tick_units) <> 0 THEN
    RAISE EXCEPTION 'price_units % does not respect the tick size % on %', v_price, v_market.price_tick_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.qty_step_units > 0 AND mod(v_qty, v_market.qty_step_units) <> 0 THEN
    RAISE EXCEPTION 'qty_units % does not respect the step size % on %', v_qty, v_market.qty_step_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.min_qty_units IS NOT NULL AND v_qty < v_market.min_qty_units THEN
    RAISE EXCEPTION 'qty_units % is below the minimum % on %', v_qty, v_market.min_qty_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  IF v_market.min_notional_units IS NOT NULL AND v_price IS NOT NULL
     AND public.notional_units(v_qty, v_price, v_ns) < v_market.min_notional_units THEN
    RAISE EXCEPTION 'order notional % is below the minimum % on %',
      public.notional_units(v_qty, v_price, v_ns), v_market.min_notional_units, v_market.symbol
      USING ERRCODE = 'check_violation';
  END IF;

  -- ---- idempotency: a retried client_order_id returns the original order ----
  IF v_client IS NOT NULL THEN
    SELECT id INTO v_existing
      FROM public.orders
     WHERE user_id = v_user AND market_id = v_market.id AND client_order_id = v_client;

    IF v_existing IS NOT NULL THEN
      RETURN public.order_result(v_existing, '[]'::jsonb);
    END IF;
  END IF;

  v_should_rest := (v_type = 'limit' AND v_tif = 'gtc');

  -- ---- pre-trade plan: what could fill, and therefore what to hold ----
  IF v_type = 'market' OR v_tif = 'fok' THEN
    SELECT f.fillable_units, f.gross_quote_units
      INTO v_fillable, v_gross
      FROM public.book_fillable(v_market.id, v_side, v_price, v_qty, v_user) f;
  END IF;

  -- FOK that cannot fill completely never trades: no hold, no ledger rows.
  IF v_tif = 'fok' AND COALESCE(v_fillable, 0) < v_qty THEN
    INSERT INTO public.orders (user_id, market_id, client_order_id, side, type, time_in_force,
                               price_units, qty_units, status, reject_reason, environment, closed_at)
    VALUES (v_user, v_market.id, v_client, v_side, v_type, v_tif,
            v_price, v_qty, 'rejected', 'fok_not_fillable', v_env, now())
    RETURNING id INTO v_order_id;

    INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
    VALUES (v_order_id, 'rejected',
            jsonb_build_object('reason', 'fok_not_fillable', 'qty_units', v_qty,
                               'fillable_units', COALESCE(v_fillable, 0)),
            'engine', v_user);

    RETURN public.order_result(v_order_id, '[]'::jsonb);
  END IF;

  v_max_bps := greatest(v_market.taker_fee_bps, v_market.maker_fee_bps);

  IF v_side = 'sell' THEN
    v_hold_asset := v_market.base_asset_id;
    v_hold := v_qty;
  ELSE
    v_hold_asset := v_market.quote_asset_id;
    IF v_type = 'market' THEN
      -- hold only what the visible book can actually take
      v_gross := COALESCE(v_gross, 0);
    ELSE
      v_gross := public.notional_units(v_qty, v_price, v_ns);
    END IF;
    v_fee_cap := trunc(v_gross * v_max_bps / 10000);
    v_hold := v_gross + v_fee_cap;
  END IF;

  v_available_account := public.ensure_user_account(v_user, v_hold_asset, 'available', v_env);
  v_hold_account      := public.ensure_user_account(v_user, v_hold_asset, 'locked',    v_env);

  IF v_hold > 0 THEN
    SELECT COALESCE(b.available_units, 0) INTO v_available
      FROM public.balances b WHERE b.account_id = v_available_account;

    IF COALESCE(v_available, 0) < v_hold THEN
      RAISE EXCEPTION 'insufficient available balance: order needs % base units to hold but only % are available on account %',
        v_hold, COALESCE(v_available, 0), v_available_account
        USING ERRCODE = 'insufficient_privilege';
    END IF;
  END IF;

  -- ---- the order ----
  INSERT INTO public.orders (user_id, market_id, client_order_id, side, type, time_in_force,
                             price_units, qty_units, quote_qty_units,
                             hold_asset_id, hold_account_id, status, environment)
  VALUES (v_user, v_market.id, v_client, v_side, v_type, v_tif,
          v_price, v_qty, CASE WHEN v_side = 'buy' THEN v_gross ELSE NULL END,
          v_hold_asset, v_hold_account, 'new', v_env)
  RETURNING id INTO v_order_id;

  INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
  VALUES (v_order_id, 'created',
          jsonb_build_object('side', v_side, 'type', v_type, 'time_in_force', v_tif,
                             'qty_units', v_qty, 'price_units', v_price,
                             'market', v_market.symbol, 'environment', v_env),
          'engine', v_user);

  -- ---- hold ----
  IF v_hold > 0 THEN
    INSERT INTO public.ledger_transactions (type, environment, reference_type, reference_id, description, metadata)
    VALUES ('order_hold', v_env, 'order', v_order_id,
            format('hold %s units for %s order', v_hold, v_side),
            jsonb_build_object('order_id', v_order_id, 'asset_id', v_hold_asset,
                               'amount_units', v_hold, 'side', v_side, 'market_id', v_market.id))
    RETURNING id INTO v_tx;

    PERFORM public.post_entry(v_tx, v_available_account, -v_hold, 'held for order');
    PERFORM public.post_entry(v_tx, v_hold_account,      v_hold, 'held for order');

    UPDATE public.orders
       SET hold_amount_units = v_hold, hold_transaction_id = v_tx
     WHERE id = v_order_id;

    INSERT INTO public.order_events (order_id, event, payload, actor, actor_user_id)
    VALUES (v_order_id, 'hold_placed',
            jsonb_build_object('hold_units', v_hold, 'asset_id', v_hold_asset,
                               'ledger_transaction_id', v_tx),
            'engine', v_user);
  END IF;

  -- ---- match ----
  v_fills := public.match_order(v_order_id, v_should_rest);

  RETURN public.order_result(v_order_id, v_fills);
END $$;

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

  -- the paper sandbox switch: only the paper path reads it (the live path is gated by
  -- deposits_enabled above and by enforce_environment_gate on the table)
  IF p_source = 'paper_operator' THEN
    PERFORM public.assert_paper_deposits_enabled();
  END IF;

  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %: a deposit belongs to exactly one user', p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;
  -- >>> 20261005100150 (admin operations): maintenance + deposits-restriction gates.
  -- Additive: one read of the one-row app_settings table and one indexed lookup on
  -- account_restrictions. Behaviour is unchanged while maintenance_mode = false and
  -- no active 'deposits' restriction exists for this user.
  PERFORM public.assert_not_in_maintenance('deposits');
  PERFORM public.assert_account_not_restricted(p_user_id, 'deposits');

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
  -- >>> 20261005100150 (admin operations): maintenance + deposits-restriction gates.
  -- Additive: one read of the one-row app_settings table and one indexed lookup on
  -- account_restrictions. Behaviour is unchanged while maintenance_mode = false and
  -- no active 'deposits' restriction exists for this user.
  PERFORM public.assert_not_in_maintenance('deposits');
  PERFORM public.assert_account_not_restricted(v_dep.user_id, 'deposits');

  -- a paper-environment credit obeys the paper sandbox switch; a live credit is gated
  -- by deposits_enabled (assert_deposits_enabled above) and is untouched here
  IF v_dep.environment = 'paper' THEN
    PERFORM public.assert_paper_deposits_enabled();
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
  -- >>> 20261005100150 (admin operations): maintenance + withdrawals-restriction gates.
  -- Additive: one read of the one-row app_settings table and one indexed lookup on
  -- account_restrictions. Behaviour is unchanged while maintenance_mode = false and
  -- no active 'withdrawals' restriction exists for this user.
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
  -- >>> 20261005100150 (admin operations): maintenance + withdrawals-restriction gates.
  -- Additive: one read of the one-row app_settings table and one indexed lookup on
  -- account_restrictions. Behaviour is unchanged while maintenance_mode = false and
  -- no active 'withdrawals' restriction exists for this user.
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

-- ===========================================================================
-- 4. KYC REVIEW — operator wrappers around the PR #6 entry points
-- ===========================================================================
-- Reuse, do not duplicate: these call set_kyc_under_review() / approve_kyc() /
-- reject_kyc() unchanged, so the state machine, the atomic level grant, the
-- provider/source separation and the append-only submission rules stay in ONE
-- place. What the wrappers add is (a) operator authentication/authorisation on
-- the compliance matrix cell kyc.decide, (b) actor identity — assert_operator()
-- sets gtvx.actor_id, so the audit rows the PR #6 triggers write now carry a
-- real actor_id instead of NULL, and (c) an explicit admin.kyc.* audit row.
CREATE OR REPLACE FUNCTION public.admin_kyc_set_under_review(
  p_submission_id uuid,
  p_reason        text DEFAULT NULL,
  p_operator_id   uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op   uuid;
  v_sub  public.kyc_submissions;
  v_st   text;
BEGIN
  v_op := public.assert_operator('kyc.decide', p_operator_id);
  SELECT * INTO v_sub FROM public.kyc_submissions WHERE id = p_submission_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown KYC submission %', p_submission_id USING ERRCODE = 'no_data_found';
  END IF;
  v_st := public.set_kyc_under_review(p_submission_id, p_reason);
  PERFORM public.log_operator_action(
    'admin.kyc.under_review', 'kyc_submission', p_submission_id, v_sub.user_id,
    jsonb_build_object('before', jsonb_build_object('status', v_sub.status),
                       'after', jsonb_build_object('status', v_st, 'review_reason', p_reason),
                       'level_sought', v_sub.level_sought),
    v_op);
  RETURN v_st;
END $fn$;

COMMENT ON FUNCTION public.admin_kyc_set_under_review(uuid, text, uuid) IS
  'Operator action (kyc.decide): put a pending KYC submission under review through the PR #6 set_kyc_under_review(). Writes an admin.kyc.under_review audit row with actor identity; the kyc.* audit rows the trigger writes now carry that same actor.';

CREATE OR REPLACE FUNCTION public.admin_kyc_approve(
  p_submission_id uuid,
  p_note          text DEFAULT NULL,
  p_operator_id   uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op    uuid;
  v_sub   public.kyc_submissions;
  v_st    text;
  v_lvl   smallint;
  v_before smallint;
BEGIN
  v_op := public.assert_operator('kyc.decide', p_operator_id);
  SELECT * INTO v_sub FROM public.kyc_submissions WHERE id = p_submission_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown KYC submission %', p_submission_id USING ERRCODE = 'no_data_found';
  END IF;
  SELECT COALESCE((SELECT level FROM public.kyc_status WHERE user_id = v_sub.user_id), 0)
    INTO v_before;
  v_st := public.approve_kyc(p_submission_id, p_note);
  SELECT COALESCE((SELECT level FROM public.kyc_status WHERE user_id = v_sub.user_id), 0)
    INTO v_lvl;
  PERFORM public.log_operator_action(
    'admin.kyc.approved', 'kyc_submission', p_submission_id, v_sub.user_id,
    jsonb_build_object('before', jsonb_build_object('status', v_sub.status, 'level', v_before),
                       'after', jsonb_build_object('status', v_st, 'level', v_lvl, 'note', p_note),
                       'level_sought', v_sub.level_sought),
    v_op);
  RETURN v_st;
END $fn$;

COMMENT ON FUNCTION public.admin_kyc_approve(uuid, text, uuid) IS
  'Operator action (kyc.decide): approve a submission through the PR #6 approve_kyc(), which grants the level atomically. Writes an admin.kyc.approved audit row (actor recorded), on top of the kyc.submission.approved + kyc.level.changed rows the triggers write with the same actor.';

CREATE OR REPLACE FUNCTION public.admin_kyc_reject(
  p_submission_id uuid,
  p_reason        text,
  p_operator_id   uuid DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op  uuid;
  v_sub public.kyc_submissions;
  v_st  text;
BEGIN
  v_op := public.assert_operator('kyc.decide', p_operator_id);
  SELECT * INTO v_sub FROM public.kyc_submissions WHERE id = p_submission_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown KYC submission %', p_submission_id USING ERRCODE = 'no_data_found';
  END IF;
  v_st := public.reject_kyc(p_submission_id, p_reason);
  PERFORM public.log_operator_action(
    'admin.kyc.rejected', 'kyc_submission', p_submission_id, v_sub.user_id,
    jsonb_build_object('before', jsonb_build_object('status', v_sub.status),
                       'after', jsonb_build_object('status', v_st, 'reason', p_reason),
                       'level_sought', v_sub.level_sought),
    v_op);
  RETURN v_st;
END $fn$;

COMMENT ON FUNCTION public.admin_kyc_reject(uuid, text, uuid) IS
  'Operator action (kyc.decide): reject a submission through the PR #6 reject_kyc() (mandatory reason, level untouched, terminal). Writes an admin.kyc.rejected audit row with actor identity.';

-- ===========================================================================
-- 5. READ-ONLY INSPECTION (user/account/balance/order/kyc) — role-scoped views
-- ===========================================================================
-- Every view starts from public.operator_can_do('<action>'), so a caller who is
-- not an operator — including every ordinary signed-in customer and the anon
-- role — gets ZERO ROWS rather than an error. Column-level PII (email) is gated
-- separately on 'users.read.pii'. Nothing here reads or writes balances; they
-- are SELECTed from the ledger-derived balances table only.
CREATE OR REPLACE VIEW public.v_admin_users AS
SELECT u.id AS user_id,
       CASE WHEN public.operator_can_do('users.read.pii') THEN u.email END AS email,
       u.created_at AS signed_up_at,
       COALESCE(ks.level, 0)::smallint AS kyc_level,
       ks.provider AS kyc_provider,
       ks.level_changed_at,
       COALESCE((SELECT string_agg(r.scope, ',' ORDER BY r.scope)
                   FROM public.account_restrictions r
                  WHERE r.user_id = u.id AND r.active), '') AS restricted_scopes,
       (SELECT count(*) FROM public.risk_flags f WHERE f.user_id = u.id AND f.resolved_at IS NULL) AS open_risk_flags,
       (SELECT count(*) FROM public.orders o WHERE o.user_id = u.id AND o.status IN ('new', 'partially_filled')) AS open_orders
  FROM auth.users u
  LEFT JOIN public.kyc_status ks ON ks.user_id = u.id
 WHERE public.operator_can_do('users.read');

COMMENT ON VIEW public.v_admin_users IS
  'Operator user directory: id, signup time, KYC level, active restrictions, open risk flags, open orders. Requires users.read; the email column is filled only for users.read.pii holders (superadmin, compliance) and is NULL for support/readonly.';

CREATE OR REPLACE VIEW public.v_admin_balances AS
SELECT a.user_id, a.id AS account_id, ast.symbol, a.asset_id, a.account_type, a.kind, a.environment,
       COALESCE(b.available_units, 0) AS available_units,
       COALESCE(b.locked_units, 0) AS locked_units,
       b.version, b.last_entry_at, b.updated_at
  FROM public.accounts a
  JOIN public.assets ast ON ast.id = a.asset_id
  LEFT JOIN public.balances b ON b.account_id = a.id
 WHERE public.operator_can_do('money.read');

COMMENT ON VIEW public.v_admin_balances IS
  'Operator view of accounts and their balances (read-only; the balances table itself is never written by an admin function). Requires money.read.';

CREATE OR REPLACE VIEW public.v_admin_open_orders AS
SELECT o.id AS order_id, o.user_id, m.symbol AS market_symbol, o.side, o.type, o.time_in_force,
       o.price_units, o.qty_units, o.filled_qty_units, o.avg_price_units, o.status,
       o.environment, o.created_at, o.updated_at
  FROM public.orders o
  JOIN public.markets m ON m.id = o.market_id
 WHERE o.status IN ('new', 'partially_filled')
   AND public.operator_can_do('money.read');

COMMENT ON VIEW public.v_admin_open_orders IS 'Resting/parked orders across all users, newest first (ORDER BY created_at, id). Requires money.read.';

CREATE OR REPLACE VIEW public.v_admin_deposits AS
SELECT d.id AS deposit_id, d.user_id, ast.symbol, d.network, d.environment, d.source, d.status,
       d.amount_units, d.confirmations, d.required_confirmations, d.txid, d.log_index,
       d.credited_ledger_transaction_id, d.failed_reason, d.review_reason,
       d.detected_at, d.credited_at, d.created_at
  FROM public.deposits d
  JOIN public.assets ast ON ast.id = d.asset_id
 WHERE public.operator_can_do('money.read');

COMMENT ON VIEW public.v_admin_deposits IS 'Operator deposit monitor (read-only). Requires money.read. Page with ORDER BY created_at DESC, deposit_id (both present).';

CREATE OR REPLACE VIEW public.v_admin_withdrawals AS
SELECT w.id AS withdrawal_id, w.user_id, ast.symbol, w.network, w.environment, w.source, w.status,
       w.amount_units, w.fee_units, w.destination_address, w.destination_tag,
       w.provider_txid, w.hold_ledger_transaction_id, w.failure_reason, w.review_reason,
       w.requested_at, w.approved_at, w.completed_at, w.created_at
  FROM public.withdrawal_requests w
  JOIN public.assets ast ON ast.id = w.asset_id
 WHERE public.operator_can_do('money.read');

COMMENT ON VIEW public.v_admin_withdrawals IS 'Operator withdrawal monitor (read-only). Requires money.read. Page with ORDER BY created_at DESC, withdrawal_id.';

CREATE OR REPLACE VIEW public.v_admin_trades AS
SELECT t.id AS trade_id, m.symbol AS market_symbol, t.price_units, t.qty_units, t.quote_units,
       t.taker_side, t.taker_user_id, t.maker_user_id, t.taker_fee_units, t.maker_fee_units,
       t.ledger_transaction_id, t.environment, t.created_at
  FROM public.trades t
  JOIN public.markets m ON m.id = t.market_id
 WHERE public.operator_can_do('money.read');

COMMENT ON VIEW public.v_admin_trades IS 'Operator trade tape (read-only). Requires money.read. Page with ORDER BY created_at DESC, trade_id.';

CREATE OR REPLACE VIEW public.v_admin_kyc_queue AS
SELECT s.id AS submission_id, s.user_id, s.level_sought, s.status, s.source, s.environment,
       s.provider, s.provider_reference, s.review_reason, s.decision_reason,
       s.under_review_at, s.decided_at, s.created_at
  FROM public.kyc_submissions s
 WHERE public.operator_can_do('kyc.read');

COMMENT ON VIEW public.v_admin_kyc_queue IS
  'KYC review queue (submission metadata only — document references are opaque and no PII is stored, per the step-8 no-PII guard). Requires kyc.read.';

CREATE OR REPLACE VIEW public.v_admin_restrictions AS
SELECT r.id AS restriction_id, r.user_id, r.scope, r.reason, r.active,
       r.set_at, r.set_by, su.username AS set_by_username,
       r.cleared_at, r.cleared_by, cu.username AS cleared_by_username, r.cleared_reason
  FROM public.account_restrictions r
  LEFT JOIN public.admin_users su ON su.id = r.set_by
  LEFT JOIN public.admin_users cu ON cu.id = r.cleared_by
 WHERE public.operator_can_do('users.read');

COMMENT ON VIEW public.v_admin_restrictions IS 'Account restrictions with the operator who set and cleared each one. Requires users.read.';

CREATE OR REPLACE VIEW public.v_admin_risk_flags AS
SELECT f.id AS risk_flag_id, f.user_id, f.flag_type, f.severity, f.note,
       f.created_at, f.created_by, cu.username AS created_by_username,
       f.resolved_at, f.resolved_by, ru.username AS resolved_by_username, f.resolution_note
  FROM public.risk_flags f
  LEFT JOIN public.admin_users cu ON cu.id = f.created_by
  LEFT JOIN public.admin_users ru ON ru.id = f.resolved_by
 WHERE public.operator_can_do('users.read');

COMMENT ON VIEW public.v_admin_risk_flags IS 'Advisory risk flags with their operator authors. Requires users.read.';

CREATE OR REPLACE VIEW public.v_admin_security_events AS
SELECT a.id AS event_id, a.at, a.actor_role, a.actor_id, au.username AS actor_username,
       a.subject_user_id, a.action, a.entity_type, a.entity_id, a.details
  FROM public.security_audit_log a
  LEFT JOIN public.admin_users au ON au.id = a.actor_id
 WHERE public.operator_can_do('security.read');

COMMENT ON VIEW public.v_admin_security_events IS
  'The security audit trail with actor identity resolved to an operator username. Requires security.read — full access for superadmin and readonly, and for compliance (which reviews KYC/restriction events); support gets zero rows. Page with ORDER BY at DESC, event_id.';

CREATE OR REPLACE VIEW public.v_admin_operators AS
SELECT au.id AS operator_id, au.username, au.display_name, au.operator_role,
       r.rank AS role_rank, au.is_active, au.auth_user_id, au.created_at,
       (SELECT count(*) FROM public.security_audit_log s WHERE s.actor_id = au.id) AS audit_events
  FROM public.admin_users au
  JOIN public.operator_roles r ON r.code = au.operator_role
 WHERE public.operator_can_do('operators.write');

COMMENT ON VIEW public.v_admin_operators IS 'The operator roster (superadmin only: operators.write). Password hashes are never selected.';

-- ---------------------------------------------------------------------------
-- paginated read RPCs (the service_role path an edge function will use)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_list_users(
  p_limit       integer DEFAULT 50,
  p_offset      integer DEFAULT 0,
  p_search      text DEFAULT NULL,
  p_operator_id uuid DEFAULT NULL
)
RETURNS TABLE (
  user_id uuid, email text, signed_up_at timestamptz, kyc_level smallint,
  restricted_scopes text, open_risk_flags bigint, open_orders bigint, total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op uuid;
  v_n  bigint;
BEGIN
  v_op := public.assert_operator('users.read', p_operator_id);
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 500 (got %)', p_limit USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_offset IS NULL OR p_offset < 0 THEN
    RAISE EXCEPTION 'p_offset must be >= 0 (got %)', p_offset USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT count(*) INTO v_n FROM public.v_admin_users;
  PERFORM public.log_operator_action(
    'admin.users.listed', 'user_directory', NULL, NULL,
    jsonb_build_object('limit', p_limit, 'offset', p_offset, 'search', p_search, 'returned', v_n), v_op);
  RETURN QUERY
    SELECT v.user_id, v.email, v.signed_up_at, v.kyc_level, v.restricted_scopes,
           v.open_risk_flags, v.open_orders, v_n
      FROM public.v_admin_users v
     WHERE p_search IS NULL OR btrim(p_search) = ''
        OR v.user_id::text ILIKE '%' || btrim(p_search) || '%'
        OR COALESCE(v.email, '') ILIKE '%' || btrim(p_search) || '%'
     ORDER BY v.signed_up_at DESC, v.user_id
     LIMIT p_limit OFFSET p_offset;
END $fn$;

COMMENT ON FUNCTION public.admin_list_users(integer, integer, text, uuid) IS
  'Operator action (users.read): one page of the user directory with total_count for pagination. Writes an admin.users.listed audit row. Email follows the users.read.pii matrix cell.';

CREATE OR REPLACE FUNCTION public.admin_user_overview(p_user_id uuid, p_operator_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op uuid;
  v_out jsonb;
BEGIN
  v_op := public.assert_operator('users.read', p_operator_id);
  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %', p_user_id USING ERRCODE = 'no_data_found';
  END IF;
  SELECT jsonb_build_object(
    'user', (SELECT to_jsonb(v) FROM public.v_admin_users v WHERE v.user_id = p_user_id),
    'kyc_status', (SELECT to_jsonb(k) FROM public.kyc_status k WHERE k.user_id = p_user_id),
    'kyc_submissions', COALESCE((SELECT jsonb_agg(to_jsonb(q) ORDER BY q.created_at DESC)
                                   FROM public.v_admin_kyc_queue q WHERE q.user_id = p_user_id), '[]'::jsonb),
    'balances', COALESCE((SELECT jsonb_agg(to_jsonb(b) ORDER BY b.symbol, b.kind)
                            FROM public.v_admin_balances b WHERE b.user_id = p_user_id), '[]'::jsonb),
    'open_orders', COALESCE((SELECT jsonb_agg(to_jsonb(o) ORDER BY o.created_at DESC)
                               FROM public.v_admin_open_orders o WHERE o.user_id = p_user_id), '[]'::jsonb),
    'restrictions', COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.set_at DESC)
                                FROM public.v_admin_restrictions r WHERE r.user_id = p_user_id), '[]'::jsonb),
    'risk_flags', COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.created_at DESC)
                              FROM public.v_admin_risk_flags f WHERE f.user_id = p_user_id), '[]'::jsonb)
  ) INTO v_out;
  PERFORM public.log_operator_action(
    'admin.user.inspected', 'user', p_user_id, p_user_id,
    jsonb_build_object('before', 'null'::jsonb, 'after', jsonb_build_object('inspected_user', p_user_id)),
    v_op);
  RETURN v_out;
END $fn$;

COMMENT ON FUNCTION public.admin_user_overview(uuid, uuid) IS
  'Operator action (users.read): one JSON snapshot of a user — profile, KYC state and submissions, balances, open orders, restrictions, risk flags. Strictly read-only. Writes an admin.user.inspected audit row.';

CREATE OR REPLACE FUNCTION public.admin_list_security_events(
  p_limit            integer DEFAULT 50,
  p_offset           integer DEFAULT 0,
  p_action_prefix    text DEFAULT NULL,
  p_subject_user_id  uuid DEFAULT NULL,
  p_operator_id      uuid DEFAULT NULL
)
RETURNS TABLE (
  event_id uuid, at timestamptz, actor_role text, actor_id uuid, actor_username text,
  subject_user_id uuid, action text, entity_type text, entity_id uuid, details jsonb, total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op uuid;
  v_n  bigint;
BEGIN
  v_op := public.assert_operator('security.read', p_operator_id);
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 500 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 500 (got %)', p_limit USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT count(*) INTO v_n FROM public.v_admin_security_events;
  PERFORM public.log_operator_action(
    'admin.security_events.listed', 'security_audit_log', NULL, p_subject_user_id,
    jsonb_build_object('limit', p_limit, 'offset', p_offset, 'action_prefix', p_action_prefix), v_op);
  RETURN QUERY
    SELECT e.event_id, e.at, e.actor_role, e.actor_id, e.actor_username,
           e.subject_user_id, e.action, e.entity_type, e.entity_id, e.details, v_n
      FROM public.v_admin_security_events e
     WHERE (p_action_prefix IS NULL OR btrim(p_action_prefix) = '' OR e.action LIKE btrim(p_action_prefix) || '%')
       AND (p_subject_user_id IS NULL OR e.subject_user_id = p_subject_user_id)
     ORDER BY e.at DESC, e.event_id
     LIMIT p_limit OFFSET p_offset;
END $fn$;

COMMENT ON FUNCTION public.admin_list_security_events(integer, integer, text, uuid, uuid) IS
  'Operator action (security.read): one page of the security audit trail with total_count. Writes an admin.security_events.listed audit row (the audit trail records its own reads).';

-- ===========================================================================
-- 6. MARKETS / FEES / NETWORK CONFIGURATION (superadmin only)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.admin_upsert_market(
  p_symbol          text,
  p_base_symbol     text,
  p_quote_symbol    text,
  p_price_scale     smallint DEFAULT 8,
  p_price_tick_units numeric DEFAULT 1,
  p_qty_step_units  numeric DEFAULT 1,
  p_maker_fee_bps   integer DEFAULT 2,
  p_taker_fee_bps   integer DEFAULT 5,
  p_status          text DEFAULT 'trading',
  p_is_active       boolean DEFAULT true,
  p_environment     text DEFAULT 'paper',
  p_operator_id     uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_base   uuid;
  v_quote  uuid;
  v_id     uuid;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  v_op := public.assert_operator('markets.write', p_operator_id);
  IF p_environment NOT IN ('paper', 'live') THEN
    RAISE EXCEPTION 'unknown environment % (paper|live)', p_environment USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT id INTO v_base FROM public.assets WHERE symbol = p_base_symbol;
  SELECT id INTO v_quote FROM public.assets WHERE symbol = p_quote_symbol;
  IF v_base IS NULL OR v_quote IS NULL THEN
    RAISE EXCEPTION 'unknown asset symbol (% / %)', p_base_symbol, p_quote_symbol USING ERRCODE = 'no_data_found';
  END IF;

  SELECT to_jsonb(m) INTO v_before FROM public.markets m
   WHERE m.symbol = p_symbol AND m.environment = p_environment;

  INSERT INTO public.markets AS m (
    symbol, base_asset_id, quote_asset_id, environment, status, price_scale,
    price_tick_units, qty_step_units, maker_fee_bps, taker_fee_bps, is_active
  ) VALUES (
    p_symbol, v_base, v_quote, p_environment, p_status, p_price_scale,
    p_price_tick_units, p_qty_step_units, p_maker_fee_bps, p_taker_fee_bps, p_is_active
  )
  ON CONFLICT (symbol, environment) DO UPDATE
     SET status         = EXCLUDED.status,
         price_scale    = EXCLUDED.price_scale,
         price_tick_units = EXCLUDED.price_tick_units,
         qty_step_units = EXCLUDED.qty_step_units,
         maker_fee_bps  = EXCLUDED.maker_fee_bps,
         taker_fee_bps  = EXCLUDED.taker_fee_bps,
         is_active      = EXCLUDED.is_active
  RETURNING m.id INTO v_id;

  SELECT to_jsonb(m) INTO v_after FROM public.markets m WHERE m.id = v_id;
  PERFORM public.log_operator_action(
    'admin.market.upserted', 'market', v_id, NULL,
    jsonb_build_object('before', COALESCE(v_before, 'null'::jsonb), 'after', v_after), v_op);
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.admin_upsert_market(text, text, text, smallint, numeric, numeric, integer, integer, text, boolean, text, uuid) IS
  'Operator action (markets.write): create or reconfigure a market (fees, tick/step, status, active flag). Wraps the existing markets table — notional_scale stays derived by its trigger. Writes an admin.market.upserted audit row with the full before/after row.';

CREATE OR REPLACE FUNCTION public.admin_set_market_fees(
  p_symbol        text,
  p_maker_fee_bps integer,
  p_taker_fee_bps integer,
  p_environment   text DEFAULT 'paper',
  p_operator_id   uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_m      public.markets;
  v_before jsonb;
BEGIN
  v_op := public.assert_operator('markets.write', p_operator_id);
  SELECT * INTO v_m FROM public.markets
   WHERE symbol = p_symbol AND environment = p_environment FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown market % in %', p_symbol, p_environment USING ERRCODE = 'no_data_found';
  END IF;
  v_before := jsonb_build_object('maker_fee_bps', v_m.maker_fee_bps, 'taker_fee_bps', v_m.taker_fee_bps);
  UPDATE public.markets
     SET maker_fee_bps = p_maker_fee_bps, taker_fee_bps = p_taker_fee_bps
   WHERE id = v_m.id;
  PERFORM public.log_operator_action(
    'admin.market.fees_changed', 'market', v_m.id, NULL,
    jsonb_build_object('before', v_before,
                       'after', jsonb_build_object('maker_fee_bps', p_maker_fee_bps, 'taker_fee_bps', p_taker_fee_bps)),
    v_op);
  RETURN v_m.id;
END $fn$;

COMMENT ON FUNCTION public.admin_set_market_fees(text, integer, integer, text, uuid) IS
  'Operator action (markets.write): change only the maker/taker fee bps of an existing market. Writes an admin.market.fees_changed audit row with before/after.';

CREATE OR REPLACE FUNCTION public.admin_set_market_status(
  p_symbol      text,
  p_status      text,
  p_environment text DEFAULT 'paper',
  p_operator_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_m      public.markets;
  v_before jsonb;
BEGIN
  v_op := public.assert_operator('markets.write', p_operator_id);
  SELECT * INTO v_m FROM public.markets WHERE symbol = p_symbol AND environment = p_environment FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown market % in %', p_symbol, p_environment USING ERRCODE = 'no_data_found';
  END IF;
  v_before := jsonb_build_object('status', v_m.status, 'is_active', v_m.is_active);
  UPDATE public.markets
     SET status = p_status, is_active = (p_status = 'trading')
   WHERE id = v_m.id;
  PERFORM public.log_operator_action(
    'admin.market.status_changed', 'market', v_m.id, NULL,
    jsonb_build_object('before', v_before,
                       'after', jsonb_build_object('status', p_status, 'is_active', p_status = 'trading')),
    v_op);
  RETURN v_m.id;
END $fn$;

COMMENT ON FUNCTION public.admin_set_market_status(text, text, text, uuid) IS
  'Operator action (markets.write): halt/resume a market. trading => is_active true; halted/post_only/disabled => is_active false. Writes an admin.market.status_changed audit row.';

CREATE OR REPLACE FUNCTION public.admin_register_deposit_network(
  p_asset_symbol           text,
  p_network                text,
  p_required_confirmations integer,
  p_chain_id               bigint DEFAULT NULL,
  p_requires_memo          boolean DEFAULT false,
  p_min_deposit_units      numeric DEFAULT NULL,
  p_deposit_enabled        boolean DEFAULT false,
  p_operator_id            uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_id     uuid;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  v_op := public.assert_operator('markets.write', p_operator_id);
  SELECT to_jsonb(dn) INTO v_before
    FROM public.deposit_networks dn JOIN public.assets a ON a.id = dn.asset_id
   WHERE a.symbol = p_asset_symbol AND dn.network = p_network AND dn.environment = public.app_mode();
  v_id := public.register_deposit_network(p_asset_symbol, p_network, p_required_confirmations,
                                          p_chain_id, p_requires_memo, p_min_deposit_units, p_deposit_enabled);
  SELECT to_jsonb(dn) INTO v_after FROM public.deposit_networks dn WHERE dn.id = v_id;
  PERFORM public.log_operator_action(
    'admin.deposit_network.upserted', 'deposit_network', v_id, NULL,
    jsonb_build_object('before', COALESCE(v_before, 'null'::jsonb), 'after', v_after), v_op);
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.admin_register_deposit_network(text, text, integer, bigint, boolean, numeric, boolean, uuid) IS
  'Operator action (markets.write): authorised wrapper over the existing register_deposit_network(). Reused, not duplicated. Writes an admin.deposit_network.upserted audit row with before/after.';

CREATE OR REPLACE FUNCTION public.admin_register_withdrawal_network(
  p_asset_symbol       text,
  p_network            text,
  p_min_withdrawal_units numeric,
  p_max_withdrawal_units numeric,
  p_fee_flat_units     numeric DEFAULT 0,
  p_fee_rate_bps       integer DEFAULT 0,
  p_requires_memo      boolean DEFAULT false,
  p_chain_id           bigint DEFAULT NULL,
  p_withdrawal_enabled boolean DEFAULT false,
  p_operator_id        uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_id     uuid;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  v_op := public.assert_operator('markets.write', p_operator_id);
  SELECT to_jsonb(wn) INTO v_before
    FROM public.withdrawal_networks wn JOIN public.assets a ON a.id = wn.asset_id
   WHERE a.symbol = p_asset_symbol AND wn.network = p_network AND wn.environment = public.app_mode();
  v_id := public.register_withdrawal_network(p_asset_symbol, p_network, p_min_withdrawal_units,
                                             p_max_withdrawal_units, p_fee_flat_units, p_fee_rate_bps,
                                             p_requires_memo, p_chain_id, p_withdrawal_enabled);
  SELECT to_jsonb(wn) INTO v_after FROM public.withdrawal_networks wn WHERE wn.id = v_id;
  PERFORM public.log_operator_action(
    'admin.withdrawal_network.upserted', 'withdrawal_network', v_id, NULL,
    jsonb_build_object('before', COALESCE(v_before, 'null'::jsonb), 'after', v_after), v_op);
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.admin_register_withdrawal_network(text, text, numeric, numeric, numeric, integer, boolean, bigint, boolean, uuid) IS
  'Operator action (markets.write): authorised wrapper over the existing register_withdrawal_network() (fees + min/max live there). Writes an admin.withdrawal_network.upserted audit row with before/after.';

-- ===========================================================================
-- 7. SYSTEM SETTINGS — maintenance mode + operator roster
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.admin_set_maintenance(
  p_enabled     boolean,
  p_note        text DEFAULT NULL,
  p_operator_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_before jsonb;
  v_after  jsonb;
BEGIN
  v_op := public.assert_operator('settings.write', p_operator_id);
  IF p_enabled IS NULL THEN
    RAISE EXCEPTION 'p_enabled is required (true to enter maintenance, false to leave it)'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_enabled AND (p_note IS NULL OR length(btrim(p_note)) < 3) THEN
    RAISE EXCEPTION 'entering maintenance mode requires a note (at least 3 characters) explaining why'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT jsonb_build_object('maintenance_mode', maintenance_mode, 'maintenance_note', maintenance_note,
                            'maintenance_set_at', maintenance_set_at, 'maintenance_set_by', maintenance_set_by)
    INTO v_before FROM public.app_settings WHERE id;

  UPDATE public.app_settings
     SET maintenance_mode    = p_enabled,
         maintenance_note    = CASE WHEN p_enabled THEN btrim(p_note) ELSE maintenance_note END,
         maintenance_set_at  = now(),
         maintenance_set_by  = v_op
   WHERE id;

  SELECT jsonb_build_object('maintenance_mode', maintenance_mode, 'maintenance_note', maintenance_note,
                            'maintenance_set_at', maintenance_set_at, 'maintenance_set_by', maintenance_set_by)
    INTO v_after FROM public.app_settings WHERE id;

  PERFORM public.log_operator_action(
    'admin.settings.maintenance_changed', 'app_settings', NULL, NULL,
    jsonb_build_object('before', v_before, 'after', v_after), v_op);
  RETURN v_after;
END $fn$;

COMMENT ON FUNCTION public.admin_set_maintenance(boolean, text, uuid) IS
  'Operator action (settings.write): turn maintenance mode on (a note is mandatory) or off. Touches ONLY the maintenance_* columns: mode stays paper and every LIVE_* flag is untouched. Writes an admin.settings.maintenance_changed audit row with before/after.';

CREATE OR REPLACE FUNCTION public.admin_set_operator_role(
  p_operator_username text,
  p_role              text,
  p_operator_id       uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_target public.admin_users;
BEGIN
  v_op := public.assert_operator('operators.write', p_operator_id);
  SELECT * INTO v_target FROM public.admin_users WHERE username = p_operator_username FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown operator %', p_operator_username USING ERRCODE = 'no_data_found';
  END IF;
  IF p_role IS NULL OR NOT EXISTS (SELECT 1 FROM public.operator_roles r WHERE r.code = p_role) THEN
    RAISE EXCEPTION 'unknown operator role % (superadmin|compliance|support|readonly)', p_role
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_target.operator_role = 'superadmin' AND p_role <> 'superadmin' THEN
    IF (SELECT count(*) FROM public.admin_users a
         WHERE a.operator_role = 'superadmin' AND a.is_active AND a.id <> v_target.id) = 0 THEN
      RAISE EXCEPTION 'refusing to demote % : it is the last active superadmin', v_target.username
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE public.admin_users
     SET operator_role = p_role, updated_at = now()
   WHERE id = v_target.id;

  PERFORM public.log_operator_action(
    'admin.operator.role_changed', 'admin_user', v_target.id, NULL,
    jsonb_build_object('before', jsonb_build_object('username', v_target.username, 'operator_role', v_target.operator_role),
                       'after', jsonb_build_object('username', v_target.username, 'operator_role', p_role)),
    v_op);
  RETURN jsonb_build_object('operator_id', v_target.id, 'username', v_target.username,
                            'role_before', v_target.operator_role, 'role_after', p_role);
END $fn$;

COMMENT ON FUNCTION public.admin_set_operator_role(text, text, uuid) IS
  'Operator action (operators.write, superadmin only): change another operator''s role. Refuses to demote the last active superadmin. Writes an admin.operator.role_changed audit row with before/after.';

CREATE OR REPLACE FUNCTION public.admin_set_operator_active(
  p_operator_username text,
  p_is_active         boolean,
  p_operator_id       uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_target public.admin_users;
BEGIN
  v_op := public.assert_operator('operators.write', p_operator_id);
  IF p_is_active IS NULL THEN
    RAISE EXCEPTION 'p_is_active is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO v_target FROM public.admin_users WHERE username = p_operator_username FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown operator %', p_operator_username USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT p_is_active AND v_target.operator_role = 'superadmin' THEN
    IF (SELECT count(*) FROM public.admin_users a
         WHERE a.operator_role = 'superadmin' AND a.is_active AND a.id <> v_target.id) = 0 THEN
      RAISE EXCEPTION 'refusing to deactivate % : it is the last active superadmin', v_target.username
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  UPDATE public.admin_users SET is_active = p_is_active, updated_at = now() WHERE id = v_target.id;

  PERFORM public.log_operator_action(
    'admin.operator.active_changed', 'admin_user', v_target.id, NULL,
    jsonb_build_object('before', jsonb_build_object('is_active', v_target.is_active),
                       'after', jsonb_build_object('is_active', p_is_active)),
    v_op);
  RETURN jsonb_build_object('operator_id', v_target.id, 'username', v_target.username,
                            'active_before', v_target.is_active, 'active_after', p_is_active);
END $fn$;

COMMENT ON FUNCTION public.admin_set_operator_active(text, boolean, uuid) IS
  'Operator action (operators.write, superadmin only): activate/deactivate an operator. Deactivation never deletes the row or its audit history, and the last active superadmin cannot be deactivated.';
-- ===========================================================================
-- 9. PAGINATION-ORIENTED INDEXES FOR THE ADMIN MONITORING VIEWS
-- ===========================================================================
-- The views are ordered newest-first on (created_at, id); these keep a page of
-- them from scanning the whole table as the data grows. They are additions to
-- the existing per-user indexes, not replacements.
CREATE INDEX IF NOT EXISTS deposits_admin_created_idx
  ON public.deposits (created_at DESC, id);
CREATE INDEX IF NOT EXISTS deposits_admin_status_idx
  ON public.deposits (status, created_at DESC);
CREATE INDEX IF NOT EXISTS withdrawal_requests_admin_created_idx
  ON public.withdrawal_requests (created_at DESC, id);
CREATE INDEX IF NOT EXISTS withdrawal_requests_admin_status_idx
  ON public.withdrawal_requests (status, created_at DESC);
CREATE INDEX IF NOT EXISTS orders_admin_status_created_idx
  ON public.orders (status, created_at DESC);
CREATE INDEX IF NOT EXISTS trades_admin_created_idx
  ON public.trades (created_at DESC, id);
-- security_audit_log already has subject/action indexes from step 8; this one
-- serves the newest-first page of v_admin_security_events.
CREATE INDEX IF NOT EXISTS security_audit_log_at_idx
  ON public.security_audit_log (at DESC, id);

-- ===========================================================================
-- 10. RLS + PRIVILEGES ON THE NEW OBJECTS
-- ===========================================================================
-- The four new tables are operator-only. They are NOT readable or writable by
-- anon or authenticated at any privilege level: operators reach them through
-- the SECURITY DEFINER functions and the role-scoped views above, never by
-- touching the tables. RLS is enabled with no policy, which is the second,
-- independent lock (as on admin_users).
ALTER TABLE public.operator_roles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operator_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.account_restrictions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.risk_flags           ENABLE ROW LEVEL SECURITY;

DO $fn$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'operator_roles', 'operator_permissions', 'account_restrictions', 'risk_flags'
  ] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon', t);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM authenticated', t);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT SELECT, INSERT, UPDATE ON public.%I TO service_role', t);
    END IF;
  END LOOP;
END $fn$;

COMMENT ON TABLE public.operator_roles IS
  'Operator role reference data (superadmin/compliance/support/readonly). RLS on, no policy: readable only by the SECURITY DEFINER functions.';

-- the role-scoped admin views: readable by a signed-in caller, but each view
-- filters on the caller''s operator role, so a non-operator sees zero rows.
DO $fn$
DECLARE
  v text;
BEGIN
  FOREACH v IN ARRAY ARRAY[
    'v_admin_users', 'v_admin_balances', 'v_admin_open_orders', 'v_admin_deposits',
    'v_admin_withdrawals', 'v_admin_trades', 'v_admin_kyc_queue', 'v_admin_restrictions',
    'v_admin_risk_flags', 'v_admin_security_events', 'v_admin_operators'
  ] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon', v);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('GRANT SELECT ON public.%I TO authenticated', v);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
      EXECUTE format('GRANT SELECT ON public.%I TO service_role', v);
    END IF;
  END LOOP;
END $fn$;

-- ---------------------------------------------------------------------------
-- function ACLs — the same pattern as 20261005100090/…100/…120/…130/…140:
-- PUBLIC and both client roles are revoked explicitly and only service_role gets
-- EXECUTE back. The admin functions are NOT callable with the anon or an
-- authenticated key: an operator reaches them through a server-side call (an
-- edge function holding the service key, which resolves the operator per the
-- resolve_operator() contract). The documented client-facing read entry point is
-- the set of v_admin_* views, not any function.
--
-- This block runs LAST on purpose: it resolves every signature, so every
-- function above must already exist when the migration reaches it.
-- ---------------------------------------------------------------------------
DO $fn$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
         'maintenance_mode', 'assert_not_in_maintenance', 'assert_account_not_restricted',
         'operator_can', 'operator_can_do', 'current_operator_id', 'current_operator_role',
         'resolve_operator', 'assert_operator', 'log_operator_action',
         'admin_set_restriction', 'admin_clear_restriction',
         'admin_add_risk_flag', 'admin_resolve_risk_flag',
         'admin_kyc_set_under_review', 'admin_kyc_approve', 'admin_kyc_reject',
         'admin_list_users', 'admin_user_overview', 'admin_list_security_events',
         'admin_upsert_market', 'admin_set_market_fees', 'admin_set_market_status',
         'admin_register_deposit_network', 'admin_register_withdrawal_network',
         'admin_set_maintenance', 'admin_set_operator_role', 'admin_set_operator_active'
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
END $fn$;

-- the four read-only identity helpers a signed-in operator needs in order to use
-- the role-scoped admin views (the views call operator_can_do()/current_operator_*,
-- and PostgreSQL checks EXECUTE on a function referenced by a view against the
-- INVOKING role). They take no arguments, cannot resolve or grant anything, and
-- read only admin_users/operator_permissions, so this is the documented minimum.
DO $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.current_operator_id()   TO authenticated;
    GRANT EXECUTE ON FUNCTION public.current_operator_role() TO authenticated;
    GRANT EXECUTE ON FUNCTION public.operator_can(text, text) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.operator_can_do(text)   TO authenticated;
  END IF;
END $fn$;

-- ---------------------------------------------------------------------------
-- the pre-existing money-path entry points this migration replaced: their ACLs
-- are preserved by CREATE OR REPLACE, and this block asserts that (a replaced
-- function that accidentally lost its grant would silently break the engine).
-- ---------------------------------------------------------------------------
DO $fn$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.place_order(text, text, text, numeric, numeric, text, text, uuid) TO authenticated;
    GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, text, uuid) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION public.place_order(text, text, text, numeric, numeric, text, text, uuid) TO service_role;
    GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, text, uuid) TO service_role;
    GRANT EXECUTE ON FUNCTION public._deposit_ingest(text, uuid, text, text, text, numeric, integer, text, text, integer, jsonb) TO service_role;
    GRANT EXECUTE ON FUNCTION public.credit_deposit(uuid) TO service_role;
    GRANT EXECUTE ON FUNCTION public._withdrawal_ingest(text, uuid, text, text, text, numeric, text, text, text, jsonb) TO service_role;
    GRANT EXECUTE ON FUNCTION public.approve_withdrawal(uuid) TO service_role;
  END IF;
END $fn$;

-- ---------------------------------------------------------------------------
-- the operator roster notice: privilege is never granted silently
-- ---------------------------------------------------------------------------
DO $fn$
DECLARE
  v_admin_role text;
BEGIN
  SELECT operator_role INTO v_admin_role FROM public.admin_users WHERE username = 'admin';
  IF FOUND THEN
    RAISE NOTICE '[admin operations] the pre-existing admin_users row ''admin'' is an operator with role %; promote it explicitly (select public.admin_set_operator_role(''admin'', ''superadmin'', <an operator id>)) or provision a superadmin row', v_admin_role;
  END IF;
  RAISE NOTICE '[admin operations] maintenance_mode = %, app_settings.mode unchanged (paper/live untouched), no LIVE_* flag was modified',
    public.maintenance_mode();
END $fn$;

RESET search_path;
