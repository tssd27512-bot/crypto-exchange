-- GUARD: this suite reuses state that exchange_schema_tests.sql creates in the SAME database
-- (the auth user 1111..., its funded paper accounts/orders, and the t.expect helper), so it must
-- run after that suite in the same database. Run standalone it used to fail with
-- 'schema "t" does not exist' and a misleading D5 double-entry error. Fail loudly instead.
\set ON_ERROR_STOP on
do $guard$
begin
  if to_regprocedure('t.expect(text,text,text,text,uuid)') is null then
    raise exception 'exchange_ledger_invariant_tests.sql must run in the same database, after exchange_schema_tests.sql (helper t.expect is missing).';
  end if;
  if not exists (select 1 from public.accounts where user_id = '11111111-1111-1111-1111-111111111111' and kind = 'available') then
    raise exception 'exchange_ledger_invariant_tests.sql needs the u1 paper accounts created by exchange_schema_tests.sql.';
  end if;
  if not exists (select 1 from public.ledger_entries) then
    raise exception 'exchange_ledger_invariant_tests.sql needs the funded fixtures created by exchange_schema_tests.sql.';
  end if;
end $guard$;
\set ON_ERROR_STOP off
-- D1-D4 below deliberately raise a top-level ERROR: that error is the pass condition.
\echo '=== D1: single-entry (unbalanced) transaction must be rejected at COMMIT'
begin;
insert into public.ledger_transactions (type, environment, idempotency_key) values ('correction','paper','bad-1');
insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units)
select t.id, a.id, a.asset_id, 'paper', 5 from public.ledger_transactions t, public.accounts a
 where t.idempotency_key = 'bad-1' and a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available';
commit;

\echo '=== D2: same-account round trip (sums to zero, one account) must be rejected'
begin;
insert into public.ledger_transactions (type, environment, idempotency_key) values ('correction','paper','bad-2');
insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units)
select t.id, a.id, a.asset_id, 'paper', 5 from public.ledger_transactions t, public.accounts a
 where t.idempotency_key = 'bad-2' and a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available';
insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units)
select t.id, a.id, a.asset_id, 'paper', -5 from public.ledger_transactions t, public.accounts a
 where t.idempotency_key = 'bad-2' and a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available';
commit;

\echo '=== D3: cached balance moved without ledger entries must be rejected at COMMIT'
begin;
update public.balances set available_units = available_units + 1000
 where account_id = (select id from public.accounts where user_id = '11111111-1111-1111-1111-111111111111' and kind = 'available');
commit;

\echo '=== D4: ledger entries with no matching balance update must be rejected at COMMIT'
begin;
insert into public.ledger_transactions (type, environment, idempotency_key) values ('correction','paper','bad-4');
insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units)
select t.id, v.account_id, v.asset_id, 'paper', v.amount_units from public.ledger_transactions t cross join (
  select a.id as account_id, a.asset_id, 1000::numeric as amount_units from public.accounts a
   where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available'
  union all
  select a.id, a.asset_id, -1000::numeric from public.accounts a
   where a.code = 'PAPER_FAUCET' and a.asset_id = (select id from public.assets where symbol = 'BTC')
) v where t.idempotency_key = 'bad-4';
commit;

\echo '=== D5: a correct transaction (entries + matching cache updates) must COMMIT'
begin;
with tx as (
  insert into public.ledger_transactions (type, environment, idempotency_key) values ('correction','paper','good-control') returning id
), postings as (
  insert into public.ledger_entries (transaction_id, account_id, asset_id, environment, amount_units)
  select tx.id, v.account_id, v.asset_id, 'paper', v.amount_units from tx cross join (
    select a.id as account_id, a.asset_id, 1000::numeric as amount_units from public.accounts a
     where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available'
    union all
    select a.id, a.asset_id, -1000::numeric from public.accounts a
     where a.code = 'PAPER_FAUCET' and a.asset_id = (select id from public.assets where symbol = 'BTC')
  ) v returning account_id, amount_units
)
update public.balances b set available_units = b.available_units + p.amount_units
  from postings p where b.account_id = p.account_id;
commit;

\echo '=== D6: results after the control transaction'
select t.expect('rejected transactions left no rows behind', $q$select count(*)::text from public.ledger_transactions where idempotency_key like 'bad-%'$q$, '0');
select t.expect('the good control transaction is committed', $q$select count(*)::text from public.ledger_transactions where idempotency_key = 'good-control'$q$, '1');
select t.expect('u1 available = 99941000 after the control transaction', $q$select b.available_units::text from public.balances b join public.accounts a on a.id = b.account_id where a.user_id = '11111111-1111-1111-1111-111111111111' and a.kind = 'available'$q$, '99941000');
select t.expect('no drift anywhere after all of that', $q$select count(*)::text from public.v_account_reconciliation where drift_units <> 0$q$, '0');
select t.expect('ledger still sums to zero', $q$select coalesce(sum(amount_units), 0)::text from public.ledger_entries$q$, '0');
