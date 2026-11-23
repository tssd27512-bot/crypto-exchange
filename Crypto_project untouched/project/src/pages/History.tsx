import { useState } from 'react';
import { Link } from 'react-router-dom';
import { History as HistoryIcon } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import {
  fetchMyDeposits,
  fetchMyLedger,
  fetchMyOrders,
  fetchMyTrades,
  fetchMyWithdrawals,
  formatUnits,
  units,
  useQuery,
  type DepositRow,
  type LedgerTransactionRow,
  type OrderRow,
  type QueryResult,
  type TradeRow,
  type WithdrawalRow,
} from '@/lib/api';
import { EmptyState, ErrorBlock, InfoNote, LoadingBlock, UnavailableBlock } from '@/components/DataState';

type Tab = 'orders' | 'trades' | 'ledger' | 'deposits' | 'withdrawals';

const TABS: { key: Tab; label: string }[] = [
  { key: 'orders', label: 'Orders' },
  { key: 'trades', label: 'Trades' },
  { key: 'ledger', label: 'Ledger' },
  { key: 'deposits', label: 'Deposits' },
  { key: 'withdrawals', label: 'Withdrawals' },
];

export default function History() {
  const [tab, setTab] = useState<Tab>('orders');
  const orders = useQuery<OrderRow[]>('hist-orders', fetchMyOrders);
  const trades = useQuery<TradeRow[]>('hist-trades', fetchMyTrades);
  const ledger = useQuery<LedgerTransactionRow[]>('hist-ledger', fetchMyLedger);
  const deposits = useQuery<DepositRow[]>('hist-deposits', fetchMyDeposits);
  const withdrawals = useQuery<WithdrawalRow[]>('hist-withdrawals', fetchMyWithdrawals);

  return (
    <DashboardLayout title="History">
      <PageHeader title="History" subtitle="Every row below is read from the exchange backend" />

      <div className="max-w-4xl space-y-6">
        <div className="flex flex-wrap gap-1 p-1 rounded-xl bg-gray-100 dark:bg-white/5 w-fit">
          {TABS.map((t) => (
            <button
              key={t.key}
              onClick={() => setTab(t.key)}
              className={`px-4 py-1.5 text-sm font-medium rounded-lg transition-all ${
                tab === t.key
                  ? 'bg-white dark:bg-surface-dark-3 text-brand-700 dark:text-brand-300 shadow-sm'
                  : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>

        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
          {tab === 'orders' && (
            <Rows
              query={orders}
              empty="No orders yet"
              emptyDesc="Orders you place appear here with their final status."
              render={(rows: OrderRow[]) =>
                rows.map((o) => (
                  <Row
                    key={o.id}
                    title={`${o.side.toUpperCase()} ${formatUnits(o.qty_units, 8, 8)} @ ${
                      o.price_units ? formatUnits(o.price_units, 8, 8) : 'market'
                    }`}
                    subtitle={`${o.type} · ${o.time_in_force} · ${o.environment} · filled ${formatUnits(
                      o.filled_qty_units,
                      8,
                      8,
                    )}${o.cancel_reason ? ` · ${o.cancel_reason}` : ''}${
                      o.reject_reason ? ` · ${o.reject_reason}` : ''
                    }`}
                    right={o.status}
                    when={o.created_at}
                  />
                ))
              }
            />
          )}

          {tab === 'trades' && (
            <Rows
              query={trades}
              empty="No trades yet"
              emptyDesc="Fills against your orders are recorded here by the matching engine."
              render={(rows: TradeRow[]) =>
                rows.map((t) => (
                  <Row
                    key={t.id}
                    title={`${formatUnits(t.qty_units, 8, 8)} @ ${formatUnits(t.price_units, 8, 8)}`}
                    subtitle={`quote ${formatUnits(t.quote_units, 6, 2)} · fees ${formatUnits(
                      units(t.taker_fee_units) + units(t.maker_fee_units),
                      6,
                      8,
                    )}`}
                    right="filled"
                    when={t.created_at}
                  />
                ))
              }
            />
          )}

          {tab === 'ledger' && (
            <Rows
              query={ledger}
              empty="No ledger entries yet"
              emptyDesc="The append-only ledger records every balance movement; it is empty for a new account."
              render={(rows: LedgerTransactionRow[]) =>
                rows.map((l) => (
                  <Row
                    key={l.id}
                    title={l.type}
                    subtitle={`${l.environment} · ${l.description ?? 'no description'}`}
                    right={l.reference_type ?? ''}
                    when={l.created_at}
                  />
                ))
              }
            />
          )}

          {tab === 'deposits' && (
            <Rows
              query={deposits}
              empty="No deposits yet"
              emptyDesc="Credited deposits are listed here once the backend records them."
              render={(rows: DepositRow[]) =>
                rows.map((d) => (
                  <Row
                    key={d.id}
                    title={`${formatUnits(d.amount_units, 8)} · ${d.network}`}
                    subtitle={`confirmations ${d.confirmations}/${d.required_confirmations} · ${d.environment}`}
                    right={d.status}
                    when={d.detected_at}
                  />
                ))
              }
            />
          )}

          {tab === 'withdrawals' && (
            <Rows
              query={withdrawals}
              empty="No withdrawals yet"
              emptyDesc="Withdrawal requests appear here with their status."
              render={(rows: WithdrawalRow[]) =>
                rows.map((w) => (
                  <Row
                    key={w.id}
                    title={`${formatUnits(w.amount_units, 8)} · ${w.network}`}
                    subtitle={w.destination_address}
                    right={w.status}
                    when={w.requested_at}
                  />
                ))
              }
            />
          )}
        </div>

        <InfoNote>
          History is read-only and comes from the exchange's own tables. If a section says "not available
          yet", the backend has not been deployed to this project.
        </InfoNote>

        <Link
          to="/dashboard"
          className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-gray-700 dark:text-gray-200 bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-xl hover:border-brand-300 dark:hover:border-brand-600/50 transition-all"
        >
          Back to Dashboard
        </Link>
      </div>
    </DashboardLayout>
  );
}

function Rows<T>({
  query,
  empty,
  emptyDesc,
  render,
}: {
  query: QueryResult<T[]>;
  empty: string;
  emptyDesc: string;
  render: (rows: T[]) => React.ReactNode;
}) {
  if (query.state.status === 'loading') return <LoadingBlock label="Loading…" compact />;
  if (query.state.status === 'unavailable')
    return <UnavailableBlock failure={query.state.failure} onRetry={query.reload} compact />;
  if (query.state.status === 'error')
    return <ErrorBlock failure={query.state.failure} onRetry={query.reload} compact />;
  const rows = query.state.data;
  if (rows.length === 0) return <EmptyState title={empty} description={emptyDesc} icon={<HistoryIcon className="w-6 h-6 text-gray-300 dark:text-gray-600" />} compact />;
  return <div className="space-y-2">{render(rows)}</div>;
}

function Row({
  title,
  subtitle,
  right,
  when,
}: {
  title: string;
  subtitle: string;
  right: string;
  when: string;
}) {
  return (
    <div className="flex items-center justify-between gap-3 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 px-3 py-2.5">
      <div className="min-w-0">
        <p className="text-xs font-semibold text-gray-900 dark:text-white">{title}</p>
        <p className="text-[11px] text-gray-500 dark:text-gray-400 truncate">{subtitle}</p>
      </div>
      <div className="text-right shrink-0">
        <p className="text-[11px] font-medium text-gray-700 dark:text-gray-300">{right}</p>
        <p className="text-[11px] text-gray-400 dark:text-gray-500">{new Date(when).toLocaleString()}</p>
      </div>
    </div>
  );
}
