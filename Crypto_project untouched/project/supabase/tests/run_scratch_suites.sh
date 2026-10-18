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
grep -E 'SUMMARY' "$LOGDIR/matching.log" | grep -q 'fail=0' || rc=1
grep -E 'SUMMARY' "$LOGDIR/deposits.log" | grep -q 'fail=0' || rc=1
echo "logs in $LOGDIR ; exit status $rc"
exit $rc
