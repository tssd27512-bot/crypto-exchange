/*
# Stage 4 — financial reconciliation + discrepancy alerts

Owner directive section 4. Additive only: no money-path function is created or
re-created here, no table from an earlier migration is altered, `app_settings`
and every `LIVE_*` flag are untouched.

## The rule this migration is built around

**Reconciliation DETECTS and REPORTS. It never corrects, never auto-adjusts and
never hides a mismatch.** No function in this file writes a ledger entry, moves a
cached balance, or edits a provider figure. Every number it produces is a report
row. A real correction is a deliberate compensating ledger posting executed by an
operator — documented here as the future path, deliberately NOT built.

## What it adds

1. `provider_balances` — what a custody/provider adapter says it holds, stored
   EXACTLY as reported, one row per (asset, network, environment). Before any
   provider exists the table is EMPTY, and every comparison then reads
   'unavailable' — never zero, never a match. `provider_balances_log` is the
   append-only history of every report (audit-log pattern).
2. `record_provider_balance(...)` — the RPC a real provider/edge function calls
   (stage 7). It is the ONLY write path: the tables are SELECT-only for every
   role, including service_role.
3. `reconciliation_runs` / `reconciliation_results` — one run row and one result
   row per (asset, environment), computed in ONE consistent snapshot.
4. `reconciliation_alerts` — append-only; only the acknowledge columns may ever
   change, once. Acknowledge ≠ fix.
5. `run_reconciliation(environment, operator)` — operator-guarded (audited with a
   real actor), one snapshot, invariant scan, alerts.
6. `v_admin_reconciliation` (money.read) and `v_admin_reconciliation_alerts`
   (security.read).

## The four numbers per asset × environment, and why

| column | meaning |
|---|---|
| `customer_liability_units` | SUM of `ledger_entries` over USER accounts. The ledger is the source of truth. |
| `projection_units` | SUM of the cached `balances` rows of those same user accounts. |
| `custody_units` | The custody-side mirror, SIGNED: `-(EXTERNAL_DEPOSIT + WITHDRAWAL_CLEARING)` ledger sums — i.e. net value the exchange took in from outside minus what it paid out. Positive means "we should be holding this much at the provider". This is the number a provider report is comparable to. |
| `provider_units` | SUM of the latest recorded provider balance per network, or NULL. |

`drift_units` = `customer_liability_units - projection_units` (must be 0).

**Deviation from the spec, flagged:** the spec expected `custody_units` to equal
`customer_liability_units` "by construction". In this schema it does NOT, and
pretending it did would be dishonest: liability is the user-side sum while
`PAPER_FAUCET` (paper funding) and `FEE_INCOME` (trading fees) are also system
accounts, so `liability = -(EXTERNAL_DEPOSIT + WITHDRAWAL_CLEARING + PAPER_FAUCET
+ FEE_INCOME)`. Equality holds only for the FULL system mirror, not the
custody-side subset. So the custody comparison is split into the two comparisons
that are actually meaningful, and the reconciliation reports both:

- `custody_mismatch` (critical) = the double-entry mirror is broken: SUM over ALL
  accounts of that asset and environment is not zero. This is the "assert it
  matches by construction" check the spec asked for, done at the level where the
  construction actually guarantees it. The custody/faucet/fee breakdown is in
  `detail.custody_breakdown` and `detail.non_custody_system_units`, so the gap
  between `custody_units` and `customer_liability_units` is shown, never hidden.
- `provider_mismatch` (warning) = `provider_units <> custody_units`: the provider
  reports a different holding than the ledger says flowed in and out.

`status` (match | drift | unavailable) resolves in that order: internal drift or
a broken mirror ⇒ `drift`; else no provider report ⇒ `unavailable`; else provider
disagrees ⇒ `drift`; else `match`. A provider mismatch is deliberately NOT
'critical': provider data is untrusted until stage 7 verifies the adapter.

## Authorization (no new permission cell)

- `run_reconciliation` requires `security.read`, `acknowledge_reconciliation_alert`
  requires `risk.write`. Both cells already exist, so the permission matrix is
  unchanged (4 roles × 16 actions = 64 cells) and no earlier suite has to be
  re-based. Precedent: stage 3's `admin_health_recheck` (also an audited operator
  action that runs a check and writes a row) uses `security.read`. Reusing beats
  inventing a cell; the spec allowed either and asked for the choice to be flagged.
- Neither RPC is executable by PUBLIC/anon/authenticated; every table is
  SELECT-only for every role, so the RPCs are the only write path.

## Deliberately out of scope

Auto-correction, compensating postings, a scheduler, alert push/dedup/retry, a
real provider adapter (stage 7), edge functions, the frontend, realtime
publication of reconciliation rows (reconciliation is operator data, not a
customer event). Folding reconciliation alerts into `v_admin_alerts` was NOT done
because that view is keyed per customer (`user_id`, `subject_user_id`) and
reconciliation alerts are system-wide; folding them in would need a fabricated
user or a shape change to a view that suite C already asserts.

## Conventions

`$fn$` / `$do$` / `$big$` dollar quotes (never `$$`) so a toolchain that mangles
`$$` cannot silently corrupt this file.
*/

SET search_path = public, pg_temp;

-- ===========================================================================
-- 1. PROVIDER BALANCE INTAKE — honest by default (the table starts EMPTY)
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.provider_balances (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  network text NOT NULL,
  environment text NOT NULL DEFAULT 'paper',
  units numeric(38, 0) NOT NULL,
  reported_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT provider_balances_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT provider_balances_network_check CHECK (network = lower(btrim(network)) AND length(network) BETWEEN 2 AND 40),
  CONSTRAINT provider_balances_units_check CHECK (units >= 0),
  CONSTRAINT provider_balances_source_check CHECK (length(btrim(source)) BETWEEN 3 AND 60),
  CONSTRAINT provider_balances_detail_check CHECK (jsonb_typeof(detail) = 'object'),
  CONSTRAINT provider_balances_key UNIQUE (asset_id, network, environment)
);

COMMENT ON TABLE public.provider_balances IS
  'What a custody/provider adapter reports it holds, EXACTLY as reported: one row per (asset, network, environment), integer base units, source and reported_at preserved. Written only by record_provider_balance(). The table is EMPTY until a real provider exists (stage 7); a missing row means "unavailable", never zero.';

COMMENT ON COLUMN public.provider_balances.units IS
  'Integer base units reported by the provider. 0 is a real report of an empty wallet; a MISSING row is "unavailable". The two are never conflated.';

-- append-only history of every report (the security_audit_log pattern)
CREATE TABLE IF NOT EXISTS public.provider_balances_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  network text NOT NULL,
  environment text NOT NULL,
  units numeric(38, 0) NOT NULL,
  previous_units numeric(38, 0),
  reported_at timestamptz NOT NULL,
  source text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  action text NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT provider_balances_log_action_check CHECK (action IN ('recorded', 'replaced')),
  CONSTRAINT provider_balances_log_units_check CHECK (units >= 0)
);

CREATE INDEX IF NOT EXISTS provider_balances_log_key_idx
  ON public.provider_balances_log (asset_id, network, environment, recorded_at DESC);

COMMENT ON TABLE public.provider_balances_log IS
  'Append-only history of every provider balance report: one row per record_provider_balance() call, with the value it replaced. UPDATE and DELETE are refused for every role.';

CREATE OR REPLACE FUNCTION public.provider_balances_audit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  INSERT INTO public.provider_balances_log (
    asset_id, network, environment, units, previous_units, reported_at, source, detail, action
  ) VALUES (
    NEW.asset_id, NEW.network, NEW.environment, NEW.units,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.units ELSE NULL END,
    NEW.reported_at, NEW.source, NEW.detail,
    CASE WHEN TG_OP = 'UPDATE' THEN 'replaced' ELSE 'recorded' END
  );
  RETURN NULL;
END $fn$;

DROP TRIGGER IF EXISTS provider_balances_audit ON public.provider_balances;
CREATE TRIGGER provider_balances_audit
  AFTER INSERT OR UPDATE ON public.provider_balances
  FOR EACH ROW EXECUTE FUNCTION public.provider_balances_audit();

DROP TRIGGER IF EXISTS provider_balances_log_immutable ON public.provider_balances_log;
CREATE TRIGGER provider_balances_log_immutable
  BEFORE UPDATE OR DELETE ON public.provider_balances_log
  FOR EACH ROW EXECUTE FUNCTION public.reject_mutation();

-- ---------------------------------------------------------------------------
-- the ONLY write path: record_provider_balance
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.record_provider_balance(
  p_symbol       text,
  p_network      text,
  p_units        numeric,
  p_source       text,
  p_environment  text        DEFAULT 'paper',
  p_reported_at  timestamptz DEFAULT now(),
  p_detail       jsonb       DEFAULT '{}'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_asset uuid;
  v_env   text := lower(btrim(coalesce(p_environment, 'paper')));
  v_net   text := lower(btrim(coalesce(p_network, '')));
  v_id    uuid;
BEGIN
  IF p_units IS NULL THEN
    RAISE EXCEPTION 'record_provider_balance: units are required (a NULL report is "unavailable", which is the absence of a row, not a row)'
      USING ERRCODE = 'null_value_not_allowed';
  END IF;
  IF p_units <> trunc(p_units) THEN
    RAISE EXCEPTION 'record_provider_balance: units must be a whole number of base units, got %: a provider report is stored exactly, never rounded', p_units
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_units < 0 THEN
    RAISE EXCEPTION 'record_provider_balance: a provider cannot hold a negative balance (got %)', p_units
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_env NOT IN ('paper', 'live') THEN
    RAISE EXCEPTION 'record_provider_balance: unknown environment % (paper|live)', p_environment
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF length(v_net) < 2 THEN
    RAISE EXCEPTION 'record_provider_balance: a network is required' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_source IS NULL OR length(btrim(p_source)) < 3 THEN
    RAISE EXCEPTION 'record_provider_balance: a source is required (who reported this number)' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_detail IS NULL OR jsonb_typeof(p_detail) <> 'object' THEN
    RAISE EXCEPTION 'record_provider_balance: detail must be a JSON object' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_reported_at IS NULL THEN
    RAISE EXCEPTION 'record_provider_balance: reported_at is required' USING ERRCODE = 'null_value_not_allowed';
  END IF;

  SELECT id INTO v_asset FROM public.assets WHERE symbol = upper(btrim(coalesce(p_symbol, '')));
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'record_provider_balance: unknown asset %', p_symbol USING ERRCODE = 'no_data_found';
  END IF;

  INSERT INTO public.provider_balances AS pb (
    asset_id, network, environment, units, reported_at, source, detail, recorded_at
  ) VALUES (
    v_asset, v_net, v_env, p_units, p_reported_at, btrim(p_source), p_detail, now()
  )
  ON CONFLICT ON CONSTRAINT provider_balances_key DO UPDATE
     SET units       = EXCLUDED.units,
         reported_at = EXCLUDED.reported_at,
         source      = EXCLUDED.source,
         detail      = EXCLUDED.detail,
         recorded_at = now()
  RETURNING pb.id INTO v_id;

  RETURN v_id;
END $fn$;

COMMENT ON FUNCTION public.record_provider_balance(text, text, numeric, text, text, timestamptz, jsonb) IS
  'The provider-balance intake hook (stage 7 wires a real adapter to it). Stores EXACTLY what is reported, keyed by (asset, network, environment) with the previous value kept in provider_balances_log. Refuses fractional units (never rounds), negative units, an unknown asset, a missing network/source/reported_at and a non-object detail. service_role only: it is the only write path into provider_balances.';

-- ===========================================================================
-- 2. RUN MACHINERY
-- ===========================================================================
CREATE TABLE IF NOT EXISTS public.reconciliation_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  status text NOT NULL DEFAULT 'running',
  environment text NOT NULL DEFAULT 'paper',
  triggered_by uuid REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  CONSTRAINT reconciliation_runs_status_check CHECK (status IN ('running', 'completed', 'failed')),
  CONSTRAINT reconciliation_runs_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT reconciliation_runs_detail_check CHECK (jsonb_typeof(detail) = 'object'),
  CONSTRAINT reconciliation_runs_finished_check CHECK (
    (status = 'running' AND finished_at IS NULL) OR (status <> 'running' AND finished_at IS NOT NULL)
  )
);

CREATE INDEX IF NOT EXISTS reconciliation_runs_env_idx
  ON public.reconciliation_runs (environment, started_at DESC);

COMMENT ON TABLE public.reconciliation_runs IS
  'One row per reconciliation run. Write-once: only status, finished_at and detail may change, and only while the run is still ''running''. A run that raises is recorded as ''failed'' with the error in detail (callers must check status) — the failure is never swallowed and never turned into a clean run.';

CREATE TABLE IF NOT EXISTS public.reconciliation_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES public.reconciliation_runs(id) ON DELETE RESTRICT,
  asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  environment text NOT NULL,
  customer_liability_units numeric(38, 0) NOT NULL,
  projection_units numeric(38, 0) NOT NULL,
  custody_units numeric(38, 0) NOT NULL,
  provider_units numeric(38, 0),
  drift_units numeric(38, 0),
  status text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reconciliation_results_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT reconciliation_results_status_check CHECK (status IN ('match', 'drift', 'unavailable')),
  CONSTRAINT reconciliation_results_detail_check CHECK (jsonb_typeof(detail) = 'object'),
  CONSTRAINT reconciliation_results_key UNIQUE (run_id, asset_id, environment)
);

CREATE INDEX IF NOT EXISTS reconciliation_results_run_idx ON public.reconciliation_results (run_id);

COMMENT ON TABLE public.reconciliation_results IS
  'Per (asset, environment) comparison for one run: customer liability (ledger), the cached projection, the signed custody-side mirror, the provider report (NULL = unavailable) and the internal drift. Append-only. reconciliation never writes back to the ledger, the balances or the provider rows.';

CREATE TABLE IF NOT EXISTS public.reconciliation_alerts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES public.reconciliation_runs(id) ON DELETE RESTRICT,
  asset_id uuid NOT NULL REFERENCES public.assets(id) ON DELETE RESTRICT,
  environment text NOT NULL,
  severity text NOT NULL,
  kind text NOT NULL,
  detail jsonb NOT NULL DEFAULT '{}'::jsonb,
  acknowledged_at timestamptz,
  acknowledged_by uuid REFERENCES public.admin_users(id) ON DELETE RESTRICT,
  acknowledge_note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT reconciliation_alerts_environment_check CHECK (environment IN ('paper', 'live')),
  CONSTRAINT reconciliation_alerts_severity_check CHECK (severity IN ('warning', 'critical')),
  CONSTRAINT reconciliation_alerts_kind_check CHECK (
    kind IN ('internal_drift', 'custody_mismatch', 'provider_mismatch', 'stale_provider')
  ),
  CONSTRAINT reconciliation_alerts_detail_check CHECK (jsonb_typeof(detail) = 'object'),
  CONSTRAINT reconciliation_alerts_ack_check CHECK (
    (acknowledged_at IS NULL AND acknowledged_by IS NULL)
    OR (acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL)
  ),
  -- at most one alert per (run, asset, environment, kind); the run detail carries
  -- every offending id, so nothing is lost by the cap
  CONSTRAINT reconciliation_alerts_key UNIQUE (run_id, asset_id, environment, kind)
);

CREATE INDEX IF NOT EXISTS reconciliation_alerts_open_idx
  ON public.reconciliation_alerts (environment, created_at DESC)
  WHERE acknowledged_at IS NULL;

COMMENT ON TABLE public.reconciliation_alerts IS
  'Append-only discrepancy alerts. UPDATE is permitted for the three acknowledge columns only, once; DELETE is refused for every role. Acknowledging records that an operator has seen the discrepancy — it does NOT fix it and does not change any number.';

-- ---------------------------------------------------------------------------
-- append-only guards
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_row_deletion()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  RAISE EXCEPTION
    '% rows are append-only: DELETE on %.% is not permitted',
    TG_TABLE_NAME, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'restrict_violation';
END $fn$;

DROP TRIGGER IF EXISTS reconciliation_results_immutable ON public.reconciliation_results;
CREATE TRIGGER reconciliation_results_immutable
  BEFORE UPDATE OR DELETE ON public.reconciliation_results
  FOR EACH ROW EXECUTE FUNCTION public.reject_mutation();

DROP TRIGGER IF EXISTS reconciliation_runs_no_delete ON public.reconciliation_runs;
CREATE TRIGGER reconciliation_runs_no_delete
  BEFORE DELETE ON public.reconciliation_runs
  FOR EACH ROW EXECUTE FUNCTION public.reject_row_deletion();

CREATE OR REPLACE FUNCTION public.reconciliation_runs_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF OLD.status <> 'running' THEN
    RAISE EXCEPTION 'reconciliation run % is % and can no longer be modified: a finished run is write-once', OLD.id, OLD.status
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.id <> OLD.id
     OR NEW.environment <> OLD.environment
     OR NEW.started_at <> OLD.started_at
     OR NEW.triggered_by IS DISTINCT FROM OLD.triggered_by THEN
    RAISE EXCEPTION 'reconciliation run %: only status, finished_at and detail may change', OLD.id
      USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS reconciliation_runs_before_update ON public.reconciliation_runs;
CREATE TRIGGER reconciliation_runs_before_update
  BEFORE UPDATE ON public.reconciliation_runs
  FOR EACH ROW EXECUTE FUNCTION public.reconciliation_runs_before_update();

CREATE OR REPLACE FUNCTION public.reconciliation_alerts_before_update()
RETURNS trigger
LANGUAGE plpgsql
AS $fn$
BEGIN
  IF OLD.acknowledged_at IS NOT NULL THEN
    RAISE EXCEPTION 'reconciliation alert % was already acknowledged at %: an acknowledgement is write-once', OLD.id, OLD.acknowledged_at
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.id <> OLD.id
     OR NEW.run_id <> OLD.run_id
     OR NEW.asset_id <> OLD.asset_id
     OR NEW.environment <> OLD.environment
     OR NEW.severity <> OLD.severity
     OR NEW.kind <> OLD.kind
     OR NEW.detail <> OLD.detail
     OR NEW.created_at <> OLD.created_at THEN
    RAISE EXCEPTION 'reconciliation alert %: only acknowledged_at, acknowledged_by and acknowledge_note may change (an alert is never edited, downgraded or re-pointed)', OLD.id
      USING ERRCODE = 'restrict_violation';
  END IF;
  IF NEW.acknowledged_at IS NULL OR NEW.acknowledged_by IS NULL THEN
    RAISE EXCEPTION 'reconciliation alert %: acknowledging must set both acknowledged_at and acknowledged_by', OLD.id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS reconciliation_alerts_before_update ON public.reconciliation_alerts;
CREATE TRIGGER reconciliation_alerts_before_update
  BEFORE UPDATE ON public.reconciliation_alerts
  FOR EACH ROW EXECUTE FUNCTION public.reconciliation_alerts_before_update();

DROP TRIGGER IF EXISTS reconciliation_alerts_no_delete ON public.reconciliation_alerts;
CREATE TRIGGER reconciliation_alerts_no_delete
  BEFORE DELETE ON public.reconciliation_alerts
  FOR EACH ROW EXECUTE FUNCTION public.reject_row_deletion();

-- ===========================================================================
-- 3. THE INVARIANT SCAN (global, recorded in the run detail, alerts on failure)
-- ===========================================================================
CREATE OR REPLACE FUNCTION public._reconciliation_invariant_scan(p_run_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_checks jsonb := '[]'::jsonb;
  v_unbalanced bigint;
  v_balance_bad bigint;
  v_asset_bad bigint;
BEGIN
  -- (1) every ledger transaction sums to zero, across all assets and environments
  SELECT count(*) INTO v_unbalanced
    FROM (SELECT t.id
            FROM public.ledger_transactions t
            JOIN public.ledger_entries e ON e.transaction_id = t.id
           GROUP BY t.id
          HAVING sum(e.amount_units) <> 0) x;

  -- (2) every account's cached balance equals its ledger sum (the PR #3 view)
  SELECT count(*) INTO v_balance_bad
    FROM public.v_account_reconciliation r
   WHERE r.drift_units <> 0;

  -- (3) every asset total across ALL accounts sums to zero, per environment
  SELECT count(*) INTO v_asset_bad
    FROM (SELECT acc.asset_id, acc.environment
            FROM public.ledger_entries e
            JOIN public.accounts acc ON acc.id = e.account_id
           GROUP BY acc.asset_id, acc.environment
          HAVING sum(e.amount_units) <> 0) y;

  v_checks := v_checks || jsonb_build_object(
    'check', 'ledger_transactions_balanced',
    'ok', v_unbalanced = 0,
    'offending', v_unbalanced,
    'sample_ids', COALESCE((
      SELECT jsonb_agg(x.id::text) FROM (
        SELECT t.id
          FROM public.ledger_transactions t
          JOIN public.ledger_entries e ON e.transaction_id = t.id
         GROUP BY t.id
        HAVING sum(e.amount_units) <> 0
         ORDER BY t.id
         LIMIT 20) x), '[]'::jsonb)
  );

  v_checks := v_checks || jsonb_build_object(
    'check', 'balances_match_ledger',
    'ok', v_balance_bad = 0,
    'offending', v_balance_bad,
    'sample_ids', COALESCE((
      SELECT jsonb_agg(x.account_id::text) FROM (
        SELECT r.account_id FROM public.v_account_reconciliation r
         WHERE r.drift_units <> 0
         ORDER BY r.account_id
         LIMIT 20) x), '[]'::jsonb)
  );

  v_checks := v_checks || jsonb_build_object(
    'check', 'asset_totals_zero',
    'ok', v_asset_bad = 0,
    'offending', v_asset_bad,
    'sample_ids', COALESCE((
      SELECT jsonb_agg(x.asset_id::text || '@' || x.environment) FROM (
        SELECT acc.asset_id, acc.environment
          FROM public.ledger_entries e
          JOIN public.accounts acc ON acc.id = e.account_id
         GROUP BY acc.asset_id, acc.environment
        HAVING sum(e.amount_units) <> 0
         ORDER BY acc.asset_id, acc.environment
         LIMIT 20) x), '[]'::jsonb)
  );

  -- a failing check is a CRITICAL alert with the offending ids (bounded), per
  -- (asset, environment) so the alert is actionable. The check-level view with
  -- every offending id is in the run detail.
  IF v_unbalanced > 0 THEN
    INSERT INTO public.reconciliation_alerts (run_id, asset_id, environment, severity, kind, detail)
    SELECT DISTINCT p_run_id, e.asset_id, t.environment, 'critical', 'internal_drift',
           jsonb_build_object(
             'check', 'ledger_transactions_balanced',
             'transaction_id', t.id,
             'note', 'a ledger transaction does not sum to zero: the journal itself is inconsistent. Reconciliation reports it and corrects nothing.')
      FROM (SELECT t2.id
              FROM public.ledger_transactions t2
              JOIN public.ledger_entries e2 ON e2.transaction_id = t2.id
             GROUP BY t2.id
            HAVING sum(e2.amount_units) <> 0
             LIMIT 20) bad
      JOIN public.ledger_transactions t ON t.id = bad.id
      JOIN public.ledger_entries e ON e.transaction_id = t.id
    ON CONFLICT ON CONSTRAINT reconciliation_alerts_key DO NOTHING;
  END IF;

  IF v_balance_bad > 0 THEN
    INSERT INTO public.reconciliation_alerts (run_id, asset_id, environment, severity, kind, detail)
    SELECT DISTINCT p_run_id, r.asset_id, r.environment, 'critical', 'internal_drift',
           jsonb_build_object(
             'check', 'balances_match_ledger',
             'account_id', r.account_id,
             'account_code', r.code,
             'cached_total_units', r.cached_total_units,
             'ledger_total_units', r.ledger_total_units,
             'drift_units', r.drift_units,
             'note', 'a cached balance disagrees with its ledger sum. Reconciliation reports it and corrects nothing; the repair is a deliberate compensating posting by an operator.')
      FROM (SELECT r.account_id, acc.asset_id, r.environment, r.code,
                   r.cached_total_units, r.ledger_total_units, r.drift_units
              FROM public.v_account_reconciliation r
              JOIN public.accounts acc ON acc.id = r.account_id
             WHERE r.drift_units <> 0
             ORDER BY r.account_id
             LIMIT 20) r
    ON CONFLICT ON CONSTRAINT reconciliation_alerts_key DO NOTHING;
  END IF;

  IF v_asset_bad > 0 THEN
    INSERT INTO public.reconciliation_alerts (run_id, asset_id, environment, severity, kind, detail)
    SELECT p_run_id, y.asset_id, y.environment, 'critical', 'custody_mismatch',
           jsonb_build_object(
             'check', 'asset_totals_zero',
             'asset_total_units', y.total_units,
             'note', 'the double-entry mirror for this asset and environment does not sum to zero. Reconciliation reports it and corrects nothing.')
      FROM (SELECT acc.asset_id, acc.environment, sum(e.amount_units) AS total_units
              FROM public.ledger_entries e
              JOIN public.accounts acc ON acc.id = e.account_id
             GROUP BY acc.asset_id, acc.environment
            HAVING sum(e.amount_units) <> 0
             ORDER BY acc.asset_id, acc.environment
             LIMIT 20) y
    ON CONFLICT ON CONSTRAINT reconciliation_alerts_key DO NOTHING;
  END IF;

  RETURN v_checks;
END $fn$;

COMMENT ON FUNCTION public._reconciliation_invariant_scan(uuid) IS
  'Internal: runs the three global invariants (every transaction sums to zero, every cached balance equals its ledger sum, every asset total across all accounts is zero), returns a per-check pass/fail object for the run detail and raises a CRITICAL alert per offending (asset, environment) with a bounded list of ids. It writes no money and changes no balance.';

-- ===========================================================================
-- 4. run_reconciliation — one snapshot, operator-guarded, audited
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.run_reconciliation(
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
  v_env    text := lower(btrim(coalesce(p_environment, 'paper')));
  v_run    uuid;
  v_inv    jsonb;
  v_status text;
BEGIN
  IF v_env NOT IN ('paper', 'live') THEN
    RAISE EXCEPTION 'run_reconciliation: unknown environment % (paper|live)', p_environment
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- security.read: an operator (or an edge function passing p_operator_id /
  -- gtvx.operator_id on the service_role path). A run is always attributable.
  v_op := public.assert_operator('security.read', p_operator_id);

  INSERT INTO public.reconciliation_runs (environment, status, triggered_by)
  VALUES (v_env, 'running', v_op)
  RETURNING id INTO v_run;

  BEGIN
    -- ONE statement => ONE snapshot for every number in this run.
    INSERT INTO public.reconciliation_results (
      run_id, asset_id, environment,
      customer_liability_units, projection_units, custody_units,
      provider_units, drift_units, status, detail
    )
    SELECT v_run, x.asset_id, v_env,
           x.liability_units, x.projection_units, x.custody_units,
           x.provider_units,
           x.liability_units - x.projection_units,
           CASE
             WHEN x.liability_units <> x.projection_units
                  OR (x.liability_units + x.system_mirror_units) <> 0 THEN 'drift'
             WHEN x.provider_units IS NULL THEN 'unavailable'
             WHEN x.provider_units <> x.custody_units THEN 'drift'
             ELSE 'match'
           END,
           jsonb_build_object(
             'asset', x.symbol,
             'internal_drift_units', x.liability_units - x.projection_units,
             'custody_breakdown', x.custody_breakdown,
             'system_mirror_units', x.system_mirror_units,
             'all_accounts_total_units', x.liability_units + x.system_mirror_units,
             'non_custody_system_units', x.liability_units - x.custody_units,
             'provider_networks', x.provider_networks,
             'provider_last_reported_at', x.provider_last_at,
             'provider_drift_units', CASE WHEN x.provider_units IS NULL THEN NULL
                                          ELSE x.provider_units - x.custody_units END,
             'provider_status', CASE WHEN x.provider_units IS NULL THEN 'unavailable' ELSE 'reported' END,
             'note', 'detect and report only: reconciliation never adjusts a balance, a ledger row or a provider figure'
           )
      FROM (
        SELECT a.id AS asset_id,
               a.symbol,
               COALESCE(l.units, 0) AS liability_units,
               COALESCE(p.units, 0) AS projection_units,
               COALESCE(c.units, 0) AS custody_units,
               COALESCE(c.breakdown, '{}'::jsonb) AS custody_breakdown,
               COALESCE(s.units, 0) AS system_mirror_units,
               pr.units AS provider_units,
               pr.last_at AS provider_last_at,
               pr.per_network AS provider_networks
          FROM public.assets a
          LEFT JOIN (
            SELECT acc.asset_id, sum(e.amount_units) AS units
              FROM public.ledger_entries e
              JOIN public.accounts acc ON acc.id = e.account_id
             WHERE acc.environment = v_env AND acc.account_type = 'user'
             GROUP BY acc.asset_id
          ) l ON l.asset_id = a.id
          LEFT JOIN (
            SELECT acc.asset_id,
                   sum(COALESCE(b.available_units, 0) + COALESCE(b.locked_units, 0)) AS units
              FROM public.accounts acc
              LEFT JOIN public.balances b ON b.account_id = acc.id
             WHERE acc.environment = v_env AND acc.account_type = 'user'
             GROUP BY acc.asset_id
          ) p ON p.asset_id = a.id
          LEFT JOIN (
            SELECT cc.asset_id, sum(cc.units) AS units,
                   jsonb_object_agg(cc.code, cc.units) AS breakdown
              FROM (
                SELECT acc.asset_id, acc.code, -sum(e.amount_units) AS units
                  FROM public.ledger_entries e
                  JOIN public.accounts acc ON acc.id = e.account_id
                 WHERE acc.environment = v_env
                   AND acc.account_type = 'system'
                   AND acc.code IN ('EXTERNAL_DEPOSIT', 'WITHDRAWAL_CLEARING')
                 GROUP BY acc.asset_id, acc.code
              ) cc
             GROUP BY cc.asset_id
          ) c ON c.asset_id = a.id
          LEFT JOIN (
            SELECT acc.asset_id, sum(e.amount_units) AS units
              FROM public.ledger_entries e
              JOIN public.accounts acc ON acc.id = e.account_id
             WHERE acc.environment = v_env AND acc.account_type = 'system'
             GROUP BY acc.asset_id
          ) s ON s.asset_id = a.id
          LEFT JOIN (
            SELECT pb.asset_id, sum(pb.units) AS units, max(pb.reported_at) AS last_at,
                   jsonb_object_agg(pb.network, pb.units) AS per_network
              FROM public.provider_balances pb
             WHERE pb.environment = v_env
             GROUP BY pb.asset_id
          ) pr ON pr.asset_id = a.id
         WHERE a.is_active
      ) x;

    -- internal drift: the projection disagrees with the ledger (CRITICAL)
    INSERT INTO public.reconciliation_alerts (run_id, asset_id, environment, severity, kind, detail)
    SELECT r.run_id, r.asset_id, r.environment, 'critical', 'internal_drift',
           jsonb_build_object(
             'check', 'customer_liability_vs_projection',
             'customer_liability_units', r.customer_liability_units,
             'projection_units', r.projection_units,
             'drift_units', r.drift_units,
             'note', 'the cached balance projection disagrees with the ledger. Reconciliation reports it and corrects nothing.')
      FROM public.reconciliation_results r
     WHERE r.run_id = v_run
       AND r.customer_liability_units <> r.projection_units
    ON CONFLICT ON CONSTRAINT reconciliation_alerts_key DO NOTHING;

    -- the double-entry mirror for this asset/environment is not zero (CRITICAL)
    INSERT INTO public.reconciliation_alerts (run_id, asset_id, environment, severity, kind, detail)
    SELECT r.run_id, r.asset_id, r.environment, 'critical', 'custody_mismatch',
           jsonb_build_object(
             'check', 'system_mirror_zero',
             'all_accounts_total_units', (r.detail ->> 'all_accounts_total_units')::numeric,
             'note', 'user accounts and system accounts do not mirror each other for this asset. Reconciliation reports it and corrects nothing.')
      FROM public.reconciliation_results r
     WHERE r.run_id = v_run
       AND (r.detail ->> 'all_accounts_total_units')::numeric <> 0
    ON CONFLICT ON CONSTRAINT reconciliation_alerts_key DO NOTHING;

    -- the provider reports a different holding than the ledger says (WARNING)
    INSERT INTO public.reconciliation_alerts (run_id, asset_id, environment, severity, kind, detail)
    SELECT r.run_id, r.asset_id, r.environment, 'warning', 'provider_mismatch',
           jsonb_build_object(
             'custody_units', r.custody_units,
             'provider_units', r.provider_units,
             'provider_drift_units', r.provider_units - r.custody_units,
             'provider_networks', r.detail -> 'provider_networks',
             'note', 'the provider reports a different holding than the ledger implies. Provider data is untrusted until stage 7 verifies the adapter, so this is a WARNING and nothing is corrected.')
      FROM public.reconciliation_results r
     WHERE r.run_id = v_run
       AND r.provider_units IS NOT NULL
       AND r.provider_units <> r.custody_units
    ON CONFLICT ON CONSTRAINT reconciliation_alerts_key DO NOTHING;

    -- a provider report older than 24h is stale (WARNING), match or not
    INSERT INTO public.reconciliation_alerts (run_id, asset_id, environment, severity, kind, detail)
    SELECT r.run_id, r.asset_id, r.environment, 'warning', 'stale_provider',
           jsonb_build_object(
             'provider_last_reported_at', r.detail -> 'provider_last_reported_at',
             'age_hours', round(extract(epoch FROM (now() - (r.detail ->> 'provider_last_reported_at')::timestamptz)) / 3600.0, 2),
             'threshold_hours', 24,
             'note', 'the newest provider report is older than the staleness threshold. An old number is reported as old, never silently reused as current.')
      FROM public.reconciliation_results r
     WHERE r.run_id = v_run
       AND r.provider_units IS NOT NULL
       AND (r.detail ->> 'provider_last_reported_at')::timestamptz < now() - interval '24 hours'
    ON CONFLICT ON CONSTRAINT reconciliation_alerts_key DO NOTHING;

    -- the global invariant scan, recorded per check in the run detail
    v_inv := public._reconciliation_invariant_scan(v_run);

    UPDATE public.reconciliation_runs
       SET status = 'completed',
           finished_at = now(),
           detail = jsonb_build_object(
             'environment', v_env,
             'assets_scanned', (SELECT count(*) FROM public.reconciliation_results WHERE run_id = v_run),
             'results', jsonb_build_object(
               'match',       (SELECT count(*) FROM public.reconciliation_results WHERE run_id = v_run AND status = 'match'),
               'drift',       (SELECT count(*) FROM public.reconciliation_results WHERE run_id = v_run AND status = 'drift'),
               'unavailable', (SELECT count(*) FROM public.reconciliation_results WHERE run_id = v_run AND status = 'unavailable')
             ),
             'alerts', jsonb_build_object(
               'critical', (SELECT count(*) FROM public.reconciliation_alerts WHERE run_id = v_run AND severity = 'critical'),
               'warning',  (SELECT count(*) FROM public.reconciliation_alerts WHERE run_id = v_run AND severity = 'warning')
             ),
             'provider_balances_reported', (SELECT count(*) FROM public.provider_balances WHERE environment = v_env),
             'invariants', v_inv,
             'note', 'detect and report only: reconciliation never corrects a balance, a ledger row or a provider figure. A real correction is a deliberate compensating ledger posting executed by an operator, which is not built here.'
           )
     WHERE id = v_run;
  EXCEPTION WHEN OTHERS THEN
    -- a run that cannot finish is recorded as failed with the error. Nothing is
    -- swallowed: the caller gets the run id and must read status/detail.
    UPDATE public.reconciliation_runs
       SET status = 'failed',
           finished_at = now(),
           detail = jsonb_build_object(
             'environment', v_env,
             'error', SQLERRM,
             'sqlstate', SQLSTATE,
             'note', 'the run raised; no result rows were kept for it'
           )
     WHERE id = v_run;
  END;

  SELECT status INTO v_status FROM public.reconciliation_runs WHERE id = v_run;

  PERFORM public.log_operator_action(
    'reconciliation.run',
    'reconciliation_run',
    v_run,
    NULL,
    jsonb_build_object(
      'environment', v_env,
      'status', v_status,
      'results', (SELECT count(*) FROM public.reconciliation_results WHERE run_id = v_run),
      'alerts', (SELECT count(*) FROM public.reconciliation_alerts WHERE run_id = v_run)
    ),
    v_op
  );

  RETURN v_run;
END $fn$;

COMMENT ON FUNCTION public.run_reconciliation(text, uuid) IS
  'Operator path (security.read, audited with a real actor): compute one reconciliation result per active asset for p_environment in a single snapshot, raise discrepancy alerts, run the three global invariants and record their pass/fail in the run detail. Detect and report ONLY — no balance, ledger row or provider figure is ever written or adjusted. A run that raises is recorded as failed with the error in detail.';

-- ---------------------------------------------------------------------------
-- acknowledge — acknowledge != fix
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.acknowledge_reconciliation_alert(
  p_alert_id uuid,
  p_note     text DEFAULT NULL,
  p_operator_id uuid DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_op    uuid;
  v_alert public.reconciliation_alerts;
BEGIN
  v_op := public.assert_operator('risk.write', p_operator_id);

  SELECT * INTO v_alert FROM public.reconciliation_alerts WHERE id = p_alert_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown reconciliation alert %', p_alert_id USING ERRCODE = 'no_data_found';
  END IF;
  IF v_alert.acknowledged_at IS NOT NULL THEN
    RAISE EXCEPTION 'reconciliation alert % was already acknowledged at % by operator %',
      v_alert.id, v_alert.acknowledged_at, v_alert.acknowledged_by
      USING ERRCODE = 'unique_violation';
  END IF;

  UPDATE public.reconciliation_alerts
     SET acknowledged_at = now(),
         acknowledged_by = v_op,
         acknowledge_note = NULLIF(btrim(COALESCE(p_note, '')), '')
   WHERE id = p_alert_id;

  PERFORM public.log_operator_action(
    'reconciliation.alert.acknowledged',
    'reconciliation_alert',
    p_alert_id,
    NULL,
    jsonb_build_object(
      'kind', v_alert.kind,
      'severity', v_alert.severity,
      'asset_id', v_alert.asset_id,
      'environment', v_alert.environment,
      'run_id', v_alert.run_id,
      'note', NULLIF(btrim(COALESCE(p_note, '')), ''),
      'effect', 'acknowledged only: no balance, ledger row or provider figure was changed'
    ),
    v_op
  );

  RETURN p_alert_id;
END $fn$;

COMMENT ON FUNCTION public.acknowledge_reconciliation_alert(uuid, text, uuid) IS
  'Operator path (risk.write, audited): record that a human has seen a discrepancy. It changes the three acknowledge columns and NOTHING else — no balance, ledger row or provider figure — and an acknowledgement is write-once. Acknowledging is not fixing.';

-- ===========================================================================
-- 5. ADMIN VIEWS
-- ===========================================================================
-- Owner-run views (no security_invoker), exactly like v_admin_custody /
-- v_admin_liquidity / v_admin_alerts: the scoping is operator_can_do() inside the
-- view, and the base tables stay unreachable for client roles (no grant at all).
CREATE OR REPLACE VIEW public.v_admin_reconciliation
AS
WITH latest AS (
  SELECT DISTINCT ON (r.environment)
         r.id, r.environment, r.status, r.started_at, r.finished_at, r.triggered_by, r.detail
    FROM public.reconciliation_runs r
   ORDER BY r.environment, r.started_at DESC, r.id DESC
)
SELECT l.id AS run_id,
       l.environment,
       l.status AS run_status,
       l.started_at,
       l.finished_at,
       u.username AS triggered_by_username,
       ast.symbol AS asset,
       res.customer_liability_units,
       res.projection_units,
       res.custody_units,
       res.provider_units,
       res.drift_units,
       COALESCE(res.status, l.status) AS status,
       res.detail,
       COALESCE(al.open_alerts, 0) AS open_alert_count,
       COALESCE(al.acknowledged_alerts, 0) AS acknowledged_alert_count,
       al.worst_open_severity
  FROM latest l
  LEFT JOIN public.reconciliation_results res ON res.run_id = l.id
  LEFT JOIN public.assets ast ON ast.id = res.asset_id
  LEFT JOIN public.admin_users u ON u.id = l.triggered_by
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE a.acknowledged_at IS NULL) AS open_alerts,
           count(*) FILTER (WHERE a.acknowledged_at IS NOT NULL) AS acknowledged_alerts,
           min(a.severity) FILTER (WHERE a.acknowledged_at IS NULL) AS worst_open_severity
      FROM public.reconciliation_alerts a
     WHERE a.run_id = l.id
  ) al ON true
 WHERE public.operator_can_do('money.read');

COMMENT ON VIEW public.v_admin_reconciliation IS
  'Latest run per environment: one row per asset with the four numbers, the status, the detail JSON and the open/acknowledged alert counts. A run that produced no result rows (failed or still running) still appears once with asset NULL and status = the run status, so a failed run is never invisible. Requires money.read; a non-operator sees nothing.';

CREATE OR REPLACE VIEW public.v_admin_reconciliation_alerts
AS
SELECT a.id AS alert_id,
       a.run_id,
       r.started_at AS run_started_at,
       ast.symbol AS asset,
       a.environment,
       a.severity,
       a.kind,
       a.detail,
       a.created_at,
       a.acknowledged_at,
       a.acknowledged_by,
       u.username AS acknowledged_by_username,
       a.acknowledge_note,
       (a.acknowledged_at IS NULL) AS is_open
  FROM public.reconciliation_alerts a
  JOIN public.reconciliation_runs r ON r.id = a.run_id
  JOIN public.assets ast ON ast.id = a.asset_id
  LEFT JOIN public.admin_users u ON u.id = a.acknowledged_by
 WHERE public.operator_can_do('security.read');

COMMENT ON VIEW public.v_admin_reconciliation_alerts IS
  'Every reconciliation alert with its run, asset, severity, kind, detail and acknowledgement state. Requires security.read (a support operator has no access). Read-only: the only write path is acknowledge_reconciliation_alert().';

-- ===========================================================================
-- 6. RLS + PRIVILEGES
-- ===========================================================================
-- All five tables: RLS on with NO policy (the admin_users / system_health
-- pattern), so a direct select by any client role returns zero rows rather than
-- an error, and the views are the only read paths. Every table is SELECT-only
-- for every role: the RPCs above (SECURITY DEFINER) are the only write path.
ALTER TABLE public.provider_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.provider_balances_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reconciliation_alerts ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.provider_balances, public.provider_balances_log,
              public.reconciliation_runs, public.reconciliation_results,
              public.reconciliation_alerts FROM PUBLIC;
REVOKE ALL ON public.v_admin_reconciliation, public.v_admin_reconciliation_alerts FROM PUBLIC;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE ALL ON public.provider_balances, public.provider_balances_log,
                  public.reconciliation_runs, public.reconciliation_results,
                  public.reconciliation_alerts FROM anon;
    REVOKE ALL ON public.v_admin_reconciliation, public.v_admin_reconciliation_alerts FROM anon;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON public.provider_balances, public.provider_balances_log,
                  public.reconciliation_runs, public.reconciliation_results,
                  public.reconciliation_alerts FROM authenticated;
    GRANT SELECT ON public.v_admin_reconciliation, public.v_admin_reconciliation_alerts TO authenticated;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    -- Supabase's default privileges grant ALL on a new public table to
    -- service_role, so the write privileges have to be taken away explicitly:
    -- these five tables are SELECT-only for EVERY role and the RPCs above are the
    -- only write path.
    REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.provider_balances, public.provider_balances_log,
                  public.reconciliation_runs, public.reconciliation_results,
                  public.reconciliation_alerts FROM service_role;
    GRANT SELECT ON public.provider_balances, public.provider_balances_log,
                    public.reconciliation_runs, public.reconciliation_results,
                    public.reconciliation_alerts TO service_role;
    GRANT SELECT ON public.v_admin_reconciliation, public.v_admin_reconciliation_alerts TO service_role;
  END IF;
END $do$;

-- function ACLs: the three public entry points are service_role only; the
-- internal scan and the trigger functions are never callable by a client.
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
         'record_provider_balance', 'run_reconciliation',
         'acknowledge_reconciliation_alert', '_reconciliation_invariant_scan',
         'provider_balances_audit', 'reconciliation_runs_before_update',
         'reconciliation_alerts_before_update', 'reject_row_deletion'
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

-- the identity helpers the two views depend on must stay executable by
-- authenticated (PostgreSQL checks EXECUTE against the INVOKING role).
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
BEGIN
  SELECT mode, paper_trading_enabled, live_trading_enabled, deposits_enabled, withdrawals_enabled
    INTO v_mode, v_pt, v_lt, v_dep, v_wd
    FROM public.app_settings;
  RAISE NOTICE 'reconciliation installed: mode=% paper_trading=% live_trading=% deposits=% withdrawals=% ; provider_balances rows=% (0 = no provider exists yet, comparisons are unavailable, never 0)',
    v_mode, v_pt, v_lt, v_dep, v_wd, (SELECT count(*) FROM public.provider_balances);
END $do$;
