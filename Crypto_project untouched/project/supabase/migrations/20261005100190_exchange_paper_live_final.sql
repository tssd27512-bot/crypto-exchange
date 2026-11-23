/*
# Migration 26 — paper/live separation finalisation (stage 5)

Purpose
-------
Owner directive stage 5: an AUDIT-AND-CLOSE-GAPS pass over every user-reachable
money/state path. The audit (recorded in SCHEMA.md, section "Stage 5 — paper/live
separation matrix") found the existing machinery already enforcing mode separation
on trading, deposits, withdrawals and KYC:

  * `enforce_environment_gate` triggers on accounts, ledger_transactions, orders,
    trades, deposits and withdrawal_requests (a live row is refused unless
    mode='live' AND the feature flag is on);
  * `assert_trading_enabled()` (place_order, cancel_order, settle_fill);
  * `assert_deposits_enabled()` / `assert_withdrawals_enabled()` plus the
    source↔mode pairing inside `_deposit_ingest` / `_withdrawal_ingest`
    (paper_operator refused outside paper mode, provider_adapter refused outside
    live mode);
  * `assert_paper_deposits_enabled()` / `assert_paper_withdrawals_enabled()`;
  * `assert_kyc_path()` (paper_operator vs provider_adapter, both directions);
  * `assert_not_in_maintenance()` and `assert_account_not_restricted()`.

Three gaps were found and are closed here. Nothing existing is weakened; the only
edits are inserted guard lines, every other line of each function is byte-identical
to the version already deployed by migrations 6 and 18.

  GAP 1 (trading): `assert_trading_enabled()` required mode='live' AND
    live_trading_enabled, but never read `live_enabled_at`. The table CHECK
    `app_settings_live_gate_check` makes mode='live' impossible without that
    timestamp, so no live order could in fact be created without it — but the
    engine's gate now reads the same three values the CHECK enforces instead of
    trusting `mode` alone. Paper trading is unchanged (still gated by
    `paper_trading_enabled`).

  GAP 2 (provider-balance intake): `record_provider_balance()` accepted
    p_environment='live' while the exchange was in paper mode, so a real custody
    figure could be written into a paper-mode database and would then be compared
    against the (empty) live book. It now refuses a live report unless
    app_settings.mode = 'live'. Paper reports are unchanged.

  GAP 3 (reconciliation runs): `run_reconciliation()` accepted p_environment='live'
    while the exchange was in paper mode, creating live runs/results/alerts. It now
    refuses a live run unless app_settings.mode = 'live'. Paper runs are unchanged.

Not changed, and why (see SCHEMA.md for the full matrix):
  * `cancel_order()` deliberately does not read maintenance mode or account
    restrictions: cancelling is the fund-releasing direction and must stay
    available while trading is restricted or the exchange is in maintenance.
  * `admin_upsert_market(..., p_environment)` can create a live market row while
    the exchange is paper. It moves no money and the row is inert (no order can be
    created in the live environment until mode='live'), so it is documented rather
    than gated — flagged for the owner in SCHEMA.md.
  * The release paths (`reject_withdrawal`, `fail_withdrawal`) deliberately do not
    read the paper withdrawal switch: locked funds must always be releasable.

Safety
------
app_settings is NOT touched by this migration: mode stays 'paper', every LIVE_*
flag stays false, paper_trading_enabled stays true, live_enabled_at stays NULL.
No table, column, trigger or policy is added, dropped or altered. Nothing here
creates money, data or a customer.
*/

-- ---------------------------------------------------------------------------
-- GAP 1 — trading: live trading also requires the recorded go-live timestamp
--
-- Only the comment block above the new guard and the guard itself are new. The
-- rest of the body is the migration-6 definition verbatim.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_trading_enabled()
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_mode  text;
  v_paper boolean;
  v_live  boolean;
BEGIN
  SELECT mode, paper_trading_enabled, live_trading_enabled
    INTO v_mode, v_paper, v_live
    FROM public.app_settings
   WHERE id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'app_settings has no row: the paper/live mode gate cannot be evaluated'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_mode = 'live' THEN
    IF NOT COALESCE(v_live, false) THEN
      RAISE EXCEPTION 'live trading is disabled: app_settings.mode = live but live_trading_enabled = false; refusing to move funds'
        USING ERRCODE = 'check_violation';
    END IF;

    -- >>> 20261005100190 (stage 5, paper/live separation): live trading requires the
    -- recorded go-live timestamp as well as the flag. app_settings_live_gate_check
    -- already forbids mode='live' without live_enabled_at, so this is belt-and-braces:
    -- the engine no longer trusts `mode` alone on the live path.
    IF NOT EXISTS (
      SELECT 1 FROM public.app_settings
       WHERE id AND live_enabled_at IS NOT NULL
    ) THEN
      RAISE EXCEPTION 'live trading is disabled: app_settings.mode = live but live_enabled_at is NULL (no go-live timestamp recorded); refusing to move funds'
        USING ERRCODE = 'check_violation';
    END IF;
  ELSE
    IF NOT COALESCE(v_paper, false) THEN
      RAISE EXCEPTION 'trading is disabled: paper_trading_enabled = false in app_settings (mode %); the engine is inert', v_mode
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  RETURN v_mode;
END $fn$;

-- ---------------------------------------------------------------------------
-- GAP 2 — provider-balance intake: a live report requires a live exchange
--
-- Only the comment block and the guard are new; the rest of the body is the
-- migration-18 definition verbatim.
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

  -- >>> 20261005100190 (stage 5, paper/live separation): a LIVE provider number may
  -- only enter while the exchange is live. Paper mode cannot accept a real custody
  -- figure (it would be compared against a book that cannot exist yet). Paper reports
  -- are unchanged by this guard.
  IF v_env = 'live' AND public.app_mode() <> 'live' THEN
    RAISE EXCEPTION 'record_provider_balance: a live provider balance may only be recorded while the exchange is live (app_settings.mode = %); refusing a live report in paper mode', public.app_mode()
      USING ERRCODE = 'check_violation';
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

-- ---------------------------------------------------------------------------
-- GAP 3 — reconciliation runs: a live run requires a live exchange
--
-- Only the comment block and the guard are new; the rest of the body is the
-- migration-18 definition verbatim.
-- ---------------------------------------------------------------------------
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

  -- >>> 20261005100190 (stage 5, paper/live separation): a LIVE reconciliation run may
  -- only happen while the exchange is live, so paper mode cannot manufacture live
  -- runs/results/alerts for a book that cannot exist yet. Paper runs are unchanged.
  IF v_env = 'live' AND public.app_mode() <> 'live' THEN
    RAISE EXCEPTION 'run_reconciliation: a live reconciliation run may only happen while the exchange is live (app_settings.mode = %); refusing a live run in paper mode', public.app_mode()
      USING ERRCODE = 'check_violation';
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

-- ---------------------------------------------------------------------------
-- re-assert the safety state (nothing above may have moved it)
-- ---------------------------------------------------------------------------
DO $fn$
DECLARE
  s public.app_settings;
BEGIN
  SELECT * INTO s FROM public.app_settings WHERE id;
  IF s.mode <> 'paper' OR s.live_trading_enabled OR s.deposits_enabled
     OR s.withdrawals_enabled OR s.live_enabled_at IS NOT NULL
     OR NOT s.paper_trading_enabled THEN
    RAISE EXCEPTION 'migration 20261005100190 must not change app_settings (mode=%, live_trading=%, deposits=%, withdrawals=%, live_enabled_at=%, paper_trading=%)',
      s.mode, s.live_trading_enabled, s.deposits_enabled, s.withdrawals_enabled, s.live_enabled_at, s.paper_trading_enabled;
  END IF;
  RAISE NOTICE '[paper/live final] app_settings unchanged: mode=%, paper_trading=%, live_trading=%, deposits=%, withdrawals=%, live_enabled_at is null=%',
    s.mode, s.paper_trading_enabled, s.live_trading_enabled, s.deposits_enabled, s.withdrawals_enabled, s.live_enabled_at IS NULL;
END $fn$;
