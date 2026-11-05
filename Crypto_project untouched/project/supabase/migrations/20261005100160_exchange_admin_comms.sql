/*
# 20261005100160 — exchange admin support, communications & status views (stage 2, part 2)

DB layer + functions + tests. Nothing here is deployed: no `db push` was run against
ctrazoqbudsfkpawpomv, no edge function, no frontend, no money path changed.

Built ON the stage-2 part-1 control plane (migration 20261005100150): every write in
this migration starts with `assert_operator(<action>, p_operator_id)` and ends with
`log_operator_action(...)`, so the actor identity contract is identical to PR #7 —
JWT callers resolve through `admin_users.auth_user_id`, service_role callers through
the explicit `p_operator_id` or the transaction-local `gtvx.operator_id` GUC. No
second identity mechanism is introduced.

## What this migration adds

### 1. Support management over the EXISTING chat tables (support.read / support.write)
`admin_list_support_conversations`, `admin_get_support_conversation`,
`admin_support_reply`, `admin_support_set_status`.

These read and write `chat_conversations` / `chat_messages` — the tables the original
live-chat migration created, which the site's visitor widget and the admin-chat edge
function already use. **The user-side chat RLS is NOT touched** (the tables stay
world-readable to anon/authenticated by the original design; that is a PARKED OWNER
DECISION and this migration deliberately leaves it exactly as it is — flagged again in
the report and in SCHEMA.md). What this migration adds is a *role-scoped, audited
operator path* on top: support operators list conversations, read a thread, reply as
`sender = 'agent'` and close/reopen a conversation, and every one of those actions
writes a `security_audit_log` row with a real operator actor.

Only additive indexes are added to the two chat tables (no columns, no policies, no
grants, no constraints — the status value is validated inside the RPC because the
table has no CHECK constraint and adding one could reject existing rows).

### 2. Notifications (notifications.send / notifications.broadcast)
`notifications(id, user_id NULL = broadcast, type, title, body, read_at, created_at,
created_by)`.
- `admin_send_notification(user, type, title, body)` — notifications.send
  (superadmin/compliance/support), audited `admin.notification.sent`.
- `admin_broadcast_notification(type, title, body)` — notifications.broadcast
  (superadmin only), audited `admin.notification.broadcast`.
- User side: RLS lets a signed-in user SELECT their own rows **and** broadcast rows
  (`user_id IS NULL`); there is no client write path at all. `user_mark_notification_read(id)`
  is the only user-callable function: it marks **their own** row read and refuses a
  broadcast row, because per-user read state for a broadcast needs a join table
  (documented limitation, stage 3) and silently marking a shared row read for every
  customer would be a lie.
- No notification is seeded, generated or faked anywhere. An empty table is the
  honest state.

### 3. Announcements (announcements.write, superadmin only)
`announcements(id, title, body, active_from, active_to, created_by, active,
created_at, deactivated_at, deactivated_by)`.
- `admin_create_announcement(title, body, active_from, active_to)` and
  `admin_deactivate_announcement(id)` — audited `admin.announcement.created|deactivated`.
  Deactivation keeps the row (append-only history), it never deletes it.
- Public read path: `v_public_announcements`, SELECT-able by anon and authenticated,
  returning ONLY rows that are active **and** inside their active window. Empty when
  no announcement exists — the view never invents one.

### 4. Custody / wallet status view — `v_admin_custody` (money.read)
Per system account (`accounts.account_type = 'system'`: PAPER_FAUCET, FEE_INCOME,
EXTERNAL_DEPOSIT, WITHDRAWAL_CLEARING, …) and environment: the cached balance, the
**ledger sum** for that account, the entry count, and an explicit `connectivity`
column. `connectivity` is the constant `'not_connected'` on every row: there is no
live chain connectivity in this build, and the view must never pretend otherwise.
Stage 7 (real provider adapters) is what changes that column. The tests assert both
facts: `connectivity = 'not_connected'` everywhere, and `ledger_units = balance_units`
for every system account (reconciliation-ready input for stage 4).

### 5. Liquidity / market-maker monitoring view — `v_admin_liquidity` (money.read)
Per market, from the real order book (`v_order_book_depth`): open order count, level
counts, best bid/ask and their quantities, the spread, and depth inside the top 5
price levels (plus the full depth for context). A market with no resting orders gets
one row with `open_order_count = 0`, NULL best bid/ask, NULL spread and 0 depth — an
explicit empty state. **No depth, size or maker is ever fabricated**; there is no
market maker in this build, and the view does not imply one.

### 6. Risk / security alerts view — `v_admin_alerts` (security.read)
A UNION of three honest sources, per user: active `account_restrictions`, unresolved
`risk_flags`, and `security_audit_log` sensitive actions from the last 7 days
(`kyc.*`, `security.*`, `withdrawal.*`, `admin.restriction.*`, `admin.risk_flag.*`)
that name a subject user. It is a **queryable view, not an alerting engine**: nothing
pushes, pages, retries or deduplicates, and no notification is generated from it.
Real-time alerting is the realtime stage (stage 3) and is documented as not existing.

### 7. Permission matrix additions (data, not code)
Five new actions, 20 new cells, added to the PR #7 matrix (deny by default):
`support.read`, `support.write`, `notifications.send`, `notifications.broadcast`,
`announcements.write`. `v_admin_custody` / `v_admin_liquidity` reuse the existing
`money.read` cell and `v_admin_alerts` reuses the existing `security.read` cell, so no
new action is invented for a read that already has one.

| action | superadmin | compliance | support | readonly |
|---|---|---|---|---|
| support.read | ✓ | ✓ | ✓ | ✓ |
| support.write | ✓ | ✓ | ✓ | — |
| notifications.send | ✓ | ✓ | ✓ | — |
| notifications.broadcast | ✓ | — | — | — |
| announcements.write | ✓ | — | — | — |

**This changes the PR #7 test expectations** (matrix cell count, per-role allowed
lists and the `admin_*` function count). `exchange_admin_tests.sql` is updated to the
new numbers — the same assertions, re-based, not weakened: see the report.

## Deliberately out of scope
Edge functions, the admin frontend, real-time delivery (websockets/realtime channels),
email/SMS/push providers, per-user broadcast read receipts, live custody connectivity,
a market maker, an alerting engine. No money-path function is re-created here.

## Conventions
Function bodies use `$fn$` / `$do$` dollar quotes rather than `$$` so a toolchain that
mangles `$$` cannot silently corrupt them.
*/

SET search_path = public, pg_temp;

-- ===========================================================================
-- 1. PERMISSION MATRIX ADDITIONS (data, not code)
-- ===========================================================================
-- Five new actions x four roles = 20 cells. Every role gets an explicit ALLOW or
-- DENY, so the "no missing cell" invariant of the PR #7 matrix still holds.
INSERT INTO public.operator_permissions (role_code, action, allowed) VALUES
  ('superadmin', 'support.read',            true),
  ('superadmin', 'support.write',           true),
  ('superadmin', 'notifications.send',      true),
  ('superadmin', 'notifications.broadcast', true),
  ('superadmin', 'announcements.write',     true),

  ('compliance', 'support.read',            true),
  ('compliance', 'support.write',           true),
  ('compliance', 'notifications.send',      true),
  ('compliance', 'notifications.broadcast', false),
  ('compliance', 'announcements.write',     false),

  ('support',    'support.read',            true),
  ('support',    'support.write',           true),
  ('support',    'notifications.send',      true),
  ('support',    'notifications.broadcast', false),
  ('support',    'announcements.write',     false),

  ('readonly',   'support.read',            true),
  ('readonly',   'support.write',           false),
  ('readonly',   'notifications.send',      false),
  ('readonly',   'notifications.broadcast', false),
  ('readonly',   'announcements.write',     false)
ON CONFLICT (role_code, action) DO NOTHING;

COMMENT ON TABLE public.operator_permissions IS
  'The operator permission matrix, one row per (role, action). assert_operator() is the only reader that matters: every admin function calls it before doing anything. 20261005100160 added support.read, support.write, notifications.send, notifications.broadcast and announcements.write (20 cells). Changing a cell is an owner decision.';

-- ===========================================================================
-- 2. SUPPORT MANAGEMENT OVER THE EXISTING CHAT TABLES
-- ===========================================================================
-- These functions are the operator path over chat_conversations / chat_messages.
-- The user-side RLS of those tables is untouched (parked owner decision): the
-- visitor widget keeps working exactly as before, and this is a role-scoped,
-- audited operator surface layered on top of it, not a replacement.

CREATE OR REPLACE FUNCTION public.admin_list_support_conversations(
  p_status      text    DEFAULT NULL,
  p_limit       integer DEFAULT 50,
  p_offset      integer DEFAULT 0,
  p_operator_id uuid    DEFAULT NULL
)
RETURNS TABLE (
  conversation_id uuid,
  visitor_id      text,
  visitor_name    text,
  status          text,
  created_at      timestamptz,
  updated_at      timestamptz,
  message_count   bigint,
  last_message_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_status text := NULLIF(lower(btrim(COALESCE(p_status, ''))), '');
BEGIN
  v_op := public.assert_operator('support.read', p_operator_id);
  IF v_status IS NOT NULL AND v_status NOT IN ('open', 'closed') THEN
    RAISE EXCEPTION 'unknown conversation status % (open|closed)', p_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 200 THEN
    RAISE EXCEPTION 'p_limit must be between 1 and 200 (got %)', p_limit
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF COALESCE(p_offset, 0) < 0 THEN
    RAISE EXCEPTION 'p_offset must be >= 0' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  PERFORM public.log_operator_action(
    'admin.support.conversations_listed', 'chat_conversation', NULL, NULL,
    jsonb_build_object('status_filter', v_status, 'limit', p_limit, 'offset', COALESCE(p_offset, 0)),
    v_op);

  RETURN QUERY
  SELECT c.id, c.visitor_id, c.visitor_name, c.status, c.created_at, c.updated_at,
         (SELECT count(*) FROM public.chat_messages m WHERE m.conversation_id = c.id),
         (SELECT max(m.created_at) FROM public.chat_messages m WHERE m.conversation_id = c.id)
    FROM public.chat_conversations c
   WHERE v_status IS NULL OR c.status = v_status
   ORDER BY c.updated_at DESC NULLS LAST, c.id
   LIMIT p_limit OFFSET COALESCE(p_offset, 0);
END $fn$;

COMMENT ON FUNCTION public.admin_list_support_conversations(text, integer, integer, uuid) IS
  'Operator action (support.read): newest-first page of support conversations with their message count and last message time. Reads the EXISTING chat_conversations table; user-side chat RLS is unchanged. Audited as admin.support.conversations_listed.';

CREATE OR REPLACE FUNCTION public.admin_get_support_conversation(
  p_conversation_id uuid,
  p_operator_id     uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op   uuid;
  v_conv public.chat_conversations;
  v_msgs jsonb;
BEGIN
  v_op := public.assert_operator('support.read', p_operator_id);
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'a conversation id is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO v_conv FROM public.chat_conversations WHERE id = p_conversation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown conversation %', p_conversation_id USING ERRCODE = 'no_data_found';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'message_id', m.id, 'sender', m.sender, 'content', m.content, 'created_at', m.created_at
         ) ORDER BY m.created_at, m.id), '[]'::jsonb)
    INTO v_msgs
    FROM public.chat_messages m
   WHERE m.conversation_id = p_conversation_id;

  PERFORM public.log_operator_action(
    'admin.support.conversation_read', 'chat_conversation', v_conv.id, NULL,
    jsonb_build_object('status', v_conv.status, 'message_count', jsonb_array_length(v_msgs)), v_op);

  RETURN jsonb_build_object(
    'conversation_id', v_conv.id,
    'visitor_id', v_conv.visitor_id,
    'visitor_name', v_conv.visitor_name,
    'status', v_conv.status,
    'created_at', v_conv.created_at,
    'updated_at', v_conv.updated_at,
    'messages', v_msgs);
END $fn$;

COMMENT ON FUNCTION public.admin_get_support_conversation(uuid, uuid) IS
  'Operator action (support.read): one support conversation with its full message thread as JSON. Audited as admin.support.conversation_read. Reads the EXISTING chat tables only.';

CREATE OR REPLACE FUNCTION public.admin_support_reply(
  p_conversation_id uuid,
  p_content         text,
  p_operator_id     uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_conv   public.chat_conversations;
  v_msg_id uuid;
  v_body   text := btrim(COALESCE(p_content, ''));
BEGIN
  v_op := public.assert_operator('support.write', p_operator_id);
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'a conversation id is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_body = '' OR length(v_body) > 4000 THEN
    RAISE EXCEPTION 'a reply needs between 1 and 4000 characters' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO v_conv FROM public.chat_conversations WHERE id = p_conversation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown conversation %', p_conversation_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_conv.status = 'closed' THEN
    RAISE EXCEPTION 'conversation % is closed: reopen it before replying', v_conv.id
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO public.chat_messages (conversation_id, sender, content)
  VALUES (v_conv.id, 'agent', v_body)
  RETURNING id INTO v_msg_id;

  UPDATE public.chat_conversations SET updated_at = now() WHERE id = v_conv.id;

  PERFORM public.log_operator_action(
    'admin.support.replied', 'chat_message', v_msg_id, NULL,
    jsonb_build_object('conversation_id', v_conv.id, 'sender', 'agent', 'length', length(v_body)), v_op);
  RETURN v_msg_id;
END $fn$;

COMMENT ON FUNCTION public.admin_support_reply(uuid, text, uuid) IS
  'Operator action (support.write): post an operator reply into an open conversation as sender = agent. Refuses a closed conversation. Audited as admin.support.replied with the operator as actor. Writes the EXISTING chat_messages table (user-side RLS unchanged).';

CREATE OR REPLACE FUNCTION public.admin_support_set_status(
  p_conversation_id uuid,
  p_status          text,
  p_operator_id     uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_conv   public.chat_conversations;
  v_status text := lower(btrim(COALESCE(p_status, '')));
BEGIN
  v_op := public.assert_operator('support.write', p_operator_id);
  IF p_conversation_id IS NULL THEN
    RAISE EXCEPTION 'a conversation id is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_status NOT IN ('open', 'closed') THEN
    RAISE EXCEPTION 'unknown conversation status % (open|closed)', COALESCE(p_status, 'NULL')
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO v_conv FROM public.chat_conversations WHERE id = p_conversation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown conversation %', p_conversation_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_conv.status = v_status THEN
    RAISE EXCEPTION 'conversation % is already %', v_conv.id, v_status
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.chat_conversations
     SET status = v_status, updated_at = now()
   WHERE id = v_conv.id;

  PERFORM public.log_operator_action(
    'admin.support.status_changed', 'chat_conversation', v_conv.id, NULL,
    jsonb_build_object('before', jsonb_build_object('status', v_conv.status),
                       'after',  jsonb_build_object('status', v_status)), v_op);

  RETURN jsonb_build_object('conversation_id', v_conv.id,
                            'status_before', v_conv.status, 'status_after', v_status);
END $fn$;

COMMENT ON FUNCTION public.admin_support_set_status(uuid, text, uuid) IS
  'Operator action (support.write): close or reopen a support conversation. Refuses a no-op. Audited as admin.support.status_changed with before/after. User-side chat RLS is unchanged.';

-- additive indexes only — no column, policy, grant or constraint change on the
-- original chat tables (the parked owner decision stays parked)
CREATE INDEX IF NOT EXISTS chat_messages_conversation_created_idx
  ON public.chat_messages (conversation_id, created_at);
CREATE INDEX IF NOT EXISTS chat_conversations_updated_idx
  ON public.chat_conversations (updated_at DESC);

-- ===========================================================================
-- 3. NOTIFICATIONS
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  type text NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.admin_users(id) ON DELETE SET NULL,
  CONSTRAINT notifications_type_check  CHECK (length(btrim(type)) BETWEEN 3 AND 60),
  CONSTRAINT notifications_title_check CHECK (length(btrim(title)) BETWEEN 1 AND 200),
  CONSTRAINT notifications_body_check  CHECK (length(btrim(body)) BETWEEN 1 AND 4000),
  CONSTRAINT notifications_read_check  CHECK (read_at IS NULL OR read_at >= created_at)
);

CREATE INDEX IF NOT EXISTS notifications_user_idx
  ON public.notifications (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_broadcast_idx
  ON public.notifications (created_at DESC) WHERE user_id IS NULL;

COMMENT ON TABLE public.notifications IS
  'Operator/system notifications. user_id NULL = a broadcast visible to every signed-in user. read_at is the read state of a per-user row; a broadcast row cannot be marked read (per-user broadcast receipts need a join table — stage 3). RLS: a signed-in user selects their own rows and broadcasts and has no write path at all; no notification is ever seeded or fabricated.';
COMMENT ON COLUMN public.notifications.created_by IS 'admin_users.id of the operator who sent it (NULL only for a future system-generated notification; every admin_send/broadcast_notification row has one).';
COMMENT ON COLUMN public.notifications.read_at IS 'When the recipient read their own notification. Always NULL for a broadcast row: marking a shared row read would change the state for every customer.';

CREATE OR REPLACE FUNCTION public.admin_send_notification(
  p_user_id     uuid,
  p_type        text,
  p_title       text,
  p_body        text,
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
  v_op := public.assert_operator('notifications.send', p_operator_id);
  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'unknown user %: a notification belongs to exactly one user (use admin_broadcast_notification for everyone)', p_user_id
      USING ERRCODE = 'no_data_found';
  END IF;
  IF p_type IS NULL OR length(btrim(p_type)) < 3 THEN
    RAISE EXCEPTION 'a notification needs a type (at least 3 characters)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_title IS NULL OR btrim(p_title) = '' THEN
    RAISE EXCEPTION 'a notification needs a title' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'a notification needs a body' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, created_by)
  VALUES (p_user_id, lower(btrim(p_type)), btrim(p_title), btrim(p_body), v_op)
  RETURNING id INTO v_id;

  PERFORM public.log_operator_action(
    'admin.notification.sent', 'notification', v_id, p_user_id,
    jsonb_build_object('type', lower(btrim(p_type)), 'title', btrim(p_title), 'user_id', p_user_id), v_op);
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.admin_send_notification(uuid, text, text, text, uuid) IS
  'Operator action (notifications.send: superadmin/compliance/support): send one notification to one existing user. Audited as admin.notification.sent with the operator as actor.';

CREATE OR REPLACE FUNCTION public.admin_broadcast_notification(
  p_type        text,
  p_title       text,
  p_body        text,
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
  v_op := public.assert_operator('notifications.broadcast', p_operator_id);
  IF p_type IS NULL OR length(btrim(p_type)) < 3 THEN
    RAISE EXCEPTION 'a notification needs a type (at least 3 characters)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_title IS NULL OR btrim(p_title) = '' THEN
    RAISE EXCEPTION 'a notification needs a title' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'a notification needs a body' USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO public.notifications (user_id, type, title, body, created_by)
  VALUES (NULL, lower(btrim(p_type)), btrim(p_title), btrim(p_body), v_op)
  RETURNING id INTO v_id;

  PERFORM public.log_operator_action(
    'admin.notification.broadcast', 'notification', v_id, NULL,
    jsonb_build_object('type', lower(btrim(p_type)), 'title', btrim(p_title), 'scope', 'broadcast'), v_op);
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.admin_broadcast_notification(text, text, text, uuid) IS
  'Operator action (notifications.broadcast: superadmin only): write ONE row with user_id NULL, visible to every signed-in user. Audited as admin.notification.broadcast.';

CREATE OR REPLACE FUNCTION public.user_mark_notification_read(p_notification_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_uid uuid := auth.uid();
  v_n   public.notifications;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'a signed-in user is required to mark a notification read'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_notification_id IS NULL THEN
    RAISE EXCEPTION 'a notification id is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO v_n FROM public.notifications WHERE id = p_notification_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown notification %', p_notification_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_n.user_id IS NULL THEN
    RAISE EXCEPTION 'notification % is a broadcast: per-user read state for a broadcast is not stored yet (needs a per-user receipt table, stage 3) — refusing to mark a shared row read for every customer', v_n.id
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_n.user_id <> v_uid THEN
    RAISE EXCEPTION 'notification % does not belong to the calling user', v_n.id
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  UPDATE public.notifications
     SET read_at = COALESCE(read_at, now())
   WHERE id = v_n.id
  RETURNING * INTO v_n;

  RETURN jsonb_build_object('notification_id', v_n.id, 'read_at', v_n.read_at, 'already_read', v_n.read_at < now());
END $fn$;

COMMENT ON FUNCTION public.user_mark_notification_read(uuid) IS
  'User action: mark ONE of the CALLING user''s own notifications read (idempotent). Refuses another user''s row and refuses a broadcast row, whose per-user read state needs a receipt table (stage 3). The only function in this migration granted to authenticated.';

-- ===========================================================================
-- 4. ANNOUNCEMENTS
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.announcements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  body text NOT NULL,
  active_from timestamptz NOT NULL DEFAULT now(),
  active_to timestamptz,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid NOT NULL REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  deactivated_at timestamptz,
  deactivated_by uuid REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  CONSTRAINT announcements_title_check CHECK (length(btrim(title)) BETWEEN 3 AND 200),
  CONSTRAINT announcements_body_check  CHECK (length(btrim(body)) BETWEEN 3 AND 4000),
  CONSTRAINT announcements_window_check CHECK (active_to IS NULL OR active_to > active_from),
  CONSTRAINT announcements_active_check CHECK (
    (active AND deactivated_at IS NULL AND deactivated_by IS NULL)
    OR (NOT active AND deactivated_at IS NOT NULL AND deactivated_by IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS announcements_window_idx
  ON public.announcements (active, active_from, active_to);

COMMENT ON TABLE public.announcements IS
  'Operator announcements (superadmin only). created_by is NOT NULL: an anonymous announcement is impossible. Deactivation sets active = false and keeps the row (history is never deleted). The public read path is v_public_announcements, which returns only active rows inside their window. No announcement is ever seeded.';
COMMENT ON COLUMN public.announcements.active_to IS 'End of the active window; NULL = no expiry.';
COMMENT ON COLUMN public.announcements.active IS 'Operator-controlled visibility switch, set to false by admin_deactivate_announcement (never by deleting the row).';

CREATE OR REPLACE FUNCTION public.admin_create_announcement(
  p_title       text,
  p_body        text,
  p_active_from timestamptz DEFAULT NULL,
  p_active_to   timestamptz DEFAULT NULL,
  p_operator_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op   uuid;
  v_from timestamptz := COALESCE(p_active_from, now());
  v_id   uuid;
BEGIN
  v_op := public.assert_operator('announcements.write', p_operator_id);
  IF p_title IS NULL OR length(btrim(p_title)) < 3 THEN
    RAISE EXCEPTION 'an announcement needs a title (at least 3 characters)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_body IS NULL OR length(btrim(p_body)) < 3 THEN
    RAISE EXCEPTION 'an announcement needs a body (at least 3 characters)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_active_to IS NOT NULL AND p_active_to <= v_from THEN
    RAISE EXCEPTION 'the active window is empty: active_to (%) must be after active_from (%)', p_active_to, v_from
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  INSERT INTO public.announcements (title, body, active_from, active_to, created_by)
  VALUES (btrim(p_title), btrim(p_body), v_from, p_active_to, v_op)
  RETURNING id INTO v_id;

  PERFORM public.log_operator_action(
    'admin.announcement.created', 'announcement', v_id, NULL,
    jsonb_build_object('title', btrim(p_title), 'active_from', v_from, 'active_to', p_active_to), v_op);
  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.admin_create_announcement(text, text, timestamptz, timestamptz, uuid) IS
  'Operator action (announcements.write: superadmin only): publish an announcement with an explicit active window (active_from defaults to now(), active_to NULL = no expiry). Audited as admin.announcement.created.';

CREATE OR REPLACE FUNCTION public.admin_deactivate_announcement(
  p_announcement_id uuid,
  p_operator_id     uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op uuid;
  v_a  public.announcements;
BEGIN
  v_op := public.assert_operator('announcements.write', p_operator_id);
  IF p_announcement_id IS NULL THEN
    RAISE EXCEPTION 'an announcement id is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT * INTO v_a FROM public.announcements WHERE id = p_announcement_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown announcement %', p_announcement_id USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT v_a.active THEN
    RAISE EXCEPTION 'announcement % was already deactivated at %', v_a.id, v_a.deactivated_at
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.announcements
     SET active = false, deactivated_at = now(), deactivated_by = v_op
   WHERE id = v_a.id;

  PERFORM public.log_operator_action(
    'admin.announcement.deactivated', 'announcement', v_a.id, NULL,
    jsonb_build_object('before', jsonb_build_object('active', true, 'title', v_a.title),
                       'after',  jsonb_build_object('active', false, 'deactivated_by', v_op)), v_op);
  RETURN v_a.id;
END $fn$;

COMMENT ON FUNCTION public.admin_deactivate_announcement(uuid, uuid) IS
  'Operator action (announcements.write: superadmin only): take an announcement out of the public view. The row is kept (append-only history) and the action is audited as admin.announcement.deactivated.';

-- the public read path: ONLY active rows inside their window. Empty when none exist.
CREATE OR REPLACE VIEW public.v_public_announcements AS
SELECT a.id,
       a.title,
       a.body,
       a.active_from,
       a.active_to,
       a.created_at
  FROM public.announcements a
 WHERE a.active
   AND a.active_from <= now()
   AND (a.active_to IS NULL OR a.active_to > now());

COMMENT ON VIEW public.v_public_announcements IS
  'The public announcement feed: active rows whose window contains now(). Readable by anon and authenticated. Returns ZERO rows when no announcement exists or is currently active — nothing is ever invented, and no placeholder is returned.';

-- ===========================================================================
-- 5. CUSTODY / WALLET STATUS VIEW
-- ===========================================================================
-- Ledger-derived balance of every SYSTEM account, per asset and environment, plus
-- an explicit connectivity column that is the constant 'not_connected' on every
-- row: there is NO live chain connectivity in this build. Stage 7 wires real
-- custody adapters and is the only thing allowed to change that value.
CREATE OR REPLACE VIEW public.v_admin_custody AS
SELECT a.id AS account_id,
       a.code AS account_code,
       ast.symbol AS asset_symbol,
       a.asset_id,
       a.environment,
       a.kind,
       COALESCE(b.available_units, 0) AS available_units,
       COALESCE(b.locked_units, 0)    AS locked_units,
       COALESCE(b.available_units, 0) + COALESCE(b.locked_units, 0) AS balance_units,
       COALESCE((SELECT sum(e.amount_units) FROM public.ledger_entries e WHERE e.account_id = a.id), 0) AS ledger_units,
       (SELECT count(*) FROM public.ledger_entries e WHERE e.account_id = a.id) AS entry_count,
       'not_connected'::text AS connectivity,
       b.last_entry_at,
       a.created_at AS account_created_at
  FROM public.accounts a
  JOIN public.assets ast ON ast.id = a.asset_id
  LEFT JOIN public.balances b ON b.account_id = a.id
 WHERE a.account_type = 'system'
   AND public.operator_can_do('money.read');

COMMENT ON VIEW public.v_admin_custody IS
  'Custody status per SYSTEM account (PAPER_FAUCET, FEE_INCOME, EXTERNAL_DEPOSIT, WITHDRAWAL_CLEARING, ...) and environment: cached balance, the ledger sum for that account, entry count and an explicit connectivity column. connectivity is the constant not_connected everywhere because no live chain connectivity exists in this build (stage 7 wires it); the view never implies otherwise. Requires money.read. Stage-4 reconciliation input: balance_units = ledger_units on every row.';

-- ===========================================================================
-- 6. LIQUIDITY / MARKET-MAKER MONITORING VIEW
-- ===========================================================================
-- Aggregated from the REAL order book (v_order_book_depth). Depth is measured
-- inside the top 5 price levels (plus the full book for context). A market with
-- no resting orders gets one row with open_order_count = 0, NULL best bid/ask and
-- NULL spread and 0 depth: the honest empty state. There is no market maker in
-- this build and this view does not pretend there is one.
CREATE OR REPLACE VIEW public.v_admin_liquidity AS
WITH lvl AS (
  SELECT d.market_id,
         d.environment,
         d.side,
         d.price_units,
         d.qty_units,
         d.order_count,
         row_number() OVER (
           PARTITION BY d.market_id, d.environment, d.side
           ORDER BY CASE WHEN d.side = 'buy'  THEN d.price_units END DESC NULLS LAST,
                    CASE WHEN d.side = 'sell' THEN d.price_units END ASC  NULLS LAST
         ) AS level_rank
    FROM public.v_order_book_depth d
)
SELECT m.id AS market_id,
       m.symbol AS market_symbol,
       m.environment,
       m.status AS market_status,
       COALESCE(bid.order_count, 0) + COALESCE(ask.order_count, 0) AS open_order_count,
       COALESCE(bid.level_count, 0) AS bid_level_count,
       COALESCE(ask.level_count, 0) AS ask_level_count,
       bid.best_price_units AS best_bid_units,
       bid.best_qty_units   AS best_bid_qty_units,
       ask.best_price_units AS best_ask_units,
       ask.best_qty_units   AS best_ask_qty_units,
       CASE WHEN bid.best_price_units IS NOT NULL AND ask.best_price_units IS NOT NULL
            THEN ask.best_price_units - bid.best_price_units END AS spread_units,
       COALESCE(bid.depth_units_5, 0) AS bid_depth_units_5,
       COALESCE(ask.depth_units_5, 0) AS ask_depth_units_5,
       COALESCE(bid.depth_units_all, 0) AS bid_depth_units_all,
       COALESCE(ask.depth_units_all, 0) AS ask_depth_units_all
  FROM public.markets m
  LEFT JOIN LATERAL (
    SELECT count(*) AS level_count,
           sum(l.order_count) AS order_count,
           (array_agg(l.price_units ORDER BY l.level_rank))[1] AS best_price_units,
           (array_agg(l.qty_units   ORDER BY l.level_rank))[1] AS best_qty_units,
           sum(l.qty_units) FILTER (WHERE l.level_rank <= 5) AS depth_units_5,
           sum(l.qty_units) AS depth_units_all
      FROM lvl l
     WHERE l.market_id = m.id AND l.side = 'buy'
  ) bid ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS level_count,
           sum(l.order_count) AS order_count,
           (array_agg(l.price_units ORDER BY l.level_rank))[1] AS best_price_units,
           (array_agg(l.qty_units   ORDER BY l.level_rank))[1] AS best_qty_units,
           sum(l.qty_units) FILTER (WHERE l.level_rank <= 5) AS depth_units_5,
           sum(l.qty_units) AS depth_units_all
      FROM lvl l
     WHERE l.market_id = m.id AND l.side = 'sell'
  ) ask ON true
 WHERE public.operator_can_do('money.read');

COMMENT ON VIEW public.v_admin_liquidity IS
  'Per-market liquidity from the REAL order book: open order count, level counts, best bid/ask and their sizes, the spread, and depth inside the top 5 price levels (plus full depth). A market with no resting orders shows open_order_count = 0, NULL best bid/ask, NULL spread and 0 depth — the honest empty state. No size, depth or market maker is ever fabricated (there is no market maker in this build). Requires money.read.';

-- ===========================================================================
-- 7. ADMIN RISK / SECURITY ALERTS VIEW
-- ===========================================================================
-- A QUERYABLE VIEW, not an alerting engine: nothing pushes, pages, retries or
-- de-duplicates, and no notification row is generated from it. Real-time
-- alerting is stage 3. Sources, all real rows: active account restrictions,
-- unresolved risk flags, and sensitive security_audit_log actions from the last
-- 7 days that name a subject user.
CREATE OR REPLACE VIEW public.v_admin_alerts AS
SELECT x.alert_type, x.user_id, x.source_table, x.source_id, x.category, x.severity,
       x.raised_at, x.detail, x.raised_by, x.resolved_at
  FROM (
    SELECT 'account_restriction'::text AS alert_type,
           r.user_id,
           'account_restrictions'::text AS source_table,
           r.id AS source_id,
           r.scope AS category,
           'high'::text AS severity,
           r.set_at AS raised_at,
           r.reason AS detail,
           r.set_by AS raised_by,
           r.cleared_at AS resolved_at
      FROM public.account_restrictions r
     WHERE r.active

    UNION ALL

    SELECT 'risk_flag'::text,
           f.user_id,
           'risk_flags'::text,
           f.id,
           f.flag_type,
           f.severity,
           f.created_at,
           f.note,
           f.created_by,
           f.resolved_at
      FROM public.risk_flags f
     WHERE f.resolved_at IS NULL

    UNION ALL

    SELECT 'security_event'::text,
           a.subject_user_id,
           'security_audit_log'::text,
           a.id,
           a.action,
           CASE WHEN a.action ILIKE '%fail%' OR a.action ILIKE '%reject%' THEN 'high' ELSE 'medium' END,
           a.at,
           a.details::text,
           a.actor_id,
           NULL::timestamptz
      FROM public.security_audit_log a
     WHERE a.subject_user_id IS NOT NULL
       AND a.at >= now() - interval '7 days'
       AND (a.action LIKE 'kyc.%' OR a.action LIKE 'security.%'
            OR a.action LIKE 'withdrawal.%' OR a.action LIKE 'admin.restriction.%'
            OR a.action LIKE 'admin.risk_flag.%')
  ) x
 WHERE public.operator_can_do('security.read');

COMMENT ON VIEW public.v_admin_alerts IS
  'Operator risk/security alert feed per user: active account restrictions, unresolved risk flags and sensitive security_audit_log actions from the last 7 days. It is a QUERYABLE VIEW, not an alerting engine — nothing pushes, pages, retries or de-duplicates and no notification is generated from it; real-time alerting is the realtime stage (stage 3). Requires security.read (support gets zero rows). Empty when nothing is flagged.';

-- ===========================================================================
-- 8. RLS + PRIVILEGES ON THE NEW OBJECTS
-- ===========================================================================
-- notifications: the ONE table a signed-in user can read, and only their own rows
-- plus broadcasts. There is no client write path: read_at is written by
-- user_mark_notification_read() (SECURITY DEFINER), never by the client.
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notifications_select_own ON public.notifications;
CREATE POLICY notifications_select_own ON public.notifications
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR user_id IS NULL);

-- announcements: operator-only table (the public path is the view below)
ALTER TABLE public.announcements ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.notifications, public.announcements FROM PUBLIC;

DO $do$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['notifications', 'announcements'] LOOP
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
END $do$;

-- the only client-facing grant on a new table: SELECT on notifications, narrowed
-- by the RLS policy above. INSERT/UPDATE/DELETE stay revoked.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT SELECT ON public.notifications TO authenticated;
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON public.notifications FROM authenticated;
  END IF;
END $do$;

-- the public announcement feed: anon + authenticated may read the VIEW only
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    GRANT SELECT ON public.v_public_announcements TO anon;
    REVOKE ALL ON public.v_admin_custody, public.v_admin_liquidity, public.v_admin_alerts FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT SELECT ON public.v_public_announcements TO authenticated;
    GRANT SELECT ON public.v_admin_custody, public.v_admin_liquidity, public.v_admin_alerts TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT SELECT ON public.v_public_announcements, public.v_admin_custody,
                    public.v_admin_liquidity, public.v_admin_alerts TO service_role;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- function ACLs — same pattern as 20261005100150: PUBLIC and both client roles
-- are revoked explicitly and only service_role gets EXECUTE back, because the
-- operator path is a server-side call (an edge function holding the service key
-- which resolves the operator per the resolve_operator() contract). The single
-- exception is user_mark_notification_read(), the one user-facing function here.
--
-- This block runs LAST on purpose: it resolves every signature, so every function
-- above must already exist when the migration reaches it.
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
         'admin_list_support_conversations', 'admin_get_support_conversation',
         'admin_support_reply', 'admin_support_set_status',
         'admin_send_notification', 'admin_broadcast_notification',
         'admin_create_announcement', 'admin_deactivate_announcement'
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
END $do$;

DO $do$
BEGIN
  -- PostgreSQL grants EXECUTE on a new function to PUBLIC, and anon inherits it: the
  -- PUBLIC revoke is what actually keeps the user-facing function away from anon.
  REVOKE ALL ON FUNCTION public.user_mark_notification_read(uuid) FROM PUBLIC;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON FUNCTION public.user_mark_notification_read(uuid) FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.user_mark_notification_read(uuid) TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT EXECUTE ON FUNCTION public.user_mark_notification_read(uuid) TO service_role;
  END IF;
END $do$;

-- the four read-only identity helpers the new role-scoped views depend on must stay
-- executable by authenticated (PostgreSQL checks EXECUTE on functions referenced by a
-- view against the INVOKING role). Re-asserted here so this migration cannot leave
-- the PR #7 views or these three unusable.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    GRANT EXECUTE ON FUNCTION public.current_operator_id()     TO authenticated;
    GRANT EXECUTE ON FUNCTION public.current_operator_role()   TO authenticated;
    GRANT EXECUTE ON FUNCTION public.operator_can(text, text)  TO authenticated;
    GRANT EXECUTE ON FUNCTION public.operator_can_do(text)     TO authenticated;
  END IF;
END $do$;

-- ---------------------------------------------------------------------------
-- final NOTICE: the safety gate is unchanged by this migration
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_mode text;
  v_pt   boolean;
  v_lt   boolean;
  v_dep  boolean;
  v_wd   boolean;
  v_mm   boolean;
BEGIN
  SELECT mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled, maintenance_mode
    INTO v_mode, v_pt, v_lt, v_dep, v_wd, v_mm
    FROM public.app_settings;
  RAISE NOTICE '[admin comms] app_settings unchanged by this migration: mode=%, paper_trading=%, live_trading=%, deposits=%, withdrawals=%, maintenance_mode=%',
    v_mode, v_pt, v_lt, v_dep, v_wd, v_mm;
  RAISE NOTICE '[admin comms] custody connectivity is not_connected on every row (no live chain connectivity exists yet; stage 7 wires it)';
  RAISE NOTICE '[admin comms] user-side chat RLS on chat_conversations/chat_messages is UNCHANGED by this migration (parked owner decision)';
END $do$;

RESET search_path;
