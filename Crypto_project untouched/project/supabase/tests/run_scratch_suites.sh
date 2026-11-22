#!/bin/sh
# Run every exchange verification suite against a scratch PostgreSQL, in the only order
# that works. Run as root (it calls `su postgres`). Never point this at the live Supabase
# project ctrazoqbudsfkpawpomv — these suites create users, orders and ledger rows.
#
#   ./run_scratch_suites.sh [/path/to/Crypto_project untouched/project/supabase]
#
# Layout it sets up (and why):
#   $DB_CORE  one database, freshly migrated, runs in this order:
#               00_supabase_stub.sql -> migrations/*.sql -> exchange_schema_tests.sql
#               -> exchange_ledger_invariant_tests.sql -> exchange_immutability_rls_probe.sql
#             The ledger suite and the probe reuse the fixture data (auth user 1111...,
#             its funded paper accounts/orders/ledger rows) and the t.expect helper that
#             exchange_schema_tests.sql creates, so they MUST share this database and run
#             after it. Run standalone, the ledger suite used to die with
#             'schema "t" does not exist' and a misleading D5 double-entry error.
#   $DB_MATCH a second, freshly migrated database for exchange_matching_engine_tests.sql
#             alone: its fixtures are not idempotent, so it must never run twice in the
#             same database (the second run reports ~17 phantom FAILs).
# Logs (default /tmp/pr3-logs) and a one-line summary per suite are printed; the exit
# status is non-zero if any suite is not green.
set -u
P=${1:-/usr/local/share/crypto-exchange/supabase}
DB_CORE=${DB_CORE:-gtvx_verify_core}
DB_MATCH=${DB_MATCH:-gtvx_verify_match}
LOGDIR=${LOGDIR:-/tmp/pr3-logs}
mkdir -p "$LOGDIR"
rc=0

psql_() { su postgres -c "psql $*"; }

apply() { # $1 = database name
  psql_ "-q -c \"drop database if exists $1\"" >/dev/null 2>&1
  psql_ "-q -c \"create database $1\"" >/dev/null 2>&1 || { echo "cannot create $1"; exit 1; }
  psql_ "-q -v ON_ERROR_STOP=1 -d $1 -f '$P/tests/00_supabase_stub.sql'" >/dev/null || { echo "STUB FAILED"; exit 1; }
  # the repo path contains a space, so never word-split the file list
  ls "$P"/migrations/*.sql | sort > "$LOGDIR/.migration_list"
  while IFS= read -r f; do
    if ! psql_ "-q -v ON_ERROR_STOP=1 -d $1 -f '$f'" >/dev/null 2>"$LOGDIR/migration.err"; then
      echo "MIGRATION FAILED: $f"; cat "$LOGDIR/migration.err"; exit 1
    fi
  done < "$LOGDIR/.migration_list"
  echo "migrations applied to $1"
}

apply "$DB_CORE"
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_schema_tests.sql'"          > "$LOGDIR/schema.log" 2>&1
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_ledger_invariant_tests.sql'" > "$LOGDIR/ledger.log" 2>&1
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_immutability_rls_probe.sql'" > "$LOGDIR/immutability_rls.log" 2>&1
# deposit layer: needs the schema fixtures (users) and the t/d helpers, so it runs
# last in the core database. It refuses to run twice in the same database.
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_deposit_tests.sql'" > "$LOGDIR/deposits.log" 2>&1
# withdrawal layer: needs the schema fixtures and the deposit suite's data in the same
# database (it asserts no stranded holds across the whole ledger), so it runs after it.
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_withdrawal_tests.sql'" > "$LOGDIR/withdrawals.log" 2>&1
# KYC / security layer (step 8): reads the withdrawal suite's fixture users, adds its own,
# and must run LAST in the core database. It leaves its live-mode probe rows behind on
# purpose (security_audit_log and terminal KYC rows are append-only), so it refuses to run
# twice in the same database.
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_kyc_tests.sql'" > "$LOGDIR/kyc.log" 2>&1
# admin / operator control plane (stage 2, part 1): needs the fixture users and the
# deposit/withdrawal networks the suites above register, and must run LAST in the core
# database. It flips maintenance_mode in BOTH directions and reverts it, and leaves its
# own audit rows behind on purpose (security_audit_log is append-only).
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_admin_tests.sql'" > "$LOGDIR/admin.log" 2>&1
# admin support + communications + status views (stage 2, part 2): runs after the admin
# suite (it reuses its operator control plane, fixture users and markets), places real
# orders through place_order and creates a market of its own. Additive, refuses nothing,
# leaves its notifications/announcements/chat rows behind on purpose.
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_admin_comms_tests.sql'" > "$LOGDIR/comms.log" 2>&1
# realtime publication + operational health checks (stage 3): runs LAST in the core
# database. It reuses the fixture users, the paper networks the deposit/withdrawal
# suites registered and the operator control plane, then adds its own paper deposit
# and withdrawal request and drives REAL state-machine transitions to prove the
# status-notification triggers. Realtime DELIVERY is not testable on scratch (no
# Realtime daemon, wal_level is replica): that stays a deployment-time check.
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_realtime_health_tests.sql'" > "$LOGDIR/realtime_health.log" 2>&1
# financial reconciliation + discrepancy alerts (stage 4): runs LAST in the core
# database. It reuses the fixture users, the registered paper networks, a credited
# deposit and a settled withdrawal from the suites above, and it drives two
# expected psql ERROR lines (deferred constraint triggers refusing internal drift,
# see the suite header). It leaves its own runs/alerts/provider rows behind on
# purpose: runs, alerts and the provider log are append-only.
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_reconciliation_tests.sql'" > "$LOGDIR/reconciliation.log" 2>&1
# paper/live separation audit (stage 5): runs ABSOLUTELY LAST in the core database.
# It reuses the fixture users, the registered paper networks and markets, then flips
# app_settings.mode to live and back (the only suite that does), so nothing may run
# after it. Every refusal is caught in-process: it emits NO bare psql ERROR line.
psql_ "-q -d $DB_CORE -f '$P/tests/exchange_separation_audit.sql'" > "$LOGDIR/separation_audit.log" 2>&1
apply "$DB_MATCH"
psql_ "-q -d $DB_MATCH -f '$P/tests/exchange_matching_engine_tests.sql'" > "$LOGDIR/matching.log" 2>&1

report() { # $1 = name, $2 = log, $3 = expected bare "psql:...ERROR" count
  n_pass=$(grep -cE 'NOTICE:  PASS' "$2" 2>/dev/null || true)
  n_fail=$(grep -cE 'NOTICE:  FAIL' "$2" 2>/dev/null || true)
  n_err=$(grep -cE '^psql:.*ERROR' "$2" 2>/dev/null || true)
  printf '%-16s PASS=%-4s FAIL=%-4s psql-ERRORs=%-4s (expected %s)\n' "$1" "$n_pass" "$n_fail" "$n_err" "$3"
  grep -E 'NOTICE:  FAIL' "$2" 2>/dev/null
  [ "$n_fail" = "0" ] && [ "$n_err" = "$3" ] || rc=1
}
grep -E 'SUMMARY' "$LOGDIR/matching.log" || true
report schema          "$LOGDIR/schema.log"          0
report ledger          "$LOGDIR/ledger.log"          4
report immutability_rls "$LOGDIR/immutability_rls.log" 0
report deposits          "$LOGDIR/deposits.log"          0
report withdrawals       "$LOGDIR/withdrawals.log"       0
report kyc               "$LOGDIR/kyc.log"               0
report admin             "$LOGDIR/admin.log"             0
report comms             "$LOGDIR/comms.log"             0
report realtime_health   "$LOGDIR/realtime_health.log"   0
report reconciliation    "$LOGDIR/reconciliation.log"     2
report separation_audit  "$LOGDIR/separation_audit.log"   0
# The reconciliation suite deliberately drives exactly TWO bare psql ERROR lines, both
# named in its header: R6 (a1) an UPDATE to a cached balance with no ledger entries is
# refused by the deferred constraint trigger ('balance drift on account'), and R6 (a2)
# an unbalanced ledger transaction is refused ('not a valid double-entry posting').
# Counting ERROR lines alone is not enough - a syntax error or a missing object would
# also count as "expected". So the two lines must be those two refusals and nothing else.
n_err=$(grep -cE '^psql:.*ERROR' "$LOGDIR/reconciliation.log" 2>/dev/null || true)
n_drift=$(grep -c 'balance drift on account' "$LOGDIR/reconciliation.log" 2>/dev/null || true)
n_unbal=$(grep -c 'not a valid double-entry posting' "$LOGDIR/reconciliation.log" 2>/dev/null || true)
n_bad=$(grep -cE '^psql:.*ERROR:  (syntax error|.*does not exist)' "$LOGDIR/reconciliation.log" 2>/dev/null || true)
if [ "$n_err" = "2" ] && [ "$n_drift" = "1" ] && [ "$n_unbal" = "1" ] && [ "$n_bad" = "0" ]; then
  echo "reconciliation   expected-ERROR gate: R6 (a1) drift refusal + R6 (a2) unbalanced-posting refusal, 2/2 matched"
else
  echo "reconciliation   expected-ERROR gate FAILED: errors=$n_err drift=$n_drift unbalanced=$n_unbal syntax/undefined=$n_bad"
  grep -E '^psql:.*ERROR' "$LOGDIR/reconciliation.log" 2>/dev/null || true
  rc=1
fi
grep -E 'SUMMARY' "$LOGDIR/matching.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/deposits.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/withdrawals.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/kyc.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/admin.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/comms.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/realtime_health.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/reconciliation.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/separation_audit.log" | grep -q 'fail=0' || rc=1
echo "logs in $LOGDIR ; exit status $rc"
exit $rc
