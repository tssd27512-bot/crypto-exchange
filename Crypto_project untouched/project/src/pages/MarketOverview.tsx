import { useState } from 'react';
import { Search, TrendingUp, TrendingDown, BarChart3, LineChart } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import {
  fetchBestPrices,
  fetchMarketStats,
  fetchMarkets,
  formatUnits,
  units,
  useQuery,
  type BestRow,
  type MarketRow,
  type MarketStatsRow,
} from '@/lib/api';
import { EmptyState, ErrorBlock, LoadingBlock, UnavailableBlock } from '@/components/DataState';

export default function MarketOverview() {
  const markets = useQuery<MarketRow[]>('mo-markets', fetchMarkets);
  const best = useQuery<BestRow[]>('mo-best', fetchBestPrices);
  const stats = useQuery<MarketStatsRow[]>('mo-stats', fetchMarketStats);
  const [search, setSearch] = useState('');

  const marketRows = markets.state.status === 'ready' ? markets.state.data : [];
  const bestRows = best.state.status === 'ready' ? best.state.data : [];
  const statRows = stats.state.status === 'ready' ? stats.state.data : [];

  const rows = marketRows.map((m) => {
    const b = bestRows.find((x) => x.market_id === m.market_id);
    const s = statRows.find((x) => x.market_id === m.market_id);
    const open = units(s?.open_price_units);
    const last = units(s?.last_price_units ?? b?.last_price_units);
    return {
      market: m,
      best: b,
      stats: s,
      changePct: open > 0n && last > 0n ? (Number(last - open) / Number(open)) * 100 : null,
    };
  });

  const filtered = rows.filter(
    (r) =>
      r.market.market_symbol.toLowerCase().includes(search.toLowerCase()) ||
      r.market.base_symbol.toLowerCase().includes(search.toLowerCase()),
  );

  const totalVolume = statRows.reduce((sum, s) => sum + units(s.volume_quote_units), 0n);
  const movers = statRows
    .map((s) => {
      const open = units(s.open_price_units);
      const last = units(s.last_price_units);
      return { symbol: s.market_symbol, change: open > 0n && last > 0n ? (Number(last - open) / Number(open)) * 100 : null };
    })
    .filter((m) => m.change !== null) as { symbol: string; change: number }[];
  const top = movers.length > 0 ? movers.reduce((a, b) => (b.change > a.change ? b : a)) : null;

  const statCards = [
    { label: 'Markets', value: markets.state.status === 'ready' ? String(marketRows.length) : '—', sub: 'Configured trading pairs', icon: BarChart3 },
    { label: 'Volume (24h)', value: stats.state.status === 'ready' ? formatUnits(totalVolume, 6, 2) : '—', sub: 'Quote units, all markets', icon: LineChart },
    { label: 'Top mover (24h)', value: top ? top.symbol : '—', sub: top ? `${top.change >= 0 ? '+' : ''}${top.change.toFixed(2)}%` : 'No trades in 24h', icon: TrendingUp },
  ];

  const blocked =
    markets.state.status === 'unavailable'
      ? markets.state.failure
      : best.state.status === 'unavailable'
      ? best.state.failure
      : stats.state.status === 'unavailable'
      ? stats.state.failure
      : null;

  return (
    <DashboardLayout title="Market Overview">
      <PageHeader title="Market Overview" subtitle="Prices and volume from the exchange's own order book" />

      <div className="grid sm:grid-cols-3 gap-4 mb-6">
        {statCards.map((c) => (
          <div key={c.label} className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-5 card-glow">
            <div className="flex items-center justify-between mb-3">
              <p className="text-xs text-gray-500 dark:text-gray-400">{c.label}</p>
              <div className="w-8 h-8 rounded-lg bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center">
                <c.icon className="w-4 h-4 text-brand-600 dark:text-brand-400" />
              </div>
            </div>
            <p className="text-2xl font-bold text-gray-900 dark:text-white">{c.value}</p>
            <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">{c.sub}</p>
          </div>
        ))}
      </div>

      <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow overflow-hidden">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 p-6 pb-4">
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white">All Markets</h3>
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text"
              placeholder="Search markets..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="w-full pl-10 pr-4 py-2.5 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
            />
          </div>
        </div>

        {blocked ? (
          <div className="p-6 pt-0">
            <UnavailableBlock failure={blocked} onRetry={markets.reload} compact />
          </div>
        ) : markets.state.status === 'loading' ? (
          <div className="p-6 pt-0">
            <LoadingBlock label="Loading markets…" />
          </div>
        ) : markets.state.status === 'error' ? (
          <div className="p-6 pt-0">
            <ErrorBlock failure={markets.state.failure} onRetry={markets.reload} />
          </div>
        ) : rows.length === 0 ? (
          <div className="p-6 pt-0">
            <EmptyState title="No markets configured" description="The backend has no trading pairs yet." />
          </div>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead>
                <tr className="border-y border-gray-200 dark:border-white/5">
                  {['Market', 'Last Price', '24h Change', 'Volume (24h)'].map((h, i) => (
                    <th
                      key={h}
                      className={`px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider ${
                        i === 0 ? 'text-left' : 'text-right'
                      }`}
                    >
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {filtered.map(({ market, best: b, stats: s, changePct }) => {
                  const last = s?.last_price_units ?? b?.last_price_units;
                  return (
                    <tr
                      key={market.market_id}
                      className="border-b border-gray-100 dark:border-white/5 last:border-0 hover:bg-gray-50 dark:hover:bg-white/5 transition-colors"
                    >
                      <td className="px-6 py-3.5">
                        <div className="flex items-center gap-3">
                          <span className="w-8 h-8 rounded-full bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center text-[10px] font-bold text-white shrink-0">
                            {market.base_symbol[0]}
                          </span>
                          <div>
                            <div className="text-sm font-semibold text-gray-900 dark:text-white">{market.market_symbol}</div>
                            <div className="text-xs text-gray-500 dark:text-gray-500">
                              {market.market_status} · {market.environment}
                            </div>
                          </div>
                        </div>
                      </td>
                      <td className="px-6 py-3.5 text-right text-sm font-semibold text-gray-900 dark:text-white">
                        {units(last) > 0n ? formatUnits(last, market.price_scale, 8) : 'No trades yet'}
                      </td>
                      <td className="px-6 py-3.5 text-right">
                        {changePct === null ? (
                          <span className="text-sm text-gray-400 dark:text-gray-600">—</span>
                        ) : (
                          <span className={`inline-flex items-center gap-1 text-sm font-medium ${changePct >= 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'}`}>
                            {changePct >= 0 ? <TrendingUp className="w-3.5 h-3.5" /> : <TrendingDown className="w-3.5 h-3.5" />}
                            {changePct >= 0 ? '+' : ''}{changePct.toFixed(2)}%
                          </span>
                        )}
                      </td>
                      <td className="px-6 py-3.5 text-right text-sm text-gray-600 dark:text-gray-300">
                        {units(s?.volume_quote_units) > 0n
                          ? `${formatUnits(s?.volume_quote_units, market.quote_decimals, 2)} ${market.quote_symbol}`
                          : '—'}
                      </td>
                    </tr>
                  );
                })}
                {filtered.length === 0 && (
                  <tr>
                    <td colSpan={4} className="px-6 py-8 text-center text-sm text-gray-400 dark:text-gray-600">
                      No markets found matching "{search}"
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </DashboardLayout>
  );
}
