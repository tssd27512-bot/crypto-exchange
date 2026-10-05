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
