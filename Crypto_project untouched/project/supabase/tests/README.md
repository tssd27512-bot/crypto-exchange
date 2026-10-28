# Exchange schema verification tests

These run the six exchange migrations (`supabase/migrations/2026100510000*_exchange_*.sql`)
against a **scratch PostgreSQL** and check the schema's behaviour, not just that it parses.

They are destructive to the database they run in (they create auth users, accounts, orders and
ledger rows). **Never point them at the live Supabase project `ctrazoqbudsfkpawpomv`.**

## Why a stub

A Supabase database is an ordinary PostgreSQL database plus: the `anon`, `authenticated` and
`service_role` roles, the `auth` schema with `auth.uid()`, the `supabase_realtime` publication,
and default privileges that grant `ALL` on new `public` tables to those three roles. The stub
(`00_supabase_stub.sql`) recreates exactly those, which is what makes the RLS tests meaningful:
without the default-privilege grants, "anon cannot read" would pass for the wrong reason.

## Running

```bash
export DEBIAN_FRONTEND=noninteractive
apt-get install -y postgresql                      # PostgreSQL 16 is enough
pg_ctlcluster 16 main start
create() { su postgres -c "$1"; }
create "dropdb --if-exists gtvx_scratch; createdb gtvx_scratch"

P=/path/to/Crypto_project\ untouched/project/supabase
su postgres -c "psql -q -v ON_ERROR_STOP=1 -d gtvx_scratch -f $P/tests/00_supabase_stub.sql"

# apply every migration in filename order, exactly as Supabase would
for f in $(ls $P/migrations/*.sql | sort); do
  su postgres -c "psql -q -v ON_ERROR_STOP=1 -d gtvx_scratch -f $f" || break
done

su postgres -c "psql -q -d gtvx_scratch -f $P/tests/exchange_schema_tests.sql" \
  | grep -E 'PASS|FAIL'
su postgres -c "psql -q -d gtvx_scratch -f $P/tests/exchange_ledger_invariant_tests.sql" \
  | grep -E 'ERROR|PASS|FAIL'
```

## Reading the output

| File | Expected result |
|---|---|
| `exchange_schema_tests.sql` | every line `PASS`; `grep -c FAIL` is 0. Covers reference data, integer-unit money math, RLS (anon denied, `authenticated` sees only its own rows, no client write path), append-only enforcement, the paper/live gate, order validation and the balance guards. |
| `exchange_ledger_invariant_tests.sql` | **four `ERROR:` lines are the pass condition** — they are the deferred constraint triggers rejecting (D1) a single-entry transaction, (D2) a same-account round trip, (D3) a cached balance moved without ledger entries, (D4) ledger entries with no matching balance update. Each is followed by a `ROLLBACK`; the control transaction at D5 must commit, and D6's assertions must all be `PASS`. |

## Gotchas

- Roles are **cluster-wide** in PostgreSQL, so create them once (the stub does, guarded by
  `pg_roles` checks) and drop the database between runs, not the roles.
- `EXECUTE ... INTO` fails on a statement that returns no rows, which is why the negative tests
  use `INSERT ... RETURNING 1`.
- Deferred constraint triggers fire at `COMMIT`, so violations cannot be caught inside a
  `DO` block — those tests are top-level `BEGIN; … COMMIT;` statements whose error is the
  expected outcome.
- PostgreSQL rounds values into a `numeric(38,0)` column. A fractional amount is therefore
  rounded to the nearest integer unit rather than rejected; the tests assert that documented
  behaviour explicitly.

## Run every suite at once (recommended)

```bash
sudo ./tests/run_scratch_suites.sh "/path/to/Crypto_project untouched/project/supabase"
```

Creates two scratch databases, applies the stub + every migration to each, then runs
`exchange_schema_tests.sql` -> `exchange_ledger_invariant_tests.sql` ->
`exchange_immutability_rls_probe.sql` in the first database and
`exchange_matching_engine_tests.sql` alone in the second. It prints one summary line per suite,
exits non-zero if any suite is not green, and keeps raw logs in `$LOGDIR` (default `/tmp/pr3-logs`).

| suite | green means |
|---|---|
| `exchange_schema_tests.sql` | `NOTICE:  PASS` 112, `NOTICE:  FAIL` 0, 0 `psql ... ERROR` |
| `exchange_ledger_invariant_tests.sql` | exactly 4 `psql ... ERROR` lines (D1-D4 are the pass condition), `NOTICE:  PASS` 5, `NOTICE:  FAIL` 0 |
| `exchange_immutability_rls_probe.sql` | `NOTICE:  PASS` 56, `NOTICE:  FAIL` 0 — ledger immutability as postgres/authenticated/anon plus the full RLS matrix |
| `exchange_matching_engine_tests.sql` | `SUMMARY total=63 pass=63 fail=0` |
| `exchange_kyc_tests.sql` | `SUMMARY total=160 pass=160 fail=0` — the tier model, tier-0 materialisation, both decision paths, the provider-adapter contract, the no-PII guard, the append-only audit log, the authz matrix and the function ACLs |

## Suite dependencies and gotchas (learned the hard way)

- `exchange_ledger_invariant_tests.sql` and `exchange_immutability_rls_probe.sql` **must run in the
  same database as, and after, `exchange_schema_tests.sql`**: they reuse its fixtures (auth user
  `1111…1111`, its funded paper accounts/orders/ledger rows) and its `t.expect` helper. Both now
  refuse to run with an explanation if that order is broken; without the guards they died with
  `schema "t" does not exist` and a misleading D5 double-entry error.
- `exchange_matching_engine_tests.sql` **must run against a freshly migrated database**: its fixtures
  are not idempotent, so a second run in the same database re-funds the same users and reports 17
  FAILs plus a `users_pkey` error at line 65 (`SUMMARY total=61 pass=44 fail=17`) that look exactly
  like an engine regression. It now refuses to start in that case.
- The repo path contains a space — never `for f in $(ls "$P"/migrations/*.sql)` in a shell harness, or
  the list word-splits and the migration filenames are cut in half.
- Read results with `grep -E 'NOTICE:  (PASS|FAIL)'`: every line carries a `psql:file:line: NOTICE:`
  prefix, so a grep for `^ PASS` silently matches nothing.
- The book/market views (`v_order_book_best`, `v_order_book_depth`, `v_markets`) are readable only with
  a privileged token — `SELECT` is not granted to `anon`/`authenticated`. Client roles get
  `permission denied for view`, which is what the probe asserts.
