import { Link } from 'react-router-dom';
import { Wallet, ArrowDownToLine, ArrowUpFromLine } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import {
  fetchBestPrices,
  fetchMarkets,
  fetchMyBalances,
  formatUnits,
  notionalUnits,
  units,
  useQuery,
  useRealtimeTable,
  type BalanceRow,
  type BestRow,
  type MarketRow,
} from '@/lib/api';
import { EmptyState, ErrorBlock, LoadingBlock, UnavailableBlock } from '@/components/DataState';

export default function MyBalance() {
  const balances = useQuery<BalanceRow[]>('bal', fetchMyBalances);
  const markets = useQuery<MarketRow[]>('bal-markets', fetchMarkets);
  const best = useQuery<BestRow[]>('bal-best', fetchBestPrices);

  useRealtimeTable('balances', { onChange: balances.reload });

  const rows = balances.state.status === 'ready' ? balances.state.data : [];
  const marketRows = markets.state.status === 'ready' ? markets.state.data : [];
  const bestRows = best.state.status === 'ready' ? best.state.data : [];

  const marketByBase = new Map<string, MarketRow>();
  for (const m of marketRows) {
    const existing = marketByBase.get(m.base_symbol);
    if (!existing || (m.quote_symbol === 'USDT' && existing.quote_symbol !== 'USDT')) {
      marketByBase.set(m.base_symbol, m);
    }
  }

  const valued = rows.map((row) => {
    const held = units(row.total_units);
    if (row.symbol === 'USDT') return { row, valueUnits: held, quoteDecimals: 6, priced: true };
    const market = marketByBase.get(row.symbol);
    const b = market ? bestRows.find((x) => x.market_id === market.market_id) : undefined;
    const price = units(b?.last_price_units) > 0n ? b?.last_price_units : b?.best_bid_units;
    if (!market || units(price) === 0n) {
      return { row, valueUnits: 0n, quoteDecimals: market?.quote_decimals ?? 6, priced: false };
    }
    return {
      row,
      valueUnits: notionalUnits(held, price, market.notional_scale),
      quoteDecimals: market.quote_decimals,
      priced: true,
    };
  });

  const total = valued.reduce((sum, v) => sum + v.valueUnits, 0n);
  const unpriced = valued.filter((v) => units(v.row.total_units) > 0n && !v.priced).length;

  return (
    <DashboardLayout title="My Balance">
      <PageHeader title="My Balance" subtitle="Balances read from the exchange ledger" />

      <div className="max-w-3xl space-y-6">
        {/* Total balance */}
        <div className="rounded-2xl bg-gradient-to-br from-surface-light dark:from-surface-dark-2 to-surface-light-2 dark:to-surface-dark-3 border border-gray-200 dark:border-white/5 p-6 card-glow">
          <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">Total Balance</p>
          <div className="flex items-center gap-3 mb-4">
            {balances.state.status === 'loading' ? (
              <h3 className="text-4xl font-bold text-gray-400">—</h3>
            ) : (
              <h3 className="text-4xl font-bold text-gray-900 dark:text-white">
                {formatUnits(total, 6, 2)} USDT
              </h3>
            )}
            <span className="px-2.5 py-1 rounded-md text-xs font-medium bg-brand-50 dark:bg-brand-950/40 text-brand-700 dark:text-brand-300 border border-brand-200/40 dark:border-brand-800/30">
              {balances.state.status === 'ready' ? 'paper ledger' : 'unavailable'}
            </span>
          </div>
          {unpriced > 0 && (
            <p className="text-xs text-gray-400 dark:text-gray-500 mb-3">
              {unpriced} holding(s) have no traded price yet and are excluded from the total.
            </p>
          )}
          <div className="flex gap-3">
            <Link
              to="/deposit"
              className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
            >
              <ArrowDownToLine className="w-4 h-4" />
              Deposit
            </Link>
            <Link
              to="/withdraw"
              className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-gray-700 dark:text-gray-200 bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-xl hover:border-brand-300 dark:hover:border-brand-600/50 transition-all"
            >
              <ArrowUpFromLine className="w-4 h-4" />
              Withdraw
            </Link>
          </div>
        </div>

        {/* Asset breakdown */}
        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">Asset Breakdown</h3>

          {balances.state.status === 'loading' ? (
            <LoadingBlock label="Loading balances…" compact />
          ) : balances.state.status === 'unavailable' ? (
            <UnavailableBlock failure={balances.state.failure} onRetry={balances.reload} compact />
          ) : balances.state.status === 'error' ? (
            <ErrorBlock failure={balances.state.failure} onRetry={balances.reload} compact />
          ) : rows.length === 0 ? (
            <EmptyState
              title="No assets yet"
              description="Your holdings appear here once the exchange ledger has a balance for your account."
              icon={<Wallet className="w-8 h-8 text-gray-300 dark:text-gray-600" />}
              action={
                <Link
                  to="/deposit"
                  className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
                >
                  <ArrowDownToLine className="w-4 h-4" />
                  Make a Deposit
                </Link>
              }
            />
          ) : (
            <div className="space-y-2">
              {valued.map(({ row, valueUnits, quoteDecimals, priced }) => (
                <div
                  key={row.account_id}
                  className="flex items-center justify-between gap-3 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 px-4 py-3"
                >
                  <div className="flex items-center gap-3">
                    <span className="w-8 h-8 rounded-full bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center text-[10px] font-bold text-white">
                      {row.symbol[0]}
                    </span>
                    <div>
                      <p className="text-sm font-semibold text-gray-900 dark:text-white">{row.symbol}</p>
                      <p className="text-[11px] text-gray-500 dark:text-gray-400">
                        available {formatUnits(row.available_units, row.base_decimals)} · locked{' '}
                        {formatUnits(row.locked_units, row.base_decimals)}
                      </p>
                    </div>
                  </div>
                  <div className="text-right">
                    <p className="text-sm font-semibold text-gray-900 dark:text-white">
                      {formatUnits(row.total_units, row.base_decimals)} {row.symbol}
                    </p>
                    <p className="text-[11px] text-gray-500 dark:text-gray-400">
                      {priced ? `≈ ${formatUnits(valueUnits, quoteDecimals, 2)} USDT` : 'no traded price'}
                    </p>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </DashboardLayout>
  );
}
