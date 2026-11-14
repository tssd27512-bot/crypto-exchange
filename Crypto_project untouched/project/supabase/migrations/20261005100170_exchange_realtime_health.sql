/*
# 20261005100170 — realtime publication + operational health checks (stage 3)

DB layer + tests. Nothing here is deployed: no `db push` was run against
ctrazoqbudsfkpawpomv, no edge function, no frontend, no money path changed, every
LIVE_* flag stays false.

## What this migration adds

### 1. Realtime publication membership (security posture = the EXISTING RLS)
Eight user-facing event tables are members of the `supabase_realtime` publication:
`orders`, `trades`, `balances`, `deposits`, `withdrawal_requests`, `notifications`,
`chat_conversations`, `chat_messages`.

No new authorisation mechanism is introduced. Supabase Realtime applies the table's
RLS policies to each subscriber's row changes, so a subscriber only ever receives
events for rows their RLS allows them to read. That is why the migration REFUSES to
run if any member of the publication has RLS disabled: a table without RLS would
broadcast every row change to every subscriber.

`security_audit_log` is deliberately NOT added. It is operator-only, it names
subjects, actors and IPs, and a public publication would leak it. Admin risk and
security alerts therefore stay PULL-based (`v_admin_alerts`, PR #8). Putting the
audit trail on a realtime channel is an owner decision, not an engineering one.

`withdrawal_requests` is the real table name for withdrawals (there is no
`public.withdrawals`); the spec's "withdrawals" maps onto it.

Delivery itself is NOT verifiable here: a scratch PostgreSQL has no Realtime daemon
and its `wal_level` is `replica`, not `logical`. The migration records membership and
prints an honest NOTICE; end-to-end websocket delivery is a deployment-time
(production) verification step, not a scratch one. `system_health.realtime` therefore
stays `not_configured`.

### 2. Deposit / withdrawal status notifications (additive, no money-path change)
Two AFTER UPDATE triggers insert one `notifications` row when a deposit or a
withdrawal request actually changes status:

- `deposits` → type `deposit.status`
- `withdrawal_requests` → type `withdrawal.status`

They fire only on a real transition (`OLD.status IS DISTINCT FROM NEW.status`) and
only carry facts from the row itself (amount, asset, network, new status, txid). They
never invent an event, never retry, never write money, and never call a money-path
function. Each is wrapped so that a notification failure can never block or roll back
the status change that caused it: the warning is raised, the money path proceeds.

### 3. Operational health checks — `system_health`
`system_health(component PK, status, last_checked_at, detail jsonb, checked_by)` with
`status` CHECKed to exactly `ok | degraded | down | not_configured | not_connected`.

Seeded ONCE (INSERT ... ON CONFLICT DO NOTHING, so re-running never rewrites history)
with the truth of this build:

| component | seeded status | why |
|---|---|---|
| `database` | result of the real self-check at seed time (`ok`) | `run_db_self_check()` really runs |
| `market_data` | `not_configured` | no provider chosen (owner decision #3) |
| `blockchain:BTC` / `ETH` / `USDT` / `SOL` | `not_connected` | no chain connectivity exists; adapters are contracts only |
| `custodian` | `not_connected` | no custody provider chosen (owner decision #2) |
| `realtime` | `not_configured` | publication recorded, delivery unverified until deployment |

`run_db_self_check()` is a real check, not a constant: it counts ledger transactions
that do not sum to zero and balances that do not equal their ledger sum, and reports
both counts in the detail JSON. A non-zero count yields `degraded`.

`record_health(component, status, detail, checked_by)` — service_role only, enum
checked, refuses an unknown component (adding a component is an ops/owner decision,
not a provider's), and stores the detail JSON **verbatim**. It never "fixes" a
reported detail and never infers a status. This is the RPC future edge functions and
provider adapters call.

Views:
- `v_system_health` (authenticated) — component, status, last_checked_at only. No
  detail JSON: that is internal (counts, reasons, provider error text).
- `v_admin_system_health` (operator, `security.read`) — the same plus `checked_by`,
  the full `detail` JSON and `needs_attention` (true for `down`/`degraded`). Failure
  alerts are exactly this: `down`/`degraded` rows are visible here. Nothing pages,
  retries or invents a recovery.

`admin_health_recheck(operator)` — operator path, `security.read`, audited
`admin.health.recheck`. It runs **only** the database self-check and rewrites **only**
the `database` row. There is no override: it cannot mark a provider healthy, cannot
clear a `down` component and cannot touch `market_data`, `blockchain:*`, `custodian`
or `realtime`.

No new permission action is invented: the operator health view and the re-check reuse
the existing `security.read` cell (the same one `v_admin_alerts` uses), so the PR #7
matrix and its cell counts are unchanged.

## Deliberately out of scope
Realtime daemon/channel configuration, websocket client code, edge functions, the
frontend, provider adapters, alert paging/retry, per-user broadcast read state,
`security_audit_log` publication, any money-path function.

## Conventions
Function bodies use `$fn$` / `$do$` dollar quotes rather than `$$` so a toolchain that
mangles `$$` cannot silently corrupt them.
*/

SET search_path = public, pg_temp;

-- ===========================================================================
-- 1. REALTIME PUBLICATION MEMBERSHIP
-- ===========================================================================
-- Membership only. Supabase Realtime evaluates the table's RLS for each subscriber,
-- so this is exactly as safe as the RLS that is already in place — and the block
-- below refuses to run if that RLS is missing anywhere in the publication.
DO $do$
DECLARE
  v_tables text[] := ARRAY[
    'orders', 'trades', 'balances', 'deposits', 'withdrawal_requests',
    'notifications', 'chat_conversations', 'chat_messages'
  ];
  t text;
  r record;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    RAISE EXCEPTION
      'refusing: the supabase_realtime publication does not exist on this database (a Supabase database always has it)'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  FOREACH t IN ARRAY v_tables LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = t AND c.relkind = 'r'
    ) THEN
      RAISE EXCEPTION
        'refusing: public.% does not exist as a table — a publication member must be a real table', t
        USING ERRCODE = 'undefined_table';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = t AND c.relrowsecurity
    ) THEN
      RAISE EXCEPTION
        'refusing: public.% has RLS disabled. A realtime publication member without RLS would broadcast every row change to every subscriber', t
        USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
      RAISE NOTICE '[realtime] added public.% to supabase_realtime', t;
    ELSE
      RAISE NOTICE '[realtime] public.% is already a member of supabase_realtime', t;
    END IF;
  END LOOP;

  -- the same assertion for EVERY member of the publication, not just the eight above
  FOR r IN
    SELECT pt.schemaname, pt.tablename
      FROM pg_publication_tables pt
      JOIN pg_namespace n ON n.nspname = pt.schemaname
      JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = pt.tablename
     WHERE pt.pubname = 'supabase_realtime'
       AND NOT c.relrowsecurity
  LOOP
    RAISE EXCEPTION
      'refusing: publication member %.% has RLS disabled', r.schemaname, r.tablename
      USING ERRCODE = 'insufficient_privilege';
  END LOOP;

  IF current_setting('wal_level') <> 'logical' THEN
    RAISE NOTICE '[realtime] wal_level=% on this instance: publication membership is recorded, but real-time DELIVERY cannot be verified here (Supabase runs wal_level=logical). Delivery is a deployment-time check.', current_setting('wal_level');
  END IF;
END $do$;

-- per-table channel semantics, APPENDED to each table's existing comment (the comment
-- is read back with obj_description and extended, never replaced)
DO $do$
DECLARE
  r record;
  v_note text;
  v_existing text;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      ('orders',
       'Realtime channel "orders": a subscriber receives INSERT/UPDATE events for THEIR OWN orders only (RLS user_id = auth.uid()). Order status transitions (new -> partially_filled -> filled/canceled/rejected/expired) arrive as UPDATE payloads; the payload is the row, so the client must not treat an UPDATE as a fill on its own.'),
      ('trades',
       'Realtime channel "trades": one INSERT per fill, visible only to the two parties of that fill (taker_user_id / maker_user_id via RLS). This is the recent-trades feed; the aggregate depth/book views stay pull-based (v_order_book_best/v_order_book_depth are not published).'),
      ('balances',
       'Realtime channel "balances": UPDATE events when available_units/locked_units change on an account the subscriber may read (own accounts only). Balances are a projection of the append-only ledger; a client must reconcile, never compute money from events alone.'),
      ('deposits',
       'Realtime channel "deposits": status changes (pending -> confirming -> confirmed/failed/under review) for the subscriber''s own deposits. A status change also writes a notifications row of type deposit.status (see section 2).'),
      ('withdrawal_requests',
       'Realtime channel "withdrawal_requests": status changes (pending -> under review -> approved -> processing -> completed/failed/rejected) for the subscriber''s own withdrawal requests. A status change also writes a notifications row of type withdrawal.status. (There is no public.withdrawals table; this is the withdrawals table.)'),
      ('notifications',
       'Realtime channel "notifications": INSERT for the subscriber''s own rows plus broadcasts (user_id IS NULL). Read state is per row (read_at); per-user read state for a broadcast is still a documented gap, so a broadcast INSERT is delivered to every signed-in subscriber.'),
      ('chat_conversations',
       'Realtime channel "chat_conversations": support conversation created/updated. The visitor widget subscribes by visitor_id. The user-side chat RLS is UNCHANGED from the original chat migration (world-readable to anon/authenticated) — a PARKED OWNER DECISION, restated here because this table is now a realtime channel.'),
      ('chat_messages',
       'Realtime channel "chat_messages": new support message in a conversation (sender visitor|agent). Same caveat as chat_conversations: the user-side chat RLS is unchanged and remains a parked owner decision.')
    ) AS v(tbl, note)
  LOOP
    SELECT obj_description(('public.' || quote_ident(r.tbl))::regclass, 'pg_class') INTO v_existing;
    v_note := r.note || ' Delivery is unverified until deployment: a scratch PostgreSQL has no Realtime daemon.';
    IF v_existing IS NULL OR position('Realtime channel' in v_existing) = 0 THEN
      EXECUTE format('COMMENT ON TABLE public.%I IS %L', r.tbl,
                     CASE WHEN v_existing IS NULL THEN v_note ELSE v_existing || ' ' || v_note END);
    END IF;
  END LOOP;
END $do$;

-- ===========================================================================
-- 2. DEPOSIT / WITHDRAWAL STATUS NOTIFICATIONS (additive; no money-path change)
-- ===========================================================================

-- base units -> a human string, using the asset's own base_decimals. Pure formatting:
-- it never rounds money, it only renders the integer amount the row already holds.
CREATE OR REPLACE FUNCTION public.units_to_display(p_units numeric, p_decimals smallint)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE
           WHEN coalesce(p_decimals, 0) <= 0 THEN coalesce(p_units, 0)::text
           ELSE trim(trailing '.' from trim(trailing '0' from
                  to_char(coalesce(p_units, 0) / power(10::numeric, p_decimals),
                          'FM999999999999999999999999999990.' || repeat('0', p_decimals))))
         END
$fn$;

COMMENT ON FUNCTION public.units_to_display(numeric, smallint) IS
  'Renders integer base units as a display string using an asset''s base_decimals (150000000, 8 -> 1.5). Formatting only: no rounding of money, no float.';

CREATE OR REPLACE FUNCTION public.notify_deposit_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_symbol text;
  v_dec    smallint;
  v_amount text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  BEGIN
    SELECT a.symbol, a.base_decimals INTO v_symbol, v_dec
      FROM public.assets a WHERE a.id = NEW.asset_id;

    v_amount := public.units_to_display(NEW.amount_units, v_dec);

    INSERT INTO public.notifications (user_id, type, title, body)
    VALUES (
      NEW.user_id,
      'deposit.status',
      left(format('Deposit %s', NEW.status), 200),
      left(format('Your deposit of %s %s on %s is now %s (txid %s).',
                  v_amount, coalesce(v_symbol, '?'), NEW.network, NEW.status, NEW.txid), 4000)
    );
  EXCEPTION WHEN OTHERS THEN
    -- A notification must never block or roll back the status change that caused it.
    -- The failure is surfaced as a warning, never silently swallowed.
    RAISE WARNING 'deposit % status notification was not written: % (%)',
      NEW.id, sqlerrm, sqlstate;
  END;

  RETURN NEW;
END $fn$;

COMMENT ON FUNCTION public.notify_deposit_status_change() IS
  'AFTER UPDATE trigger on public.deposits: writes ONE notifications row (type deposit.status) per real status transition, from facts already on the row. Never writes money, never retries, never invents an event; a failure warns instead of blocking the status change.';

CREATE OR REPLACE FUNCTION public.notify_withdrawal_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_symbol text;
  v_dec    smallint;
  v_amount text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  BEGIN
    SELECT a.symbol, a.base_decimals INTO v_symbol, v_dec
      FROM public.assets a WHERE a.id = NEW.asset_id;

    v_amount := public.units_to_display(NEW.amount_units, v_dec);

    INSERT INTO public.notifications (user_id, type, title, body)
    VALUES (
      NEW.user_id,
      'withdrawal.status',
      left(format('Withdrawal %s', NEW.status), 200),
      left(format('Your withdrawal of %s %s on %s is now %s.',
                  v_amount, coalesce(v_symbol, '?'), NEW.network, NEW.status), 4000)
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'withdrawal % status notification was not written: % (%)',
      NEW.id, sqlerrm, sqlstate;
  END;

  RETURN NEW;
END $fn$;

COMMENT ON FUNCTION public.notify_withdrawal_status_change() IS
  'AFTER UPDATE trigger on public.withdrawal_requests: writes ONE notifications row (type withdrawal.status) per real status transition, from facts already on the row. Never writes money, never retries, never invents an event; a failure warns instead of blocking the status change.';

DROP TRIGGER IF EXISTS deposits_notify_status ON public.deposits;
CREATE TRIGGER deposits_notify_status
  AFTER UPDATE OF status ON public.deposits
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.notify_deposit_status_change();

DROP TRIGGER IF EXISTS withdrawal_requests_notify_status ON public.withdrawal_requests;
CREATE TRIGGER withdrawal_requests_notify_status
  AFTER UPDATE OF status ON public.withdrawal_requests
  FOR EACH ROW
  WHEN (OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.notify_withdrawal_status_change();

-- ===========================================================================
-- 3. OPERATIONAL HEALTH CHECKS
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.system_health (
  component       text PRIMARY KEY,
  status          text NOT NULL,
  last_checked_at timestamptz NOT NULL DEFAULT now(),
  detail          jsonb NOT NULL DEFAULT '{}'::jsonb,
  checked_by      text,
  CONSTRAINT system_health_component_check CHECK (length(btrim(component)) BETWEEN 3 AND 60),
  -- the only five states this exchange is allowed to claim
  CONSTRAINT system_health_status_check CHECK (
    status IN ('ok', 'degraded', 'down', 'not_configured', 'not_connected')
  ),
  CONSTRAINT system_health_detail_check CHECK (jsonb_typeof(detail) = 'object'),
  CONSTRAINT system_health_checked_by_check CHECK (
    checked_by IS NULL OR length(btrim(checked_by)) BETWEEN 1 AND 120
  )
);

COMMENT ON TABLE public.system_health IS
  'One row per health-checked component. status is one of ok|degraded|down|not_configured|not_connected; not_configured and not_connected are honest states, not failures and not successes. detail is the raw evidence (counts, reasons, provider error text) and is stored verbatim: nothing here is ever "corrected" to look healthy. Read through v_system_health (no detail) or v_admin_system_health (operators, full detail). Writes only through record_health() (service_role) and admin_health_recheck() (operator).';
COMMENT ON COLUMN public.system_health.status IS
  'ok = checked and healthy; degraded = checked and wrong but serving; down = checked and failing; not_configured = no provider/credential chosen yet; not_connected = configured in design but no live connectivity exists in this build.';
COMMENT ON COLUMN public.system_health.detail IS
  'Raw evidence JSON, stored verbatim. Internal: not exposed by v_system_health.';
COMMENT ON COLUMN public.system_health.checked_by IS
  'Who/what last wrote the row: migration_seed, service_role (record_health), admin_health_recheck, or a provider adapter name.';

-- the real database self-check: counts, never a constant
CREATE OR REPLACE FUNCTION public.run_db_self_check()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_tx          bigint;
  v_unbalanced  bigint;
  v_balances    bigint;
  v_mismatched  bigint;
BEGIN
  SELECT count(*) INTO v_tx FROM public.ledger_transactions;

  SELECT count(*) INTO v_unbalanced FROM (
    SELECT t.id
      FROM public.ledger_transactions t
      JOIN public.ledger_entries e ON e.transaction_id = t.id
     GROUP BY t.id
    HAVING sum(e.amount_units) <> 0
  ) x;

  SELECT count(*) INTO v_balances FROM public.balances;

  SELECT count(*) INTO v_mismatched
    FROM public.balances b
   WHERE COALESCE(b.available_units, 0) + COALESCE(b.locked_units, 0)
         <> COALESCE((SELECT sum(e.amount_units) FROM public.ledger_entries e
                       WHERE e.account_id = b.account_id), 0);

  RETURN jsonb_build_object(
    'check',                   'db_self_check',
    'checked_at',              now(),
    'ledger_transactions',     v_tx,
    'unbalanced_transactions', v_unbalanced,
    'balances',                v_balances,
    'balances_mismatched',     v_mismatched
  );
END $fn$;

COMMENT ON FUNCTION public.run_db_self_check() IS
  'The database component''s health check: counts ledger transactions that do not sum to zero and balances that do not equal their ledger sum. Returns the counts as JSON evidence. It never repairs anything — stage 4 (reconciliation) surfaces discrepancies, this only reports them.';

-- internal: status implied by a self-check result (ok / degraded). Not a public knob.
CREATE OR REPLACE FUNCTION public.health_status_from_self_check(p_detail jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT CASE
           WHEN coalesce((p_detail->>'unbalanced_transactions')::bigint, 1) = 0
            AND coalesce((p_detail->>'balances_mismatched')::bigint, 1) = 0
           THEN 'ok'
           ELSE 'degraded'
         END
$fn$;

-- the provider/edge-function write path: service_role only
CREATE OR REPLACE FUNCTION public.record_health(
  p_component  text,
  p_status     text,
  p_detail     jsonb DEFAULT '{}'::jsonb,
  p_checked_by text  DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_component text := btrim(coalesce(p_component, ''));
  v_status    text := lower(btrim(coalesce(p_status, '')));
  v_by        text;
BEGIN
  IF v_status NOT IN ('ok', 'degraded', 'down', 'not_configured', 'not_connected') THEN
    RAISE EXCEPTION
      'unknown health status % (ok|degraded|down|not_configured|not_connected)', p_status
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  IF p_detail IS NOT NULL AND jsonb_typeof(p_detail) <> 'object' THEN
    RAISE EXCEPTION 'health detail must be a JSON object (got %)', jsonb_typeof(p_detail)
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- who checked: an explicit caller label wins, then the role the caller SET (the way
  -- PostgREST/edge functions call as service_role), then the login role. current_user
  -- would name this SECURITY DEFINER function's owner, which is never the caller.
  v_by := coalesce(nullif(btrim(coalesce(p_checked_by, '')), ''),
                   nullif(current_setting('role', true), 'none'),
                   session_user);

  UPDATE public.system_health
     SET status          = v_status,
         last_checked_at = now(),
         -- VERBATIM: no merge, no sanitising, no "correcting" a bad report
         detail          = coalesce(p_detail, '{}'::jsonb),
         checked_by      = v_by
   WHERE component = v_component;

  IF NOT FOUND THEN
    RAISE EXCEPTION
      'unknown health component %: record_health() only updates components that already exist (adding a component is an ops/owner decision, not a provider''s)', p_component
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  RETURN v_status;
END $fn$;

COMMENT ON FUNCTION public.record_health(text, text, jsonb, text) IS
  'The only health WRITE path (service_role; future edge functions and provider adapters call it). Enum-checked, refuses unknown components, stores the detail JSON verbatim and stamps last_checked_at/checked_by. It cannot create a component, cannot touch another component, and cannot report a status outside the five honest states.';

-- the operator re-check: DB self-check ONLY. No overrides.
CREATE OR REPLACE FUNCTION public.admin_health_recheck(p_operator_id uuid DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op     uuid;
  v_detail jsonb;
  v_status text;
BEGIN
  v_op := public.assert_operator('security.read', p_operator_id);

  v_detail := public.run_db_self_check();
  v_status := public.health_status_from_self_check(v_detail);

  UPDATE public.system_health
     SET status          = v_status,
         last_checked_at = now(),
         detail          = v_detail,
         checked_by      = 'admin_health_recheck'
   WHERE component = 'database';

  PERFORM public.log_operator_action(
    'admin.health.recheck', 'system_health', NULL, NULL,
    jsonb_build_object('component', 'database', 'status', v_status, 'detail', v_detail),
    v_op);

  RETURN v_status;
END $fn$;

COMMENT ON FUNCTION public.admin_health_recheck(uuid) IS
  'Operator re-check (security.read, audited admin.health.recheck). Runs ONLY the database self-check and rewrites ONLY the database row: it cannot mark a provider healthy, cannot clear a down component and cannot touch market_data, blockchain:*, custodian or realtime. Health reflects reality or it stays wrong.';

-- ---------------------------------------------------------------------------
-- read surface
-- ---------------------------------------------------------------------------
-- public status data only: component + status + when. No detail JSON, no checked_by.
CREATE OR REPLACE VIEW public.v_system_health AS
  SELECT component, status, last_checked_at
    FROM public.system_health;

COMMENT ON VIEW public.v_system_health IS
  'The customer-facing component status (authenticated). Component, status and last_checked_at only: the detail JSON is internal evidence and is not exposed here.';

-- operator view: the permission matrix decides, and the full evidence is visible
CREATE OR REPLACE VIEW public.v_admin_system_health AS
  SELECT h.component,
         h.status,
         h.last_checked_at,
         h.checked_by,
         h.detail,
         (h.status IN ('down', 'degraded')) AS needs_attention
    FROM public.system_health h
   WHERE public.operator_can_do('security.read');

COMMENT ON VIEW public.v_admin_system_health IS
  'Operator health view (security.read via operator_can_do). Full detail JSON, who last checked, and needs_attention = true for down/degraded rows: that flag IS the failure alert surface (nothing pages, retries or fabricates a recovery).';

-- ---------------------------------------------------------------------------
-- seed ONCE with the truth of this build
-- ---------------------------------------------------------------------------
DO $do$
DECLARE
  v_detail jsonb;
  v_status text;
  v_inserted int;
BEGIN
  v_detail := public.run_db_self_check();
  v_status := public.health_status_from_self_check(v_detail);

  INSERT INTO public.system_health (component, status, last_checked_at, detail, checked_by)
  VALUES ('database', v_status, now(), v_detail, 'migration_seed')
  ON CONFLICT (component) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  INSERT INTO public.system_health (component, status, last_checked_at, detail, checked_by) VALUES
    ('market_data', 'not_configured', now(),
     '{"reason":"no market-data provider chosen (owner decision #3); the exchange has no reference prices and never quotes one it does not have","reference_prices":"none"}'::jsonb,
     'migration_seed'),
    ('blockchain:BTC', 'not_connected', now(),
     '{"network":"BTC","reason":"no live chain connectivity in this build; the adapter contract is an interface only (stage 7)"}'::jsonb,
     'migration_seed'),
    ('blockchain:ETH', 'not_connected', now(),
     '{"network":"ETH","reason":"no live chain connectivity in this build; the adapter contract is an interface only (stage 7)"}'::jsonb,
     'migration_seed'),
    ('blockchain:USDT', 'not_connected', now(),
     '{"network":"USDT","reason":"no live chain connectivity in this build; the adapter contract is an interface only (stage 7)"}'::jsonb,
     'migration_seed'),
    ('blockchain:SOL', 'not_connected', now(),
     '{"network":"SOL","reason":"no live chain connectivity in this build; the adapter contract is an interface only (stage 7)"}'::jsonb,
     'migration_seed'),
    ('custodian', 'not_connected', now(),
     '{"reason":"no custody provider chosen (owner decision #2); custody/liquidity views report connectivity not_connected"}'::jsonb,
     'migration_seed'),
    ('realtime', 'not_configured', now(),
     '{"reason":"publication membership is recorded, but live websocket delivery is unverified: it can only be verified against the deployed project (wal_level=logical + Realtime daemon)"}'::jsonb,
     'migration_seed')
  ON CONFLICT (component) DO NOTHING;

  RAISE NOTICE '[health] database self-check at seed time: % (inserted fresh: %)', v_detail, (v_inserted = 1);
  RAISE NOTICE '[health] seeded components: database=%, market_data=not_configured, blockchain:{BTC,ETH,USDT,SOL}=not_connected, custodian=not_connected, realtime=not_configured', v_status;
END $do$;

-- ===========================================================================
-- 4. RLS + PRIVILEGES
-- ===========================================================================
-- system_health: RLS on with NO policy, like admin_users. The two views are the only
-- read paths, so a client that selects the table directly gets zero rows (not an
-- error), and the detail JSON is unreachable without operator rights.
ALTER TABLE public.system_health ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.system_health FROM PUBLIC;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON public.system_health FROM anon;
    REVOKE ALL ON public.v_system_health, public.v_admin_system_health FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON public.system_health FROM authenticated;
    GRANT SELECT ON public.v_system_health TO authenticated;
    GRANT SELECT ON public.v_admin_system_health TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    GRANT SELECT, INSERT, UPDATE ON public.system_health TO service_role;
    GRANT SELECT ON public.v_system_health, public.v_admin_system_health TO service_role;
  END IF;
END $do$;

-- function ACLs: every function here is server-side except nothing — the health read
-- surface is the two views, and the health write paths are service_role/operator RPCs.
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
         'record_health', 'run_db_self_check', 'health_status_from_self_check',
         'admin_health_recheck', 'units_to_display',
         'notify_deposit_status_change', 'notify_withdrawal_status_change'
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

-- the identity helpers the operator health view depends on must stay executable by
-- authenticated (PostgreSQL checks EXECUTE on functions referenced by a view against
-- the INVOKING role). Re-asserted so this migration cannot break the PR #7/#8 views.
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
  RAISE NOTICE '[realtime/health] app_settings unchanged by this migration: mode=%, paper_trading=%, live_trading=%, deposits=%, withdrawals=%, maintenance_mode=%',
    v_mode, v_pt, v_lt, v_dep, v_wd, v_mm;
  RAISE NOTICE '[realtime/health] security_audit_log is NOT in the publication (operator-only, would leak): admin alerts stay pull-based on v_admin_alerts';
  RAISE NOTICE '[realtime/health] realtime delivery is unverified in this environment; system_health.realtime stays not_configured until a deployed project proves delivery';
END $do$;

RESET search_path;
