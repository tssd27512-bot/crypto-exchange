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
| `app_settings` | One-row global switch. Holds the paper/live `mode` and the feature flags. Physically limited to one row by `CHECK (id)`. | `mode`, `live_trading_enabled`, `deposits_enabled`, `paper_deposits_enabled`, `withdrawals_enabled`, `live_enabled_at` |
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
- **The paper deposit path has its own switch.** `app_settings.paper_deposits_enabled` (default
  **true**) gates the paper sandbox only: while it is false, `record_deposit()` and
  `credit_deposit()` of a paper-environment deposit are refused with their own distinct message.
  It never opens or closes the live path, and `deposits_enabled` never opens or closes the paper
  path — see the deposits section for the two switches side by side.
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

---

## 9. Matching engine (migration 7) and order book reads (migration 8)

**Status: built and exercised on a scratch PostgreSQL; not deployed.**

### Order lifecycle

`new` -> (`partially_filled`) -> `filled` | `canceled` | `rejected`.
There is no separate `open` status: an order is open while it is `new` or
`partially_filled`, which is what the `orders_book_idx` partial index matches.

- a **limit GTC** order rests in the book;
- a **market** order (and any IOC) fills against the best opposite side and the
  unfilled remainder is then cancelled with `cancel_reason='insufficient_liquidity'`
  — fill-what-is-available, cancel-the-rest, deterministically;
- a **FOK** order is pre-checked against the book and, if the whole quantity is
  not fillable, stored as `rejected` / `reject_reason='fok_not_fillable'` with no
  hold and no ledger rows at all.

### Entry points

| Function | Granted to | Notes |
|---|---|---|
| `place_order(market_symbol, side, type, qty_units, price_units, tif, client_order_id, user_id) -> jsonb` | `authenticated`, `service_role` | validates, holds, inserts, matches — one transaction |
| `cancel_order(order_id, reason, user_id) -> jsonb` | `authenticated`, `service_role` | open orders only, releases the remaining hold |

Everything else (`match_order`, `settle_fill`, `close_order`, `post_entry`,
`book_fillable`, `order_result`, `ensure_user_account`, `system_account_id`,
`assert_trading_enabled`, `resolve_order_actor`) is `REVOKE`d from `PUBLIC`,
`anon`, `authenticated` and `service_role`; only the function owner (the
migration role) and the two entry points use them. All are `SECURITY DEFINER`
owned by the migration role, so RLS does not apply to them.

**Identity.** `auth.uid()` decides the actor. A caller with a JWT may only act
for themselves (`user_id` must be NULL or equal to the JWT subject); a caller with
no JWT (server-side / `service_role`) must pass the user explicitly. The identity
is never taken from the request body, and a JWT-holding caller passing somebody
else's id is refused (`T11.3`).

**Amounts.** All quantities and prices are integer base units. Fractional input
is **rejected loudly** ("fractional amounts are rejected, not rounded") at the
`place_order` boundary — the stronger guarantee the API needs, since `numeric(38,0)`
columns would otherwise round 0.5 satoshi to 60001 silently (SCHEMA.md §2).

### Matching algorithm

Price-time priority: **best price first, then earliest `created_at`** (id as the
tie-breaker). The incoming order is the taker, resting orders are makers, and the
fill price is always the **maker's** price. Partial fills are normal. An order
never trades with another order of the same user (self-match prevention), and the
same rule is applied by the pre-trade liquidity scan, so the plan and the fills
agree. Balance rows are locked in `account_id` order inside every fill so two
fills touching the same accounts cannot deadlock.

### Holds

Placement holds the money the order can spend:

| Order | Hold |
|---|---|
| sell | `qty_units` of base, available -> locked |
| buy limit | `notional(qty, limit price)` + worst-case fee, available -> locked |
| buy market | what the visible book can actually take (`book_fillable`) + worst-case fee |

`orders.hold_released_units` counts everything no longer locked for the order
(spent on fills **and** returned on close), so `hold_amount_units -
hold_released_units` is exactly what is still locked, and the pre-trade hold can
never be exceeded by the fills: per-fill truncation is monotone, so the sum of
per-fill claims is <= the claim computed on the whole quantity. A hold the user
cannot afford is refused **before** the order row exists (`T4.1`), and a fill that
cannot overdraw the locked balance is additionally refused by the
`balances_before_write` trigger from migration 2.

### Settlement and the ledger

Each fill is **one** `ledger_transactions` row of type `trade_fill` plus the
entries below, written through `post_entry` — the single function that appends a
ledger row *and* moves the matching cached balance in the same statement, which is
what makes the deferred invariants of migration 3 impossible to break by engine
code:

```
buyer  locked    <quote>  -(notional + buyer_fee)
seller locked    <base>   -qty
buyer  available <base>   +qty
seller available <quote>  +(notional - seller_fee)
FEE_INCOME available <quote> +(buyer_fee + seller_fee)
```

Zero-sum per asset, >= 2 distinct accounts, both directions of the balance
invariant satisfied — asserted per fill and globally in the tests (`T8.*`).
Fees are charged in the **quote** asset at `markets.maker_fee_bps` /
`taker_fee_bps` (2/5 bps by default), truncated toward zero in the exchange's
favour, and recorded on the immutable `trades` row together with the ledger
transaction that settled it. Paper funding uses the same ledger path from
`PAPER_FAUCET`; nothing in the engine invents a balance.

### Mode gate

`place_order`, `cancel_order` and `settle_fill` all call
`assert_trading_enabled()`, the one place the mode is read: in paper mode
(`mode='paper'`, the default) trading must be enabled by `paper_trading_enabled`,
in live mode by `live_trading_enabled`, otherwise the engine raises and stays
inert. Orders are always written to the environment that `app_settings.mode`
names, so while the exchange is in paper mode no order, trade or ledger row can
exist in `live` (the migration-1 `enforce_environment_gate` trigger enforces this
independently, and `T9.*` covers both). Fine-grained `LIVE_*` wiring is step 12.

**Flagged for the lead:** `cancel_order` is gated like the other money movers, per
the brief, which means pausing trading also prevents users from releasing their
own holds. If that is not wanted, the single `assert_trading_enabled()` call in
`cancel_order` is the line to drop.

### Order book and market data reads

`v_markets`, `v_order_book_depth` (aggregated levels + cumulative quantity),
`v_order_book_best` (best bid/ask, spread, last price) and `v_market_stats_24h`
(trade count, open/last/low/high, base and quote volume over 24h). `authenticated`
and `service_role` only; `anon` revoked.

These four are deliberately **owner-run** (no `security_invoker`), unlike
`v_my_balances`: under `security_invoker` the RLS policies on `orders`/`trades`
would silently reduce the book to "my own orders". The property that matters is
preserved by construction instead — **no user id, account id or order id is
exposed** (asserted in `T12.4`).

## Deposit layer (step 6 — owner statuses, provider-adapter contract, paper vs live)

`deposits`, `deposit_addresses`, `deposit_networks`. Statuses are exactly the owner's five:
`pending`, `confirming`, `confirmed`, `failed`, `under review`. **Crediting is data, not a
status**: `credit_deposit()` posts the ledger transaction and writes
`credited_ledger_transaction_id` + `credited_at` on the still-`confirmed` row in one call
(`CHECK (credited_at IS NULL OR (status = 'confirmed' AND confirmations >= required_confirmations))`),
and it only accepts a `confirmed` deposit — a deposit `under review` or below its policy is
refused with a specific message.

State machine, enforced by the `deposits_before_update` trigger:

| from | to |
|---|---|
| `pending` | `confirming`, `confirmed`, `failed`, `under review` |
| `confirming` | `confirmed`, `failed`, `under review` |
| `under review` | `confirmed`, `failed` |
| `confirmed` | `failed`, only while the row is **not credited** (a credited row can never leave `confirmed` — `deposits_credit_state_check`) |
| `failed` | terminal |

Mapping from the earlier draft of this migration (never deployed anywhere):
`detected → pending`; `confirming → confirming`; `credited → dropped as a status, credit
data on a `confirmed` row`; `cancelled → failed + failed_reason`; `orphaned → failed +
failed_reason`; `reorged → failed + failed_reason`.

Entry points (all `service_role` only; `anon`/`authenticated` hold no privilege and no policy
on these three tables): `record_deposit` (paper), `record_provider_deposit` (live adapter),
`set_deposit_confirmations`, `confirm_deposit`, `set_deposit_under_review`, `fail_deposit`,
`credit_deposit`. A deposit below its policy, a disabled network, a network with
`min_deposit_units IS NULL` and a network with `required_confirmations = 0` (treated as "no
confirmation policy configured" — a deliberate strictness) are each refused before any money moves.

### Provider adapter contract

The live path depends on one function, not on a provider:
`record_provider_deposit(p_event jsonb) returns uuid`. The adapter normalises one provider
event into one JSON object:

| event key | required | deposits column | rule |
|---|---|---|---|
| `network` | yes | `network` | must be registered for (asset, live) in `deposit_networks` |
| `asset_symbol` | yes | `asset_id` | must exist in `assets` |
| `user_id` | yes | `user_id` | must exist in `auth.users` |
| `txid` | yes | `txid` | non-blank, part of the chain key |
| `amount_units` | yes | `amount_units` | positive whole number of base units |
| `log_index` | no | `log_index` | default -1 (native transfer) |
| `confirmations` | no | `confirmations` | default 0; drives pending/confirming/confirmed |
| `to_address` | no | `address` | recorded as reported, never verified here |
| `memo` | no | `memo` | required when `deposit_networks.requires_memo` |
| any extra key | no | `raw` | kept verbatim for audit |

A missing key, a wrong type or a non-object event raises an adapter contract violation
(`invalid_parameter_value`) and records nothing. The function refuses to run unless
`app_settings.mode = 'live'`; it then passes the `LIVE_DEPOSITS_ENABLED` gate
(`app_settings.deposits_enabled`, still **false** in the repo) and the migration-1
`enforce_environment_gate` trigger. No provider, credential, generated address or
confirmation source exists in this step — the adapter is not implemented.

### Paper vs live separation

| `source` | `environment` | entry point |
|---|---|---|
| `paper_operator` | `paper` | `record_deposit()` — refused while `mode = 'live'` |
| `provider_adapter` | `live` | `record_provider_deposit()` — refused while `mode <> 'live'` |

`CHECK ((source = 'provider_adapter') = (environment = 'live'))` pins the pairing, so which
path produced a deposit is visible in the row and the two paths cannot be mixed in either
direction. Paper deposits are never represented as chain-verified.

### The two deposit switches (owner directive: paper deposits get their own control)

| switch | default | what it gates | refusal message |
|---|---|---|---|
| `deposits_enabled` | **false** | the LIVE path only, and only while `mode = 'live'` — the DB side of `LIVE_DEPOSITS_ENABLED`; `enforce_environment_gate` refuses a live row independently | `live deposits are disabled: ...` |
| `paper_deposits_enabled` | **true** | the PAPER path only: `record_deposit()` and `credit_deposit()` of a paper-environment deposit, via `assert_paper_deposits_enabled()` | `paper deposits are disabled: ...` |

Neither switch can substitute for the other: with the paper switch ON and the exchange in
paper mode, a live deposit row is still refused, and with the live switch ON the paper
operator path is still refused outside paper mode. The paper switch defaults ON because paper
is the non-money sandbox; the live switch defaults OFF because it moves real funds. Both are
asserted in both directions in the scratch suite (D6 for the live switch, D7 for the paper
switch, every flip reverted before the suite ends).

**Flagged for the lead:** (1) the paper path is gated by its own switch
(`paper_deposits_enabled`, default true), not by `deposits_enabled` — that flag is the DB side
of `LIVE_DEPOSITS_ENABLED` and gates the live path only (both switches asserted in both
directions in the scratch suite); (2) `required_confirmations = 0` is
refused as "no policy configured", which is stricter than treating 0 as "credit on sight";
(3) a confirmed-but-uncredited deposit can still be failed by an operator, but a credited one
cannot — reversal needs a compensating ledger transaction, out of scope here.

## Withdrawal layer (step 7 — status machine, hold/release, fee model, paper vs live)

Migration: `20261005100130_exchange_withdrawals.sql`. Tables: `withdrawal_networks`
(per asset × network × environment configuration, nothing seeded) and `withdrawal_requests`
(one row per requested withdrawal). Money only ever moves through the ledger: approval
posts one `withdrawal_request` hold, completion posts one `withdrawal_settle`, closing posts
one `withdrawal_refund`. No balance is ever written outside those transactions.

### Status mapping (owner-facing statuses → database state)

| owner-facing | `withdrawal_requests.status` | notes |
|---|---|---|
| requested | `pending` | created by `record_withdrawal_request()` (paper) or `record_provider_withdrawal()` (live) |
| under review | `under review` | operator hold, `review_reason` mandatory |
| approved (queued) | `approved` | the hold is placed here — funds are locked at approval, not at broadcast |
| broadcasting / sent | `processing` | `provider_txid` is required to enter it and is recorded on the row |
| completed | `completed` | settled: `settled_ledger_transaction_id` + `completed_at` set |
| failed | `failed` | terminal, reason mandatory, hold released |
| rejected | `rejected` | terminal, reason mandatory, hold released |

### State machine (enforced by the `withdrawal_requests_before_update` trigger)

```
pending ──► under review ──► approved ──► processing ──► completed
   │             │              │             │
   └─────────────┴──► rejected  └────► failed ◄┘
```
* `pending → under review → approved → processing → completed` is the only forward path;
  skipping `processing` is refused (`approved → completed` raises through the entry point).
* Only `pending` / `under review` can become `rejected`. From `approved` / `processing` the
  only closing edge is `failed` — a broadcast that already went out is a FAILURE, not a
  rejection. `reject_withdrawal()` therefore refuses an approved/processing row (its
  COMMENT says so and points at `fail_withdrawal()`).
* `completed`, `failed`, `rejected` are terminal: no status change, no edit of the
  settlement/hold/release pointers, no edit of amount/destination (row identity).
* Timestamp columns record *when things happened*, so the CHECKs are one-directional on
  purpose: a row in `approved/processing/completed` MUST carry `approved_at`; a row in
  `processing/completed` MUST carry `processing_at`; a row in `failed/rejected` MUST carry
  `closed_at`. A closed row KEEPS `approved_at`/`processing_at` as audit facts — the first,
  bidirectional form of `withdrawal_requests_approved_at_check` and
  `withdrawal_requests_processing_at_check` made closing an approved (or broadcast) request
  impossible, which is what this step fixed.

### Fee model

`fee = withdrawal_fee_flat_units + floor(amount_units × withdrawal_fee_rate_bps / 10000)`,
in integer base units, charged **on top** of the amount (the user needs amount + fee).
One implementation — `_withdrawal_fee_units()` — with `quote_withdrawal_fee(asset, network,
amount)` as the read-only wrapper clients may call (authenticated). The fee is
**snapshotted** into `withdrawal_requests.fee_units` at creation, so reconfiguring a network
never changes an existing request. `min_withdrawal_units` / `max_withdrawal_units` bound the
REQUESTED amount, not amount + fee, and are NOT NULL (a network cannot be registered without
limits). Worked examples from the suite: BTC paper (flat 1000, 50 bps) → 1,000,000 units
costs 1000 + 5000 = **6000**; the live BTC registration mirrors it, so a 100,000-unit live
event costs 1000 + floor(500) = **1500**; SOL (flat 5000, 10 bps) → 50,000 units = 5050.

### Settlement and release postings

* approval: `withdrawal_request` — available −(amount+fee) → locked +(amount+fee).
* completion: `withdrawal_settle` — locked −(amount+fee), `WITHDRAWAL_CLEARING` +amount,
  `FEE_INCOME` +fee (fee posting omitted when the fee is 0). One transaction, zero sum.
* failure/rejection: `withdrawal_refund` — locked −(amount+fee) → available +(amount+fee),
  recorded in `released_ledger_transaction_id`. A request that was never approved releases
  nothing. The `withdrawal_release` type does not exist in the ledger's CHECK, so the release
  posts as `withdrawal_refund` and says what it is in description/metadata (flagged).

### The two withdrawal switches (per-mode, both tested in both directions)

| switch | gates | default |
|---|---|---|
| `app_settings.withdrawals_enabled` + `mode = 'live'` | live requests through the provider adapter (`assert_withdrawals_enabled()`) and any live row (`enforce_environment_gate` trigger) | `false` |
| `app_settings.paper_withdrawals_enabled` | paper request creation, paper approval (holding money), paper settlement | `true` |

Deliberate: neither switch gates `fail_withdrawal()` / `reject_withdrawal()`, so switching a
mode off can never trap funds that are already locked. Both switches are flipped only in
scratch databases in the suite and reverted there (`W8`, `W8b`, `W8c`, `W11`).

### Provider adapter contract (live path)

`record_provider_withdrawal(p_event jsonb) RETURNS uuid` — the only live entry point. Required
keys `network`, `asset_symbol`, `user_id`, `destination_address`, `amount_units`; optional
`destination_tag`, `memo`, `provider_txid`; any extra provider fields are preserved verbatim
in `withdrawal_requests.raw`. A malformed event is refused as an adapter contract violation
and NOTHING is recorded. The row is always `source = provider_adapter`, `environment = 'live'`
(pinned by CHECK), and the live network row must have been registered in the LIVE environment
(`register_withdrawal_network()` writes to the current `app_mode()`). The adapter itself —
broadcasting, signing, key management, polling, confirmations — is NOT implemented in this step.

### Flagged decisions (owner)

1. Destination whitelisting / per-chain address validation / travel rule: not implemented.
   The destination is only checked non-blank, no whitespace, 4–200 chars, and the
   (asset, network) pair must be registered. The `under review` state is the hold hook it
   will need.
2. Release ledger type: releases post as `withdrawal_refund` (no `withdrawal_release` type).
3. Reversal of a settled withdrawal: not implemented — it needs a compensating ledger
   transaction; `fail_withdrawal()` refuses a settled row instead of silently reversing.
4. Custody model (networks, hot/cold) and fee accounting beyond `FEE_INCOME` (network fee vs
   service fee split) are open — see the plan's open decisions 2 and 4.

### Verification status

`tests/exchange_withdrawal_tests.sql` runs last in the shared scratch core database:
**181/181 PASS, 0 FAIL** (run 5, `tests/run_scratch_suites.sh`, runner exit 0) covering the
network configuration, fee model and rounding, request validation, holds, the state machine,
settlement and provider-txid idempotency, the release paths, both switches in both
directions, the adapter contract, the anon/authenticated/service_role matrix, and the
end-of-suite settings snapshot. Nothing here has been applied to the live Supabase project.

## KYC layer (step 8 — tier model, provider-adapter contract, no PII, security audit)

Migration `20261005100140_exchange_kyc_security.sql`. **Provider-agnostic by design:** no vendor
is integrated, selected or referenced, and no credential, document store or API key exists in
this repo. Vendor selection is the owner's open decision #1.

**No money path is gated on KYC in this migration.** The money layers (deposits, withdrawals,
trading) do not read any KYC table; `app_settings.kyc_required_for_trading` still exists,
still defaults to `false` and is untouched.

### Tier model (`kyc_levels`)

| level | name | meaning |
|---|---|---|
| 0 | `unverified` | default for every user; no identity check performed |
| 1 | `identity` | an identity document was checked by an operator or a provider |
| 2 | `address` | identity plus proof of address checked |

Reference data only — `(level, name, description)`. **Per-tier limits are deliberately absent:**
withdrawal caps, deposit caps and trading caps depend on the custody model and the vendor, so
they are an OWNER decision. There is no limit column, no `limits` jsonb and no implied policy;
the suite pins this (`K1`).

### Per-user status (`kyc_status`)

One row per user, materialised at level 0 on first reference (`ensure_kyc_status()`, and
`my_kyc_status()` for a signed-in user). `provider` stays NULL until a vendor is chosen.

The level follows approvals, and that is a **database invariant**, not a convention: the
`kyc_status_before_update` trigger refuses (a) any level that has no `approved` submission for
that user and level, (b) any downgrade, (c) any change of owner. So `UPDATE kyc_status SET
level = 2` by hand fails even for `service_role`.

### Submission state machine (`kyc_submissions`)

```
pending --> under review --> approved | rejected
   |                              |
   +----------> approved | rejected
approved  --> (terminal)     rejected --> (terminal)
```

- `pending → approved` (straight through) and `pending → under review → approved` are both
  allowed, exactly as in the withdrawal layer: **whether review is mandatory (or only above a
  threshold) is an owner policy decision** and is not invented here.
- `approved` means the level was granted; `rejected` leaves the level untouched. Both are
  terminal and immutable (trigger), so **resubmission is always a new row** and the old row
  stays as evidence.
- The identity of a row (user, level sought, environment, source) and the provider idempotency
  pair are immutable; an approved/rejected row refuses every `UPDATE`.

### No personal data in the database (enforced, not just documented)

| stored here | NOT stored here |
|---|---|
| opaque references: document id, content hash, vendor applicant id, provider reference | names, dates of birth, e-mail/phone, postal addresses, national ID/passport numbers, documents (images/PDFs/base64), selfies, signatures, bank details |

The document bytes belong to whatever the future vendor stores; **the storage location is part
of the vendor decision and is deliberately not decided here.** The rule is enforced by
`_kyc_pii_key_path()` + the `kyc_metadata_guard` trigger, which walks `metadata`/`raw`
recursively and refuses a denylisted key with the path of the offending field
(`K7`, `K8e`). A careless operator or adapter cannot turn this table into a PII store.

### Paper vs live: two paths

| source | environment | entry points | who calls it |
|---|---|---|---|
| `paper_operator` | `paper` | `submit_kyc()`, `set_kyc_under_review()`, `approve_kyc()`, `reject_kyc()` | operator / test harness, paper only |
| `provider_adapter` | `live` | `record_provider_kyc_event()` | the live KYC provider adapter |

Pairing is pinned by CHECK and by `assert_kyc_path()` in **both** directions: the operator path
raises while `app_settings.mode = 'live'`, the adapter path raises unless `mode = 'live'`
(`K9`). Deliberate: KYC carries no money, so it has **no `app_settings` flag** and the
`enforce_environment_gate` trigger is NOT attached to these tables (a live KYC row must not
require live trading). The mode is the only switch, and no `app_settings` column is added.

### Provider adapter contract

`record_provider_kyc_event(p_event jsonb) RETURNS uuid`

```json
{ "event_type":           "approve | reject | under_review",
  "user_id":              "<uuid>",
  "submission_reference": "<vendor submission/applicant id>",
  "provider":             "<vendor name>",
  "level_sought":         1,
  "reason":               "<free text>",
  "metadata":             { "provider_applicant_ref": "..." } }
```

Required: `event_type`, `user_id`, `submission_reference`. Optional: `provider`, `level_sought`
(**required when the event creates the row**), `reason`, `metadata`; any extra provider field is
preserved verbatim in `raw`. Idempotency is `UNIQUE (provider, provider_reference)` plus an
explicit guard: replaying a terminal event, or repeating the current status, raises and records
nothing, so a replayed vendor callback can never grant a second level (`K8d`). A non-object
event, a missing key, an unknown `event_type`, a non-uuid user id, a blank reference, an
ambiguous reference, PII in the payload, or a `reject` for an unknown reference is refused as an
adapter contract violation (`K8e`–`K8g`). The adapter itself — HTTP client, signature
verification, polling, webhook handling, document upload — is **not** part of this step.

### Security audit log (`security_audit_log`)

Append-only, using the ledger's `reject_mutation` trigger: `UPDATE`/`DELETE` are refused for
**every** role including the owner, and by privilege for anon/authenticated/service_role (`K10`).
Columns: `at, actor_role, actor_id (nullable), subject_user_id (nullable), action, entity_type,
entity_id, details`.

Exactly one row per KYC submission status change and per KYC level change, written by the AFTER
triggers `kyc_submissions_audit` / `kyc_status_audit` — so **both paths** are audited, including a
privileged update that bypasses the entry points. A row created already decided (the adapter's
straight-through approve) writes two rows: `kyc.submission.submitted` and the decision. The actor
comes from the transaction-local settings `gtvx.actor_role` / `gtvx.actor_id` set by the entry
points (`operator`, `provider_adapter`, else `system`). **`actor_id` is NULL on the operator path
because no operator identity system exists yet** — that is step 9 (admin/operator controls), and
it is flagged rather than faked.

Users read their own rows (`subject_user_id = auth.uid()`); `service_role` reads all; anon has
nothing and cannot forge a row (`K10d`–`K10e`).

### Privileges

| object | anon | authenticated | service_role |
|---|---|---|---|
| `kyc_levels` | — | SELECT (all rows) | SELECT, INSERT, UPDATE |
| `kyc_submissions` | — | SELECT own (`user_id = auth.uid()`) | SELECT, INSERT, UPDATE |
| `kyc_status` | — | SELECT own | SELECT, INSERT, UPDATE |
| `security_audit_log` | — | SELECT own | SELECT, INSERT (never UPDATE) |
| functions | — | `my_kyc_status()` only | every entry point |

No `DELETE` anywhere, and every new function has `REVOKE ALL … FROM PUBLIC, anon, authenticated`
followed by an explicit `GRANT EXECUTE … TO service_role` — the same ACL block pattern as the
withdrawal migration, run last so every signature exists when it resolves (`K11`).

### Flagged decisions (owner)

1. **Per-tier limits** — withdrawal/deposit/trading caps per KYC level: not modelled at all.
2. **KYC vendor** (open decision #1): the whole layer stays provider-agnostic until it is chosen;
   `provider` columns are NULL.
3. **AML / sanctions / PEP screening** — out of scope; provider-dependent and needs a policy.
4. **Document storage location** — TBD with the vendor; only opaque references are stored here.
5. Whether **review is mandatory** for every submission, and who may approve (quorum, SLA) — the
   state machine allows straight-through approval; the admin/operator workflow is step 9.
6. **Level downgrade / expiry / re-verification** — not implemented (a downgrade needs a policy
   for open orders and locked funds). The trigger refuses downgrades rather than allowing them.
7. **Gating money paths on KYC** — nothing is gated; `kyc_required_for_trading` stays `false`.

### Verification status

`tests/exchange_kyc_tests.sql` runs last in the shared scratch core database:
**160/160 PASS, 0 FAIL, 0 psql ERRORs** (`tests/run_scratch_suites.sh`, runner exit 0), covering
the tier model, tier-0 materialisation, both decision paths, the state machine, the level
invariants, the no-PII guard, the adapter contract (including replay refusal), path separation in
both directions, the append-only audit log, the authz matrix and the function ACLs. The five
pre-existing suites stayed green in the same run (matching 63/63, schema 112/0, ledger 5/0 with
exactly 4 expected ERRORs, immutability+RLS 60/60, deposits 173/173, withdrawals 181/181).
**Nothing here has been applied to the live Supabase project.**

## Admin / operator control plane (step 9, part 1 — migration `20261005100150_exchange_admin_operations`)

DB layer only: no edge function, no frontend, nothing deployed.

### Operator identity — how a production request says WHO it is

Operators are rows in the existing `admin_users` table (the table the admin-chat edge function
already logs in against), extended with `operator_role`, `auth_user_id`, `is_active`,
`display_name`, `updated_at`. `username`/`password_hash` are untouched, so `verify_password` /
`update_admin_password` keep working.

`resolve_operator(p_operator_id)` is the single place identity is decided. Two paths:

1. **JWT caller** (`auth.uid()` is not null — a browser holding a GoTrue session): the operator is
   looked up by `admin_users.auth_user_id = auth.uid()`. A caller can only ever be themselves: the
   explicit `p_operator_id` is refused unless it is their own row, and a JWT that maps to no
   operator row is refused. The edge function does nothing special here — it forwards the caller's
   JWT and the server-side call carries no operator id.
2. **service_role caller** (`auth.uid()` is null — an edge function holding the service key): the
   explicit `p_operator_id` argument, else the transaction-local GUC `gtvx.operator_id` that the
   edge function sets after it has verified the admin session. `set_config('gtvx.operator_id', …)`
   is only honoured on this path, so a signed-in customer cannot spoof it with a `set_config` of
   their own.

The edge function that verifies an admin login and then calls these RPCs with the service key is
**not** part of this step. When it is written it must call `set_config('gtvx.operator_id', <id>,
true)` (or pass `p_operator_id`) after its own session check. The parked
`feat/admin-auth-hardening` branch (signed admin tokens, rate limiting) should feed path 2 and
needs no change here.

`assert_operator(action, p_operator_id)` is the guard every admin function starts with: resolve,
check the matrix, refuse a deactivated operator, then stamp `gtvx.actor_role = 'operator'` and
`gtvx.actor_id`, so the audit rows written inside the call (including the PR #6 KYC triggers)
carry a real actor id. **This closes the NULL-actor gap PR #6 left open**: rows written by the old
operator path before this migration still have `actor_id IS NULL`; every row this migration writes
has one, and `log_operator_action()` refuses to write a row when no actor can be resolved rather
than recording NULL.

### Roles and the permission matrix (data, not code)

- `operator_roles`: `superadmin` (4) · `compliance` (3) · `support` (2) · `readonly` (1), with rank
  and description. Rank is reference metadata for UI ordering; **authorisation is the matrix, never
  the rank**.
- `operator_permissions`: 44 rows (4 roles × 11 actions) with an explicit `allowed` per cell —
  no missing cell is possible, and `operator_can()` denies by default (unknown role, unknown action,
  no row).
- Actions: `users.read`, `users.read.pii`, `kyc.read`, `kyc.decide`, `money.read`,
  `restrictions.write`, `risk.write`, `markets.write`, `settings.write`, `operators.write`,
  `security.read`.

| action | superadmin | compliance | support | readonly |
|---|---|---|---|---|
| users.read | ✓ | ✓ | ✓ | ✓ |
| users.read.pii | ✓ | ✓ | — | — |
| kyc.read | ✓ | ✓ | ✓ | ✓ |
| kyc.decide | ✓ | ✓ | — | — |
| money.read | ✓ | ✓ | ✓ | ✓ |
| restrictions.write | ✓ | ✓ | — | — |
| risk.write | ✓ | ✓ | — | — |
| markets.write | ✓ | — | — | — |
| settings.write | ✓ | — | — | — |
| operators.write | ✓ | — | — | — |
| security.read | ✓ | ✓ | — | ✓ |

`users.read.pii` gates the email column in `v_admin_users` (and the email in
`admin_list_users`): the whole column comes back NULL without it.

**Least privilege on upgrade:** `admin_users.operator_role` defaults to `readonly`, so the
pre-existing `admin` row becomes a read-only operator until the owner promotes it explicitly. The
migration raises a NOTICE saying so.

### Sensitive-action audit

Every admin function writes one `security_audit_log` row (`action`, `entity_type`, `entity_id`,
`subject_user_id`, `details.before` / `details.after`) through `log_operator_action()`.
Actions: `admin.restriction.set|cleared`, `admin.risk_flag.added|resolved`,
`admin.kyc.under_review|approved|rejected`, `admin.user.inspected`, `admin.users.listed`,
`admin.security_events.listed`, `admin.market.upserted|fees_changed|status_changed`,
`admin.deposit_network.upserted`, `admin.withdrawal_network.upserted`,
`admin.settings.maintenance_changed`, `admin.operator.role_changed|active_changed`.

The high-volume `v_admin_*` views are **not** audited per row (that would flood the log with one
row per page view); the RPC reads that replace them for list/inspect work are. **Owner decision
worth a look:** whether a per-view audit is needed.

### Account restrictions and risk flags

- `account_restrictions(user_id, scope, reason, set_at, set_by, cleared_at, cleared_by,
  cleared_reason)`, `scope ∈ {trading, deposits, withdrawals}`, one ACTIVE row per user+scope
  (partial unique index), rows are never deleted, clearing sets `active = false` and is audited.
- `risk_flags(user_id, flag_type, severity low|medium|high|critical, note, created_by,
  resolved_at/by/note)` — **advisory only**: a flag blocks nothing, by design.

**Enforcement is in the money paths**, via `assert_account_not_restricted(user, scope)` added to
the five entry points this migration re-creates verbatim (`place_order`, `_deposit_ingest`,
`credit_deposit`, `_withdrawal_ingest`, `approve_withdrawal`). Refusal is
`insufficient_privilege` with a message naming the scope, the reason and the restriction id.

Deliberately **not** gated: `cancel_order`, `close_order`, `release_order_remainder`,
`reject_withdrawal`, `fail_withdrawal`. A restriction must never trap a customer's funds — they
can always cancel and get their hold back, and the operator can always reject/fail a withdrawal.
The tests assert the cancel case explicitly.

### Maintenance mode

`app_settings` gains `maintenance_mode` (NOT NULL DEFAULT false), `maintenance_note`,
`maintenance_set_at`, `maintenance_set_by`. `admin_set_maintenance(on, note)` is the only writer
(needs a note when switching ON, and it touches only the maintenance columns — mode and every
LIVE_* flag are left alone). While ON, `assert_not_in_maintenance(area)` inside the same five entry
points refuses trading / deposits / withdrawals with a distinct message
(`... is in maintenance mode: deposits is temporarily unavailable`). Cancels and withdrawal
rejections stay available for the same reason as above.

### KYC review (reuses PR #6, does not duplicate it)

`admin_kyc_set_under_review` / `admin_kyc_approve` / `admin_kyc_reject` require `kyc.decide`, call
the PR #6 functions (`set_kyc_under_review`, `approve_kyc`, `reject_kyc`) and stamp the actor so
the existing triggers record a real operator. No state machine is reimplemented — a static test
asserts the wrappers never `UPDATE kyc_submissions` / `kyc_status` themselves.

### Read surface (role-scoped)

Views: `v_admin_users` (email gated on `users.read.pii`), `v_admin_balances`,
`v_admin_open_orders`, `v_admin_deposits`, `v_admin_withdrawals`, `v_admin_trades`,
`v_admin_kyc_queue`, `v_admin_restrictions`, `v_admin_risk_flags`, `v_admin_security_events`,
`v_admin_operators`. Each filters through `operator_can_do(...)`, so a caller who is not an
operator (or lacks the action) gets **zero rows**, never an error and never data. `SELECT` is
granted to `authenticated`, revoked from `anon`; the four read-only identity helpers
(`current_operator_id`, `current_operator_role`, `operator_can`, `operator_can_do`) are the only
`EXECUTE` grants to `authenticated`, because PostgreSQL checks function privileges against the
invoking role for a view.

Paginated RPCs: `admin_list_users(limit, offset, search)`, `admin_list_security_events(...)`,
`admin_user_overview(user_id)` (JSON: user, kyc_status, kyc_submissions, balances, open_orders,
restrictions, risk_flags). Indexes `*_admin_created_idx` / `*_admin_status_idx` back the
newest-first pages.

### Administrators can never create customer money

No function in this migration inserts a `balances` row, touches `accounts`, posts a ledger entry or
calls `post_entry` / `settle_fill` / `ensure_user_account` / `system_account_id`. A static probe
over `pg_proc.prosrc` asserts this, and the suite re-checks that every ledger transaction still sums
to zero and every balance still equals its entries afterwards. Configuration (fees, market status,
networks) is writable by superadmin; **money is not**, ever, through this surface.

### ACL summary

- New tables (`operator_roles`, `operator_permissions`, `account_restrictions`, `risk_flags`):
  RLS on with no policy, `REVOKE ALL` from `anon`/`authenticated`, `SELECT/INSERT/UPDATE` to
  `service_role`.
- All 18 `admin_*` functions plus the guards: `REVOKE ALL` from PUBLIC/anon/authenticated,
  `EXECUTE` to `service_role` only. The ACL block runs last in the migration so every signature
  resolves, and it re-asserts the grants on the five replaced money-path functions.

### Deliberate scope limits (for the owner)

- No edge function, no admin UI: this is the DB layer plus the operator-identity contract the edge
  function must implement.
- No operator MFA, no per-IP rate limiting, no operator-session revocation — that is the parked
  auth-hardening branch.
- AML/sanctions/PEP screening still out of scope; `risk_flags` is a manual, advisory record only.
- No money path is gated on KYC, and per-tier limits remain an owner decision.
- Only `admin_users`, `app_settings`, the five money-path entry points and the deposit-suite
  assertion noted below were touched; nothing else in the existing engine changed.
- **One existing test was narrowed** (`exchange_deposit_tests.sql`, "no view exposes deposit
  data"): the operator monitor `v_admin_deposits` is now the one view over that table, so the
  assertion became "the only such view is the operator-only monitor, and it returns zero rows to a
  non-operator". Both halves are asserted.

### Verification

Scratch PostgreSQL 16, migrations applied in order, all suites green (runner exit 0):
matching 63/63 · schema 112/0 · ledger 5/0 with exactly 4 expected errors · immutability+RLS 3/0 ·
deposits 174/174 · withdrawals 181/181 · kyc 160/160 · **admin 171/171**. Nothing applied to the
live project.

## Admin support, communications and status views (stage 2, part 2 — migration `20261005100160_exchange_admin_comms`)

DB layer only: no edge function, no frontend, nothing deployed, no money path re-created.
Every write goes through the stage-2 part-1 guard `assert_operator(action)` and ends in
`log_operator_action(...)`, so the actor is a real operator on every row (JWT callers through
`admin_users.auth_user_id`, service_role callers through `p_operator_id` / `gtvx.operator_id` —
identical to PR #7, no second identity mechanism).

### Support management over the EXISTING chat tables

`admin_list_support_conversations(status, limit, offset)`, `admin_get_support_conversation(id)`,
`admin_support_reply(conversation_id, content)`, `admin_support_set_status(conversation_id, open|closed)`.

They read and write `chat_conversations` / `chat_messages` — the tables the original live-chat
migration created for the visitor widget and the `admin-chat` edge function. Actions are audited as
`admin.support.conversations_listed`, `admin.support.conversation_read`,
`admin.support.replied`, `admin.support.status_changed`.

- A reply is a `chat_messages` row with `sender = 'agent'`, so the visitor sees it through the
  existing widget; a closed conversation refuses a reply until it is reopened.
- Only additive indexes are added to the two chat tables. **No column, constraint, grant or policy
  on them is touched.**

**PARKED OWNER DECISION (flagged, not fixed):** `chat_conversations` and `chat_messages` are still
world-readable and world-writable by `anon` and `authenticated` (3 + 2 policies, `USING (true)`).
That is the original design, it is a live privacy hole (any visitor can read every conversation),
and closing it changes the visitor widget's contract — so this migration leaves it exactly as it is
and the tests assert it is *unchanged* (policy counts 3/2, anon still reads the thread). It needs an
owner decision plus a widget change; it is not something to slip into a DB-only PR.

### Notifications

`notifications(id, user_id, type, title, body, read_at, created_at, created_by)` — `user_id IS NULL`
means a broadcast visible to every signed-in user.

- `admin_send_notification(user, type, title, body)` — `notifications.send` (superadmin,
  compliance, support) → `admin.notification.sent`.
- `admin_broadcast_notification(type, title, body)` — `notifications.broadcast` (superadmin only)
  → `admin.notification.broadcast`, one row with `user_id NULL`.
- RLS: a signed-in user `SELECT`s their own rows **or** broadcasts (`user_id = auth.uid() OR
  user_id IS NULL`); INSERT/UPDATE/DELETE are revoked from `authenticated` and no policy grants
  them, so there is no client write path.
- `user_mark_notification_read(id)` (the only function in this migration granted to `authenticated`)
  marks **the caller's own** row read, idempotently. It refuses another user's row and it refuses a
  broadcast row: per-user read state for a broadcast needs a per-user receipt table, and marking the
  shared row read would lie for every other customer. That receipt table is stage 3.
- Nothing is seeded, generated or faked. An empty table is the honest state.

### Announcements

`announcements(id, title, body, active_from, active_to, created_by NOT NULL, active, created_at,
deactivated_at, deactivated_by)`.

- `admin_create_announcement(title, body, active_from, active_to)` and
  `admin_deactivate_announcement(id)` — `announcements.write` (superadmin only), audited as
  `admin.announcement.created` / `admin.announcement.deactivated`. Deactivation sets
  `active = false` and keeps the row; nothing is ever deleted.
- Public read path `v_public_announcements` (SELECT for `anon` and `authenticated`): only rows with
  `active AND active_from <= now() AND (active_to IS NULL OR active_to > now())`. Zero rows when no
  announcement exists — the view never returns a placeholder.
- The table itself is RLS-on with no policy and is not readable by `anon`/`authenticated`.

### `v_admin_custody` — custody / wallet status (money.read)

One row per SYSTEM account (`PAPER_FAUCET`, `FEE_INCOME`, `EXTERNAL_DEPOSIT`,
`WITHDRAWAL_CLEARING`, …) per asset and environment: `available_units`, `locked_units`,
`balance_units`, the **`ledger_units` sum over `ledger_entries`**, `entry_count`, and `connectivity`.

`connectivity` is the constant `'not_connected'` on every row. **There is no live chain connectivity
in this build**; the view must never imply otherwise, and the suite asserts the value on every row.
Stage 7 (real custody adapters) is the only thing allowed to change it. `balance_units = ledger_units`
on every row is asserted too — this view is the reconciliation-ready input for stage 4.

### `v_admin_liquidity` — liquidity / market-maker monitoring (money.read)

Per market, aggregated from the real book (`v_order_book_depth`): `open_order_count`,
`bid_level_count` / `ask_level_count`, `best_bid_units` / `best_ask_units` (and sizes),
`spread_units` (ask − bid, NULL unless both sides exist), depth inside the **top 5 price levels**
and full depth per side.

**Honest empty state:** a market with no resting orders shows `open_order_count = 0`, NULL best
bid/ask, NULL spread and 0 depth — asserted on a freshly created market before any order exists.
No depth, size or maker is ever fabricated; there is no market maker in this build and the view does
not imply one. The suite also re-derives every aggregate from the raw `orders` table and requires
agreement on every market.

### `v_admin_alerts` — risk / security alerts (security.read)

A UNION of three real sources per user: active `account_restrictions` (severity `high`),
unresolved `risk_flags` (their own severity) and `security_audit_log` actions from the last 7 days
that name a subject user (`kyc.*`, `security.*`, `withdrawal.*`, `admin.restriction.*`,
`admin.risk_flag.*`; severity `high` for a failing/rejected action, else `medium`).

**It is a queryable view, not an alerting engine.** Nothing pushes, pages, retries or de-duplicates,
and no notification row is generated from it. Real-time alerting is stage 3. `support` gets zero rows
(`security.read` denied); superadmin, compliance and readonly see it.

### Permission matrix additions (data, not code)

Five new actions, 20 new cells — every role still has an explicit ALLOW/DENY for every action:

| action | superadmin | compliance | support | readonly |
|---|---|---|---|---|
| support.read | ✓ | ✓ | ✓ | ✓ |
| support.write | ✓ | ✓ | ✓ | — |
| notifications.send | ✓ | ✓ | ✓ | — |
| notifications.broadcast | ✓ | — | — | — |
| announcements.write | ✓ | — | — | — |

`v_admin_custody` / `v_admin_liquidity` reuse the existing `money.read` cell and `v_admin_alerts`
reuses `security.read`, so no action was invented for a read that already had one. `support` is no
longer strictly read-only: it may answer a customer and send a single-user notification, and nothing
else.

**This re-bases six assertions in `exchange_admin_tests.sql`** (matrix cell count 44 → 64,
superadmin's allowed count 11 → 16, the compliance/support/readonly allowed-action lists, and the
`admin_*` function count 18 → 26). Same assertions, updated to the new data — none of them was
weakened or removed.

### ACL summary

- New tables (`notifications`, `announcements`): RLS on. `notifications` has exactly one policy
  (SELECT, own-or-broadcast) and `SELECT` granted to `authenticated` with INSERT/UPDATE/DELETE
  revoked; `announcements` has no policy and no client grant. Both `REVOKE ALL` from PUBLIC/anon,
  `SELECT, INSERT, UPDATE` to `service_role`.
- New views: `v_public_announcements` SELECT for `anon`/`authenticated`/`service_role`;
  `v_admin_custody`, `v_admin_liquidity`, `v_admin_alerts` SELECT for `authenticated` and
  `service_role`, `REVOKE ALL` from `anon`.
- The eight new `admin_*` functions: `REVOKE ALL` from PUBLIC/anon/authenticated, `EXECUTE` to
  `service_role` only. `user_mark_notification_read` is the single exception: `REVOKE ALL` from
  PUBLIC/anon, `EXECUTE` to `authenticated` and `service_role`. (The PUBLIC revoke matters — a new
  PostgreSQL function is executable by PUBLIC, and `anon` inherits it.)
- The four read-only identity helpers keep their `EXECUTE` grant to `authenticated`, re-asserted here
  because the three new role-scoped views depend on them.

### Deliberate scope limits (for the owner)

- No real-time delivery (websockets/realtime channels), no email/SMS/push provider: a notification is
  a row, and the frontend/realtime stage is what will surface it.
- No per-user broadcast read receipts (needs a join table — stage 3).
- No live custody connectivity: `connectivity = 'not_connected'` is the truth, not a placeholder to
  be "fixed" in the UI.
- No market maker and no fabricated depth.
- No alerting engine, no paging, no escalation policy.
- User-side chat RLS is untouched — the parked privacy decision above.
- No money-path function is re-created and no admin function can create customer money (static probe
  over `pg_proc.prosrc`, plus the post-suite ledger/balance reconciliation checks).

### Verification

Scratch PostgreSQL 16, every migration applied in order, all **nine** suites green (runner exit 0):
matching 63/63 · schema 112/0 · ledger 5/0 with exactly 4 expected errors · immutability+RLS 60/60 ·
deposits 174/174 · withdrawals 181/181 · kyc 160/160 · admin 171/171 · **comms 125/125**.
Nothing was applied to the live project `ctrazoqbudsfkpawpomv`.

## Realtime publication + operational health checks (stage 3 — migration `20261005100170_exchange_realtime_health`)

### Realtime publication membership

Eight user-facing event tables are members of `supabase_realtime`: `orders`, `trades`, `balances`,
`deposits`, `withdrawal_requests`, `notifications`, `chat_conversations`, `chat_messages`. There is
**no new authorisation mechanism**: Supabase Realtime applies each table's existing RLS to every
subscriber's row changes, so a subscriber only receives events for rows their RLS already lets them
read. The migration therefore **refuses to run** if any member of the publication (not just the eight)
has RLS disabled — an unpublished-RLS table would broadcast every row change to every subscriber.

| channel | what arrives | who sees it |
|---|---|---|
| `orders` | INSERT/UPDATE of an order | its owner only (`user_id = auth.uid()`) |
| `trades` | one INSERT per fill | the taker and the maker of that fill |
| `balances` | UPDATE when available/locked units change | the account owner |
| `deposits` | status transitions | the depositor |
| `withdrawal_requests` | status transitions | the requester |
| `notifications` | INSERT of own rows + broadcasts (`user_id IS NULL`) | own rows for everyone; broadcasts to all signed-in users |
| `chat_conversations` / `chat_messages` | support chat created/updated, new message | the visitor widget path (user-side chat RLS unchanged — parked owner decision) |

`security_audit_log` is **deliberately NOT published**: it is operator-only and names subjects,
actors and IPs. Admin risk/security alerts stay pull-based on `v_admin_alerts`. Publishing the audit
trail is an owner decision.

**Delivery is not verified here.** A scratch PostgreSQL has no Realtime daemon and runs
`wal_level = replica`; the stub's `wal_level is insufficient to publish logical changes` warning is
expected and skipped. Membership is a schema fact on scratch; end-to-end websocket delivery can only
be verified against the deployed project (production-verification bucket). `system_health.realtime`
therefore stays `not_configured` — it is never flipped to `ok` from a scratch run.

### Deposit / withdrawal status notifications

Two `AFTER UPDATE OF status` triggers — `deposits_notify_status` and
`withdrawal_requests_notify_status` — insert exactly **one** `notifications` row per real transition
(`OLD.status IS DISTINCT FROM NEW.status`), of type `deposit.status` / `withdrawal.status`, carrying
only facts already on the row (amount rendered with the asset's `base_decimals`, asset symbol, network,
new status, txid). They fire only on transitions the existing state machines already allow, never
write money, never retry, never invent an event, and never call a money-path function. Each is
wrapped so a notification failure raises a WARNING instead of blocking or rolling back the status
change that caused it.

### `system_health`

`system_health(component PK, status, last_checked_at, detail jsonb, checked_by)`; `status` is CHECKed
to exactly `ok | degraded | down | not_configured | not_connected`. Seeded once
(`INSERT … ON CONFLICT DO NOTHING`, so a re-run never rewrites history) with the truth of this build:

| component | seeded status | why |
|---|---|---|
| `database` | `ok` — the result of `run_db_self_check()` actually executed at seed time | the self-check counts ledger transactions that do not sum to zero and balances that do not equal their ledger sum |
| `market_data` | `not_configured` | no market-data provider chosen (owner decision #3) |
| `blockchain:BTC`, `blockchain:ETH`, `blockchain:USDT`, `blockchain:SOL` | `not_connected` | no live chain connectivity exists; the adapter contracts are interfaces only |
| `custodian` | `not_connected` | no custody provider chosen (owner decision #2) |
| `realtime` | `not_configured` | publication recorded, delivery unverified until deployment |

- `record_health(component, status, detail, checked_by)` — the **only write path**, `service_role`
  only. Enum-checked, refuses an unknown component (adding a component is an ops/owner decision, not
  a provider's), and stores `detail` **verbatim** (no merge, no sanitising, no "correction"). It is
  what future edge functions and provider adapters call.
- `run_db_self_check()` — the real check (counts, never a constant). It reports discrepancies; it
  never repairs them (that is stage 4's job).
- `v_system_health` (authenticated) — `component, status, last_checked_at` only. The `detail` JSON is
  internal evidence and is not a column of this view.
- `v_admin_system_health` (operator, `security.read`) — adds `checked_by`, the full `detail` and
  `needs_attention` (true for `down`/`degraded`). **That flag is the failure-alert surface**: nothing
  pages, retries or fabricates a recovery.
- `admin_health_recheck(operator)` — `security.read`, audited `admin.health.recheck`. Runs **only** the
  database self-check and rewrites **only** the `database` row. No overrides: it cannot mark a
  provider healthy, cannot clear a `down` component, and cannot touch `market_data`, `blockchain:*`,
  `custodian` or `realtime`.
- No new permission action is invented: the operator health view and the re-check reuse the existing
  `security.read` cell (the same one `v_admin_alerts` uses), so the PR #7 matrix and its cell counts
  are unchanged.

### ACL summary

- `system_health`: RLS on with **no policy** (like `admin_users`), `REVOKE ALL` from PUBLIC/anon/
  authenticated, `SELECT, INSERT, UPDATE` to `service_role`. The two views are the only read paths.
- `v_system_health`, `v_admin_system_health`: `SELECT` to `authenticated` and `service_role`,
  `REVOKE ALL` from `anon`.
- `record_health`, `run_db_self_check`, `health_status_from_self_check`, `admin_health_recheck`,
  `units_to_display` and both trigger functions: `REVOKE ALL` from PUBLIC/anon/authenticated,
  `EXECUTE` to `service_role` only. (The PUBLIC revoke matters — a new PostgreSQL function is
  executable by PUBLIC and `anon` inherits it.)

### Deliberate scope limits (for the owner)

- No Realtime daemon/channel configuration and no websocket client code: the migration records
  publication membership; the frontend subscription layer is stage 6.
- No `security_audit_log` publication (leak) — owner decision if it is ever wanted.
- No alerting engine: `down`/`degraded` rows are visible in `v_admin_system_health`, nothing pages.
- No per-user read state for broadcast notifications (unchanged from stage 2, part 2).
- No provider adapter writes `record_health` yet — stage 7 wires them; until then `market_data`,
  `blockchain:*`, `custodian` and `realtime` keep their honest non-ok states.

### Verification

Scratch PostgreSQL 16, every migration applied in order, all **ten** suites green (runner exit 0):
matching 63/63 · schema 112/0 · ledger 5/0 with exactly 4 expected errors · immutability+RLS 60/60 ·
deposits 174/174 · withdrawals 181/181 · kyc 160/160 · admin 171/171 · comms 125/125 ·
**realtime_health 106/106**. Live websocket delivery is NOT verified (no Realtime daemon on scratch);
that stays a deployment-time check. Nothing was applied to the live project
`ctrazoqbudsfkpawpomv`.

---

## Stage 4 — financial reconciliation + discrepancy alerts (`20261005100180_exchange_reconciliation.sql`)

**Core rule: reconciliation DETECTS and REPORTS. It never corrects, never auto-adjusts, never
hides.** No function here writes a ledger entry, moves a cached balance or edits a provider
figure. A real correction is a deliberate compensating ledger posting by an operator — the
future path, deliberately not built.

| object | what it is |
|---|---|
| `provider_balances` | What a custody/provider adapter reports, EXACTLY as reported: one row per (asset, network, environment), integer base units, `reported_at`, `source`, `detail`. **EMPTY until a real provider exists**; a missing row means *unavailable*, never zero. A reported `0` is a real empty-wallet report and is kept distinct from a missing row. |
| `provider_balances_log` | Append-only history of every report (`recorded` / `replaced` + `previous_units`), written by an AFTER trigger, UPDATE/DELETE refused. |
| `reconciliation_runs` | One row per run: `started_at`, `finished_at`, `status` (running/completed/failed), `environment`, `triggered_by`, `detail` (per-check invariants + counts). Write-once: only status/finished_at/detail change, and only while `running`. A run that raises is recorded `failed` with the error in `detail` — callers must check `status`. |
| `reconciliation_results` | Per (asset, environment): `customer_liability_units` (ledger, source of truth), `projection_units` (cached balances), `custody_units`, `provider_units` (NULL = unavailable), `drift_units` = liability − projection, `status` (match/drift/unavailable), `detail`. Append-only. |
| `reconciliation_alerts` | `severity` warning/critical, `kind` internal_drift/custody_mismatch/provider_mismatch/stale_provider, `detail`, `acknowledged_at/by/note`. Append-only; UPDATE only for the three acknowledge columns, once; DELETE refused. Acknowledge ≠ fix. |
| `record_provider_balance(...)` | The ONLY write path into provider data (the stage-7 adapter hook). Stores exactly what is reported; refuses fractional (never rounds), negative, NULL, unknown asset, missing source, non-object detail, unknown environment. `service_role` only. |
| `run_reconciliation(environment, operator)` | Operator path (`security.read`, audited with a real actor): one snapshot, all active assets, alerts, invariant scan. `service_role` only at the grant level. |
| `acknowledge_reconciliation_alert(id, note, operator)` | `risk.write`, audited, write-once. Changes the acknowledge columns and nothing else. |
| `v_admin_reconciliation` | Latest run per environment × asset with the four numbers, status, detail, open/acknowledged alert counts (`money.read`). A run with no results (failed/running) still shows one row with `asset NULL`, so a failed run is never invisible. |
| `v_admin_reconciliation_alerts` | Every alert with run, asset, severity, kind, detail, acknowledgement state (`security.read`). |

### The four numbers, and one deviation from the spec (flagged)

`custody_units` is the custody-side mirror, SIGNED: `-(EXTERNAL_DEPOSIT + WITHDRAWAL_CLEARING)`
ledger sums = net value taken in from outside minus paid out. It is the number a provider report
is comparable to, so `provider_mismatch` compares `provider_units` with `custody_units`.

The spec expected `custody_units` to equal `customer_liability_units` "by construction". **It does
not in this schema, and pretending it did would be dishonest:** liability is the user-side sum,
while `PAPER_FAUCET` (paper funding) and `FEE_INCOME` (fees) are also system accounts, so
`liability = -(EXTERNAL_DEPOSIT + WITHDRAWAL_CLEARING + PAPER_FAUCET + FEE_INCOME)`. Equality
holds only for the FULL system mirror. So the "assert it matches by construction" check is done
where the construction guarantees it — `custody_mismatch` (critical) fires when SUM over ALL
accounts of an asset/environment is not zero — and the gap is shown, never hidden:
`detail.custody_breakdown` (per system account code) and `detail.non_custody_system_units`
(= liability − custody, i.e. paper faucet + fee income).

`status` resolves: internal drift or broken mirror ⇒ `drift`; else no provider report ⇒
`unavailable`; else provider disagrees ⇒ `drift`; else `match`. Provider mismatch is a WARNING,
not critical: provider data is untrusted until stage 7 verifies the adapter. A provider report
older than 24h raises `stale_provider` even when the value agrees.

### Invariant scan (every run, recorded in `detail.invariants`)

1. every ledger transaction sums to zero; 2. every cached balance equals its ledger sum (via the
PR #3 `v_account_reconciliation` view); 3. every asset total across ALL accounts sums to zero.
Each check is recorded as `{check, ok, offending, sample_ids}` (ids bounded to 20); a failure
raises a CRITICAL alert per offending (asset, environment).

### Authorisation — no new permission cell

`run_reconciliation` uses the existing `security.read` cell and
`acknowledge_reconciliation_alert` the existing `risk.write` cell, so the PR #7 matrix is
unchanged (4 roles × 16 actions = 64 cells) and no earlier suite had to be re-based. Precedent:
stage 3's `admin_health_recheck` (also an audited operator action that runs a check and writes a
row) uses `security.read`. The spec allowed either and asked for the choice to be flagged.

All five tables: RLS on with **no policy**, `SELECT` only for `service_role`, nothing for
`anon`/`authenticated`; the RPCs are the only write path. The two views are owner-run (the
`v_admin_custody` pattern) and scope on `operator_can_do(...)`.

### Not done (deliberate)

Auto-correction / compensating postings, a scheduler, alert push/dedup/retry, realtime publication
of reconciliation rows, edge functions, frontend, a real provider adapter (stage 7). Reconciliation
alerts are **not** folded into `v_admin_alerts`: that view is keyed per customer and these alerts
are system-wide, so folding them in would need a fabricated user or a shape change to a view the
comms suite already asserts.

---

## Stage 5 — paper/live separation matrix (`20261005100190_exchange_paper_live_final.sql`)

Stage 5 was an **audit-and-close-gaps** pass, not a rebuild: the machinery below mostly already
existed. What changed is three functions (guards only, bodies verbatim) plus the proof that every
path is gated and refuses the other environment.

### The three gates this stage added

| # | Function | Gap found | Guard added |
|---|---|---|---|
| 1 | `assert_trading_enabled()` | required `mode='live'` + `live_trading_enabled` but never read `live_enabled_at`; the table CHECK `app_settings_live_gate_check` made that unreachable, so the engine trusted `mode` alone | live trading now also requires `live_enabled_at IS NOT NULL` (`'live_enabled_at is NULL'`), belt-and-braces on top of the CHECK. Paper trading unchanged (`paper_trading_enabled`). |
| 2 | `record_provider_balance()` | accepted `p_environment='live'` while the exchange was paper — a real custody figure could be written into a paper-mode database | live reports refused unless `mode='live'` (`'refusing a live report in paper mode'`). Paper reports unchanged. |
| 3 | `run_reconciliation()` | accepted `p_environment='live'` while paper, creating live runs/results/alerts | live runs refused unless `mode='live'` (`'refusing a live run in paper mode'`). Paper runs unchanged. |

Nothing was weakened, dropped or renamed. `app_settings` is untouched: `mode='paper'`, every
`LIVE_*` flag false, `paper_*` switches true, `live_enabled_at` NULL.

### The matrix (path → gate → proving test)

`SA` = `tests/exchange_separation_audit.sql` (new, this stage). `M` matching · `S` schema ·
`D` deposits · `W` withdrawals · `K` KYC · `A` admin · `C` comms · `H` realtime/health ·
`R` reconciliation.

| Path (public entry point) | Gate(s) — in the order they fire | Proven by |
|---|---|---|
| `place_order` | `assert_trading_enabled` (mode + paper/live flag + **live_enabled_at**) → `assert_not_in_maintenance('trading')` → `assert_account_not_restricted('trading')` → market must exist **in the current environment** → `orders`/`ledger_transactions` environment triggers | M; A (restrictions, maintenance); SA S1/S3/S4 |
| `cancel_order` | `assert_trading_enabled` only. **Deliberate:** cancelling releases funds and must stay available during maintenance/restrictions | M; A; SA S1, S6 |
| `match_order`, `close_order`, `settle_fill` | internal; `settle_fill` re-asserts `assert_trading_enabled`; every ledger row goes through `post_entry` + the environment trigger | M; SA S6 |
| `record_deposit` → `_deposit_ingest` | source↔mode pairing (`paper_operator` refused unless `mode='paper'`) → `assert_deposits_enabled` (live: `deposits_enabled`) → `assert_paper_deposits_enabled` (paper path) → `assert_not_in_maintenance('deposits')` → `assert_account_not_restricted` → `deposits` environment trigger | D; A; SA S1/S3/S6 |
| `record_provider_deposit` → `_deposit_ingest('provider_adapter')` | source↔mode pairing (`provider_adapter` refused unless `mode='live'`) → `assert_deposits_enabled` (`deposits_enabled`) → maintenance → restriction | D; SA S2/S3 |
| `set_deposit_confirmations`, `confirm_deposit`, `set_deposit_under_review`, `fail_deposit` | `assert_deposits_enabled` (+ deposit status machine) | D; SA S6 |
| `credit_deposit` | `assert_deposits_enabled` → maintenance → restriction → `assert_paper_deposits_enabled` for a paper row | D; SA S1/S6 |
| `record_withdrawal_request` → `_withdrawal_ingest` | source↔mode pairing (`paper_operator` refused unless paper) → `assert_withdrawals_enabled` → `assert_paper_withdrawals_enabled` → maintenance → restriction → `withdrawal_requests` environment trigger | W; A; SA S1/S3/S6 |
| `record_provider_withdrawal` → `_withdrawal_ingest('provider_adapter')` | source↔mode pairing (`provider_adapter` refused unless live) → `assert_withdrawals_enabled` (`withdrawals_enabled`) → maintenance → restriction | W; SA S2/S3 |
| `approve_withdrawal`, `start_withdrawal_processing`, `set_withdrawal_under_review`, `complete_withdrawal` | `assert_withdrawals_enabled` (+ maintenance/restriction on approve) (+ `assert_paper_withdrawals_enabled` for a paper row on approve/complete) | W; A; SA S1/S6 |
| `reject_withdrawal`, `fail_withdrawal` (release) | `assert_withdrawals_enabled` only. **Deliberate:** locked funds must always be releasable, so the paper switch is not read | W; SA S6 |
| `submit_kyc` | `assert_kyc_path('paper_operator')` → refused while `mode='live'` (live intake comes from the provider) | K; SA S1/S3 |
| `record_provider_kyc_event` | `assert_kyc_path('provider_adapter')` → refused unless `mode='live'` | K; SA S2/S3 |
| `approve_kyc`, `reject_kyc`, `set_kyc_under_review` (+ `admin_kyc_*` wrappers) | `assert_kyc_path(<submission source>)` — a paper submission cannot be decided in live mode and vice versa; `kyc_submissions_source_environment_check` backs it in the data | K; A; SA S6 |
| `record_provider_balance` | **NEW** live environment requires `mode='live'`; service_role only; append-only log | R; SA S2/S3/S6 |
| `run_reconciliation` | **NEW** live environment requires `mode='live'` → `assert_operator('security.read')` | R; SA S1/S2/S3/S6 |
| `acknowledge_reconciliation_alert` | operator `security.read`; no environment of its own (an alert belongs to a run) | R; SA S6 |
| table-level gate (`enforce_environment_gate`) | `accounts`, `ledger_transactions`, `orders`, `trades`, `deposits`, `withdrawal_requests`: a `live` row is refused unless `mode='live'` **and** the feature flag is on | S; SA S2/S6 |
| non-money paths: notifications, announcements, support chat, `system_health` | **no mode gate** — they carry no money and no environment column. Reachability is unchanged by mode: an operator can send a notification or answer support in either mode | C; H; SA S6 (static: no mode gate in their bodies) |

### Deliberately NOT gated (documented, flagged to the owner)

1. **`admin_upsert_market(..., p_environment)`** can create a `live` market row while the exchange is
   paper. It moves no money and the row is inert: no order, trade, ledger row, deposit or withdrawal
   can exist in the `live` environment until `mode='live'` (trigger). Gating it was not required by
   the audit list and would have been an unrequested behaviour change to an admin path.
2. **Paper rows are allowed in live mode** for `record_provider_balance` and `run_reconciliation`
   (only the *live* direction is gated). A paper report/run while live reads and writes only paper
   data and cannot influence a live reconciliation.
3. **`cancel_order` and the withdrawal release paths** intentionally ignore maintenance mode and
   account restrictions (see the matrix).

### What still depends on deployment / providers (honest)

- **Realtime delivery** is not verifiable on scratch (no Realtime daemon, `wal_level=replica`); the
  publication and its RLS gate are proven, delivery is a deployment-time check (stage 3).
- **Custody connectivity** does not exist: `v_admin_custody` reports `not_connected`, and
  `provider_balances` is empty until a real adapter calls `record_provider_balance` (stage 7).
- **Live KYC / live deposits / live withdrawals** have no adapter behind them. In live mode the
  adapter paths pass the mode gate and then stop at the next honest refusal (unregistered live
  network, missing provider submission). No live money or customer data exists in any environment.
- **No `LIVE_*` flag has ever been true outside a scratch database**, and stage 5 does not change
  what "verified" must mean before one is turned on (owner decision #4).

### Verification (stage 5)

Eleven suites from stages 1–4 plus `exchange_separation_audit.sql` (81 assertions: 81 pass, 0 fail,
0 bare `psql ERROR`), all green on a scratch PostgreSQL 16 through
`tests/run_scratch_suites.sh`, which now runs the audit suite last in the core database. The audit
suite is the only one that flips `app_settings.mode`; it reverts it, asserts the settings are
identical to its own pre-run snapshot, asserts **zero** live money rows were created, and re-checks
both ledger invariants. Nothing in this stage was deployed to `ctrazoqbudsfkpawpomv`.

---

## Stage 7 — user-facing withdrawal requests and KYC submissions

Migration `20261005100200_exchange_user_submissions.sql` (stage 7, not deployed). Two client
entry points — `request_withdrawal` and `cancel_my_withdrawal` — plus a KYC application entry
point `submit_my_kyc`, so a signed-in user can act **without any service_role permission**,
without a chain/provider call and without any path to a self-granted "verified".

### Public surface (granted to `authenticated` ONLY)

| function | signature | returns | auth | ownership |
|---|---|---|---|---|
| `request_withdrawal` | `(p_asset text, p_network text, p_amount_units bigint, p_idempotency_key text DEFAULT NULL, p_destination_address text DEFAULT NULL)` | `TABLE (request_id uuid, request_status text, existing boolean)` | `auth.uid() IS NULL` → `insufficient_privilege` "no authenticated user" | `user_id := auth.uid()`; never a parameter |
| `cancel_my_withdrawal` | `(p_request_id uuid)` | `TABLE (request_id uuid, request_status text, released_units numeric)` | same | row must satisfy `user_id = auth.uid()` **inside** the function, plus the own-row RLS policy |
| `submit_my_kyc` | `(p_tier_code text, p_documents jsonb DEFAULT '{}')` | `TABLE (submission_id uuid, submission_status text, existing boolean)` | same | `user_id := auth.uid()` |

ACL: `REVOKE ALL ... FROM PUBLIC, anon, authenticated, service_role` then `GRANT EXECUTE ... TO
authenticated` on each of the three. **service_role is deliberately not granted** — the operator
surface stays exactly the functions it already had. The suite asserts the ACL itself
(`aclexplode`, no `grantee = 0`) rather than only `has_function_privilege`, and asserts that the
only privileged money functions executable by `authenticated` are the two documented stage-1 ones
(`place_order`, `cancel_order`).

`submit_my_kyc` is named that way on purpose: `submit_kyc(p_user_id, p_level, ...)` is the
**operator** path (service_role) and the KYC suite's static ACL probe asserts no function named
`submit_kyc` is executable by `authenticated`. A second overload under the same name would have
broken that assertion or forced it to be weakened.

### Grants / ownership / gates matrix

| function | auth | ownership | validation | gates | idempotency |
|---|---|---|---|---|---|
| `request_withdrawal` | `auth.uid()` required, anon has no EXECUTE | `user_id = auth.uid()`; own-row RLS on reads | integer base units > 0, network min/max, asset exists, (asset, network) registered + enabled, memo requirement, destination required (4..200, no whitespace) | `assert_withdrawals_enabled`, `assert_paper_withdrawals_enabled`, `assert_not_in_maintenance('withdrawals')`, `assert_account_not_restricted(uid, 'withdrawals')`, paper-only mode rule | `UNIQUE (user_id, idempotency_key)`; hold key `withdrawal_hold:<id>`; retry returns `existing = true` and holds nothing |
| `cancel_my_withdrawal` | `auth.uid()` required | `user_id = auth.uid()` checked in the function | status must be `pending` | release path: deliberately **not** gated by the paper switch or maintenance (like reject/fail) | release key `withdrawal_release:<id>`; a second cancel is refused |
| `submit_my_kyc` | `auth.uid()` required | `user_id = auth.uid()`; own-row RLS on reads | tier must exist in `kyc_levels` and be ≥ 1; documents must be a JSON object; existing no-PII denylist trigger refuses personal data | `assert_kyc_path('user_client')` — paper only in this stage | one OPEN application per (user, tier) via `kyc_submissions_user_open_key`; retry returns `existing = true` |

### Money rules of a client withdrawal request

* **Request holds.** `request_withdrawal` posts one `withdrawal_request` ledger transaction
  (`available -= amount+fee`, `locked += amount+fee`) and stores it in
  `hold_ledger_transaction_id`. An unfunded request raises `insufficient available balance` and
  rolls back entirely — a request row never exists without its hold.
* **Idempotent, no double hold.** New column `withdrawal_requests.idempotency_key` +
  partial `UNIQUE (user_id, idempotency_key)`. The hold uses the same ledger idempotency key the
  approval path uses (`withdrawal_hold:<request id>`), so a race can only produce one hold; the
  losing call returns the winner's request with `existing = true`.
* **Cancel releases exactly.** `cancel_my_withdrawal` → `_withdrawal_close(id, 'cancelled', ...)`
  → one balanced `withdrawal_refund` (`locked -= amount+fee`, `available += amount+fee`), recorded
  in `released_ledger_transaction_id`, `closed_at` set. Only from `pending`.
* **Approval stays admin-only.** `approve_withdrawal` is still service_role only and gained ONE
  additive branch: if the row already carries its hold (a client request), approval **confirms**
  it instead of posting a second one; every row without a pre-existing hold (operator path,
  provider adapter) is byte-identical to before. Approval of a client request therefore moves no
  money.
* **New terminal status `cancelled`** (added to `withdrawal_requests_status_check`, the state
  machine trigger — reachable from `pending` only — and the `closed_at` / `released` /
  `hold_released` CHECKs). It is terminal and immutable like `failed`/`rejected`.
* **New source `user_client`** on `withdrawal_requests` and `kyc_submissions`. The existing
  source↔environment pairing CHECK is untouched, so `user_client` can only ever be a PAPER row.

### KYC honesty

`submit_my_kyc` inserts one row with `status = 'pending'` (the existing state machine's
"awaiting review" — the plan's "pending_review" is that same state; no new KYC status was
invented), `source = 'user_client'`, `environment = 'paper'`. It never writes `kyc_status.level`
(the applicant stays level 0 / unverified) and its body contains no approval path. Only
`approve_kyc` (operator) or `record_provider_kyc_event` (a real provider event) can decide an
application, and both are service_role only. The existing audit trigger records the submission
with `actor_role = 'user'`, `actor_id = auth.uid()`. One open application per user per tier; a
resubmission after a final state is a new row.

### Stage-7 scope (flagged, not silent)

* Both client write paths are **paper-only in this stage**: while `app_settings.mode = 'live'`
  they refuse with a distinct message, so a client can never create a live money row or a live
  KYC application. Live withdrawals enter through `record_provider_withdrawal`, live KYC through
  `record_provider_kyc_event`. Opening the client paths in live mode is a separate owner-gated
  change.
* No new RLS policy was needed: `withdrawal_requests_select_own` (migration 130) and
  `kyc_submissions_select_own` (migration 140) already restrict a client to its own rows; no
  write policy exists for any client role, and this migration adds none.
* The destination address is **not verified** (no allow-list, no chain integration) — the same
  position as the operator path. No document upload/storage, no vendor, no per-tier limits, no
  KYC gating of money paths.
* Frontend unchanged: the Withdraw and KYC pages stay disabled this stage.

### Verification

`tests/exchange_user_submissions.sql` (U0–U11, 130 assertions) runs in the core scratch database
**after** the reconciliation suite and **before** the separation audit (it flips `mode` to live
and back and reverts it). It covers: anon refused on all three wrappers; authenticated without a
JWT claim refused with the distinct error; the hold and its exact amounts; idempotency (one row,
one hold, unchanged ledger sums on retry); every validation refusal with no row recorded; the
cross-user cancel refusal; the RLS matrix on both tables; the exact cancel release; approval
admin-only + confirming the pre-existing hold; the operator path still holding exactly as before;
the mode gates both ways plus the paper switch, maintenance mode and an account restriction; the
KYC pending-only / no-PII / one-open-per-tier / never-verified rules; the static grant probe; and
a final re-check that `app_settings` is unchanged, no live row exists, every ledger transaction is
zero-sum and every balance equals its entries.
