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
