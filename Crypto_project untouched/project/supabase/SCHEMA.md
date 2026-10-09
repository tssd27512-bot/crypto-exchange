# GlobalTradeVX — exchange database schema

Foundational schema + RLS + immutable ledger for the exchange backend.
**Schema only** — no matching engine, no deposit/withdrawal/KYC/admin logic yet.

- Migrations: `supabase/migrations/2026100510000*_exchange_*.sql` (6 files, apply in timestamp order)
- Supabase project: `ctrazoqbudsfkpawpomv` (**reuse — no new project, no new database**)
- Existing tables are untouched: `chat_conversations`, `chat_messages`, `admin_users` and their 5
  migrations are not modified by any of these files. Only new objects are added.
- Nothing here is deployed. These files are for review; applying them to the live project is a separate,
  owner-approved step.

---

## 1. What each table is for

| Table | Purpose | Key columns |
|---|---|---|
| `app_settings` | One-row global switch. Holds the paper/live `mode` and the feature flags. Physically limited to one row by `CHECK (id)`. | `mode`, `live_trading_enabled`, `deposits_enabled`, `withdrawals_enabled`, `live_enabled_at` |
| `assets` | Coin/token reference data. `base_decimals` defines the integer ledger unit (BTC 8, ETH 18, USDT 6, SOL 9). Seeded with BTC/ETH/USDT/SOL. | `symbol` (unique), `base_decimals`, `chain`, `contract_address` |
| `markets` | Trading pairs, separated per environment. Holds precision, tick/step sizes, min sizes and maker/taker fees as **configuration** (defaults 2/5 bps to match the fee copy on the site). Seeded with paper BTC/USDT, ETH/USDT, SOL/USDT. | `base_asset_id`, `quote_asset_id`, `environment`, `price_scale`, `notional_scale`, `price_tick_units`, `qty_step_units` |
| `accounts` | Wallet container. One row per owner × asset × kind × environment. `account_type='user'` (linked to `auth.users`) or `account_type='system'` with a `code` (double-entry counterparty: `PAPER_FAUCET`, `FEE_INCOME`, later `EXTERNAL_DEPOSIT`/`EXTERNAL_WITHDRAWAL`). | `user_id`, `code`, `asset_id`, `kind`, `environment` |
| `balances` | Cached projection of the ledger for one account: `available_units` + `locked_units`, `version` for optimistic locking. Never the source of truth. | `account_id` (PK), `available_units`, `locked_units`, `version` |
| `ledger_transactions` | Append-only journal header, one row per money event (`order_hold`, `trade_fill`, `deposit_credit`, `withdrawal_settle`, `fee`, `paper_funding`, `admin_adjustment`, `correction`, …). | `type`, `environment`, `idempotency_key` (unique when set), `reference_type`/`reference_id`, `reverses_transaction_id` |
| `ledger_entries` | Append-only double-entry postings. Signed `amount_units`: positive credits, negative debits. Must sum to zero per asset per transaction. | `transaction_id`, `account_id`, `asset_id`, `amount_units` |
| `orders` | Order lifecycle: `side` buy/sell, `type` limit/market, TIF gtc/ioc/fok, limit price, quantity, running fill state, hold state, status, `client_order_id` idempotency key. | `user_id`, `market_id`, `price_units`, `qty_units`, `filled_*`, `hold_*`, `status` |
| `order_events` | Append-only audit of every order state transition. | `order_id`, `event`, `payload` |
| `trades` | One row per match (fills): taker/maker order and user, price, quantity, quote value, both fees, fee asset, and the `ledger_transaction_id` that settled it. Immutable. | `market_id`, `taker_order_id`, `maker_order_id`, `price_units`, `qty_units`, `taker_fee_units`, `maker_fee_units` |

Views (migration 6, PostgreSQL 15+ syntax):

| View | Purpose |
|---|---|
| `v_my_balances` | The frontend's balance contract: symbol, decimals, available/locked/total in integer units, scoped to the caller by RLS (`security_invoker = true`). |
| `v_account_reconciliation` | Per-account `balances` cache vs `SUM(ledger_entries)`. `drift_units` must always be 0. Server-side only (`service_role`). |

---

## 2. Money model — integer base units, never floats

**Rule: every amount in this schema is an integer count of the asset's smallest unit stored in
`numeric(38,0)`. There is no `float`, `double precision` or `real` column anywhere.**

| Asset | Unit | `base_decimals` | 1 human unit |
|---|---|---|---|
| BTC | satoshi | 8 | 100 000 000 |
| ETH | wei | 18 | 1 000 000 000 000 000 000 |
| USDT | micro-USDT | 6 | 1 000 000 |
| SOL | lamport | 9 | 1 000 000 000 |

`numeric(38,0)` rather than `bigint` because one ETH in wei (1e18) already uses most of `bigint`'s range
plus we need headroom for millions of ETH.

Quantities are in base-asset base units. Prices need a scaling rule, and the one chosen here keeps the
matching arithmetic exact:

```
price_units = price (quote per one WHOLE base asset) × 10^markets.price_scale
qty_units   = quantity in base-asset base units
quote_units = trunc(qty_units × price_units / 10^notional_scale)
notional_scale = price_scale + base_decimals − quote_decimals     (derived by trigger)
```

Worked example, BTC/USDT (`base_decimals` 8, `quote_decimals` 6, `price_scale` 8):

```
0.00060000 BTC at 60,000.00 USDT/BTC
  qty_units   = 60000            (0.0006 BTC = 60 000 satoshi)
  price_units = 6000000000000    (60000.00 × 10^8)
  notional_scale = 8 + 8 − 6 = 10
  quote_units = trunc(60000 × 6000000000000 / 10^10) = 36000000   (36.000000 USDT)  ← exact
```

`notional_scale` is computed by a trigger on `markets` (`markets_set_notional_scale`), never hand-written,
and a negative value (quote asset with too few decimals for the pair) is rejected at insert time. The two
helper functions `notional_units(...)` and `price_units_from_notional(...)` are the only place that
rounding happens; everything else is addition/subtraction of integers. Rounding is truncation toward zero,
always in the exchange's favour on fees (documented here so the engine can implement it consistently).

**Boundary rule — fractional input is rounded, not rejected.** Amount columns are `numeric(38,0)`, so
PostgreSQL rounds a fractional value to the nearest integer unit on insert (60000.5 satoshi is stored as
60001). The stored value is always a whole number of base units — the ledger property that matters — but a
client that sends decimals loses the fraction silently. The API layer must therefore parse amount fields as
**integers** (JSON strings to bigint/numeric), and the tick/step validation only ever sees integers. If loud
rejection at the database boundary is preferred, the alternative is plain `numeric` columns with
`CHECK (x = trunc(x))` instead of `numeric(38,0)` — an open decision, see section 7.

**Display** is the frontend's job: `human = amount_units / 10^base_decimals`, formatted as a decimal
string. API responses must return these as JSON **strings**, not numbers — a JS `number` round-trip is how
an exchange silently loses satoshis.

---

## 3. Ledger — why it is trustworthy

- **Double entry.** Every `ledger_transactions` row has ≥2 `ledger_entries` on ≥2 distinct accounts,
  and the entries **sum to zero per asset**. A user credit is always balanced by a system debit, so
  `SUM(all entries per asset) = 0` holds globally and user liabilities can be reconciled against system
  accounts.
- **Append-only, enforced twice.** (1) `UPDATE`/`DELETE`/`TRUNCATE` on `ledger_entries`,
  `ledger_transactions`, `trades` and `order_events` are **revoked from `PUBLIC`, `anon`,
  `authenticated` and `service_role`** — including `service_role`, which is unusual on purpose. (2) A
  `BEFORE UPDATE OR DELETE` trigger (`reject_mutation`) raises `restrict_violation` for every role,
  including the table owner. Bypassing it requires dropping the trigger or
  `session_replication_role = replica`, both of which need ownership/superuser and are logged.
- **Corrections are new rows.** A mistake is fixed by a compensating transaction
  (`type='correction'`/`withdrawal_refund`, opposite signs) referencing the original via
  `reverses_transaction_id`. History is never edited.
- **Invariants checked at COMMIT** by two deferred constraint triggers, so they hold even inside a big
  in-database matching transaction:
  - `ledger_entries_balanced` — each transaction is zero-sum per asset, has ≥2 distinct accounts, and no
    entry's `environment` differs from its transaction's.
  - `balances_match_ledger` — a `balances` row may only differ from `SUM(ledger_entries)` for its account
    if the ledger rows for that difference are written in the **same transaction**. A bare
    `UPDATE balances SET available_units = …` fails at commit with `balance drift on account …`.
- **A posting's asset/environment can never disagree with its account**: `ledger_entries` has a composite
  FK `(account_id, asset_id, environment) → accounts(id, asset_id, environment)`, so a mixed-currency
  posting is impossible at the constraint level.
- **Idempotency**: `ledger_transactions.idempotency_key` is unique when set; `orders` has a unique
  `(user_id, market_id, client_order_id)`; `orders.hold_*` records exactly one hold per order.
- **Reconciliation**: `v_account_reconciliation` compares the cache against the ledger per account. Run it
  (or a scheduled job asserting `drift_units = 0` everywhere) before real money is enabled.

### Atomicity for the future in-DB matching engine

Every invariant above is satisfied inside a single transaction, which is what the architecture calls for:
one `BEGIN … COMMIT` that (a) inserts the `orders` row, (b) writes hold entries + updates both
`available_units`/`locked_units` rows, (c) inserts `trades` rows, (d) moves funds with `trade_fill`/fee
entries, (e) appends `order_events`. If any step fails, the deferred triggers abort the commit and nothing
is partially applied. The engine will be a `SECURITY DEFINER` function owned by the migration role (RLS
does not apply to the owner), called over PostgREST RPC or from an edge function — never written to
directly by a browser.

---

## 4. RLS model (strict, and deliberately unlike the chat tables)

| Role | Access |
|---|---|
| `anon` | **Nothing.** No policy and `REVOKE ALL` on every exchange table and view. A visitor holding the public anon key can neither read nor write balances, orders, ledger rows or reference data. |
| `authenticated` | **SELECT only**, and only where a policy allows: reference data (`assets`, `markets`, `app_settings`), plus own rows in `accounts`, `balances`, `ledger_entries`, `ledger_transactions`, `orders`, `order_events`, `trades` (own = `user_id = auth.uid()`, or the account/order belongs to them, or they are taker/maker of the trade). No `INSERT`/`UPDATE`/`DELETE` policy exists for any exchange table, so client writes are denied by RLS regardless of grants. |
| `service_role` | Bypasses RLS. `SELECT + INSERT` on everything; `UPDATE`/`DELETE` only where per-row mutation is legitimate (`orders`, `balances`, `accounts`, `assets`, `markets`, `app_settings`). The append-only tables get no `UPDATE`/`DELETE` at all. |

Because Supabase grants `ALL` on new tables in `public` to `anon`/`authenticated`/`service_role` by
default, migration 5 explicitly **revokes first and re-grants the minimum** on every table.

This is the opposite of the existing chat tables (`chat_conversations`/`chat_messages` are world-readable
and world-writable with `USING (true)`) — that is acceptable for a public support widget but must never be
copied into money tables. Public market data (the landing-page ticker) is therefore **not** exposed here:
it needs a sanitised read model served by an edge function with the service role (see §7).

Identity is always `auth.users.id`, taken from the verified JWT server-side. A client-supplied user id is
never trusted, and there is no `kyc_status` column on `accounts` — KYC belongs to the identity layer, so a
KYC state change can never touch a money row.

---

## 5. Paper / live flag

- `app_settings.mode` (`paper` | `live`) is the durable switch. The seeded row is `paper`; the table can
  only ever hold one row.
- Flipping to `live` also requires `live_trading_enabled = true` **and** `live_enabled_at IS NOT NULL`
  (`app_settings_live_gate_check`), so the switch cannot be flipped by a single careless value.
- **Every money row carries `environment`** (`accounts`, `ledger_transactions`, `ledger_entries`,
  `orders`, `trades`, `markets`), and it is part of the uniqueness keys — paper and live balances can
  never share a row.
- **The gate is enforced in the database, not in React.** A `BEFORE INSERT` trigger
  (`enforce_environment_gate`) on `accounts`, `ledger_transactions`, `orders` and `trades` rejects any
  `environment = 'live'` row while `mode <> 'live'`, or while the relevant feature flag
  (`live_trading_enabled` / `deposits_enabled` / `withdrawals_enabled`) is off.
- Paper mode is funded from the seeded `PAPER_FAUCET` system account via `paper_funding` /
  `admin_adjustment` transactions, so paper trading exercises the same engine and the same ledger without
  touching real funds.
- `authenticated` can read `app_settings` so the UI's "demo mode" labels can be driven by the real flag
  instead of hardcoded strings.

---

## 6. What the frontend needs from this (contract notes)

| Frontend surface | What the schema gives it | Still missing (later layers) |
|---|---|---|
| `Trade.tsx` limit order form | `markets` (tick/step/min sizes, fees), `orders` shape, price/quantity in integer units | `place_order`/`cancel_order` RPCs, order book view, market stats, candles |
| `Trade.tsx` order book panel | `orders_book_idx` (partial index on resting orders) | aggregated depth read model |
| `Withdraw.tsx` balance | `v_my_balances` (`available_units`) | withdrawal requests, fee columns are NULL until configured |
| `MyBalance.tsx` / dashboard `BalanceCard` | `v_my_balances` (per-asset rows, available/locked/total) | USD valuation needs a price/stats table (deliberately not in this scope) |
| `Deposit.tsx` (crypto) | `assets.chain`, `contract_address`, per-asset min/fee columns (all NULL = unconfigured) | `deposit_addresses`, deposit intents, chain watcher |
| Admin panel | `orders`, `trades`, `ledger_*`, `v_account_reconciliation` readable with the service role | admin RPCs, audit log, status transitions |
| Realtime (`user:balances:<id>`, `markets:orderbook:<id>`) | — | publication changes + throttled read models are a later step; nothing was added to `supabase_realtime` here |

`trades`/`orders` rows **must be sanitised before anything public** (no `taker_user_id`/`maker_user_id`) —
the UI must never receive counterparty identity.

---

## 7. Deliberate scope limits and decisions to confirm

1. **No anon read access to `markets`/`assets`.** The public landing page's ticker currently shows mock
   data; serving real prices to anonymous visitors needs a sanitised endpoint (edge function with the
   service role). Building that here would have required a `USING (true)` policy on exchange tables,
   which the strict-RLS decision rules out. **Confirm the intended public read path** (edge function vs a
   dedicated `public_market_stats` table with an anon policy).
2. **`markets` is in scope** even though the brief listed `orders`/`trades` — orders cannot exist without
   a pair, precision and fee configuration. Kept minimal.
3. **No `order_holds` table**: one hold per order is stored on `orders` (`hold_amount_units`,
   `hold_released_units`, `hold_account_id`, `hold_transaction_id`), so there is exactly one place that can
   disagree with the ledger.
4. **No `profiles` table here.** KYC status, referral code, name/country, notifications and the
   `auth.users` link belong to the identity layer (the brief called `kyc_status` a placeholder; putting it
   on the identity table rather than `accounts` keeps KYC and money independent). `accounts.user_id`
   references `auth.users(id)` directly.
5. **User deletion is restricted, not cascaded**: `accounts.user_id` uses `ON DELETE RESTRICT` and the
   ledger references accounts with `RESTRICT`, so deleting an `auth.users` row with money history fails.
   Users must be closed/soft-deleted (status on the profile), never hard-deleted.
6. **Deposit/withdrawal/KYC/admin tables are not created here** — that is the next layer. System accounts
   for chains (`EXTERNAL_DEPOSIT`, `EXTERNAL_WITHDRAWAL`) are named but not seeded.
7. **`app_settings` also holds the future feature flags** (`deposits_enabled`, `withdrawals_enabled`), so
   the deposits layer can reuse the same gate trigger. No cron/worker, no `pg_cron` job is created here.
8. **Views need PostgreSQL 15+** (`security_invoker`). Supabase runs 15+; the check is isolated to
   migration 6 so the tables apply regardless.
9. **Not touched:** the `dist/` bundle, the frontend, `admin-chat`, `chat_*`, `admin_users`, and the
   existing 5 migrations.
10. **SQL detail to confirm:** fractional amounts round into `numeric(38,0)` instead of being rejected
    (see section 2). Switching to plain `numeric` plus `CHECK (x = trunc(x))` would make the database loud
    about decimals; it costs the typmod's clear intent. Flagged for the lead, not changed.
11. **The verification harness is committed** under `supabase/tests/` (scratch-Postgres recipe against a
    Supabase stub). It is not wired into CI and must never be pointed at the live project.

## 8. Verification status

**Applied and exercised on a scratch PostgreSQL 16.15** — nothing was deployed to Supabase.

- All six files apply cleanly, in filename order, to an empty database that mimics Supabase (the
  `anon`/`authenticated`/`service_role` roles, `auth.uid()`, the `supabase_realtime` publication, and the
  default `GRANT ALL` on new `public` tables that makes the RLS tests meaningful).
- They also apply cleanly **on top of the five existing chat/admin migrations** in one database, and the
  existing behaviour is unchanged afterwards: the 5 chat policies (anon included) are still there, anon can
  still read `chat_conversations`, `admin_users` is still seeded.
- `supabase/tests/exchange_schema_tests.sql`: **112 assertions, 0 failures** — reference data and derived
  precision, exact integer money math, RLS (anon denied everywhere, `authenticated` sees only its own rows,
  no client write path), append-only enforcement through both privilege and trigger, the paper/live gate,
  order validation, balance guards and optimistic locking.
- `supabase/tests/exchange_ledger_invariant_tests.sql`: the four deferred-invariant violations are rejected
  at COMMIT with the intended messages, the control transaction commits, and post-conditions hold (no orphan
  rows, no drift, ledger sums to zero).
- **Two schema problems were found and fixed by this exercise** (they are in the migrations as pushed):
  1. a plain `CHECK (available_units >= 0)` on `balances` made double-entry impossible, because the system
     counterparty account (`PAPER_FAUCET`, and later the chain wallets) has to go negative to fund a user.
     Replaced by the `balances_before_write` trigger, which keeps the rule for user accounts.
  2. the ledger/balance invariant was one-directional: a balance could not move without ledger rows, but
     ledger rows could be written without moving the cache. A deferred check now rejects that too.
- **Not verified:** application to the real Supabase project, and any behaviour of the future matching
  engine, order-placement RPCs or edge functions — none of those are built here.
