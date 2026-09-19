import { useState } from 'react';
import { Search, TrendingUp, TrendingDown, BarChart3, LineChart } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import { dashboardMarketData } from '@/data/mockData';

function formatPrice(price: number) {
  if (price < 1) return `$${price.toFixed(4)}`;
  if (price < 100) return `$${price.toFixed(2)}`;
  return `$${price.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function MarketOverview() {
  const [search, setSearch] = useState('');

  const filtered = dashboardMarketData.filter(
    (a) =>
      a.symbol.toLowerCase().includes(search.toLowerCase()) ||
      a.name.toLowerCase().includes(search.toLowerCase())
  );

  const topGainer = [...dashboardMarketData].sort((a, b) => b.change24h - a.change24h)[0];

  const statCards = [
    { label: 'BTC Dominance', value: '52.3%', sub: 'Of total market cap', icon: BarChart3 },
    { label: 'Total Volume (24h)', value: '$54.8B', sub: 'Across all assets', icon: LineChart },
    {
      label: 'Top Gainer',
      value: topGainer.symbol,
      sub: `${formatPrice(topGainer.price)} (+${topGainer.change24h.toFixed(2)}%)`,
      icon: TrendingUp,
      color: topGainer.color,
    },
  ];

  return (
    <DashboardLayout title="Market Overview">
      <PageHeader title="Market Overview" subtitle="Live prices across all markets" />

      {/* Stat cards */}
      <div className="grid sm:grid-cols-3 gap-4 mb-6">
        {statCards.map((c) => (
          <div key={c.label} className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-5 card-glow">
            <div className="flex items-center justify-between mb-3">
              <p className="text-xs text-gray-500 dark:text-gray-400">{c.label}</p>
              <div className="w-8 h-8 rounded-lg bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center">
                <c.icon className="w-4 h-4 text-brand-600 dark:text-brand-400" />
              </div>
            </div>
            <div className="flex items-center gap-2">
              {c.color && (
                <span
                  className="w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold text-white"
                  style={{ backgroundColor: c.color }}
                >
                  {c.value[0]}
                </span>
              )}
              <p className="text-2xl font-bold text-gray-900 dark:text-white">{c.value}</p>
            </div>
            <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">{c.sub}</p>
          </div>
        ))}
      </div>

      {/* Markets table */}
      <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow overflow-hidden">
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 p-6 pb-4">
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white">All Markets</h3>
          <div className="relative w-full sm:w-64">
            <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text"
              placeholder="Search tokens..."
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className="w-full pl-10 pr-4 py-2.5 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
            />
          </div>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="border-y border-gray-200 dark:border-white/5">
                <th className="text-left px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Asset</th>
                <th className="text-right px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Price</th>
                <th className="text-right px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">24h Change</th>
                <th className="text-right px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Volume (24h)</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map((asset) => (
                <tr
                  key={asset.symbol}
                  className="border-b border-gray-100 dark:border-white/5 last:border-0 hover:bg-gray-50 dark:hover:bg-white/5 transition-colors"
                >
                  <td className="px-6 py-3.5">
                    <div className="flex items-center gap-3">
                      <span
                        className="w-8 h-8 rounded-full flex items-center justify-center text-[10px] font-bold text-white shrink-0"
                        style={{ backgroundColor: asset.color }}
                      >
                        {asset.symbol[0]}
                      </span>
                      <div>
                        <div className="text-sm font-semibold text-gray-900 dark:text-white">{asset.symbol}</div>
                        <div className="text-xs text-gray-500 dark:text-gray-500">{asset.name}</div>
                      </div>
                    </div>
                  </td>
                  <td className="px-6 py-3.5 text-right text-sm font-semibold text-gray-900 dark:text-white">
                    {formatPrice(asset.price)}
                  </td>
                  <td className="px-6 py-3.5 text-right">
                    <span className={`inline-flex items-center gap-1 text-sm font-medium ${asset.change24h >= 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'}`}>
                      {asset.change24h >= 0 ? <TrendingUp className="w-3.5 h-3.5" /> : <TrendingDown className="w-3.5 h-3.5" />}
                      {asset.change24h >= 0 ? '+' : ''}{asset.change24h.toFixed(2)}%
                    </span>
                  </td>
                  <td className="px-6 py-3.5 text-right text-sm text-gray-600 dark:text-gray-300">
                    {asset.volume}
                  </td>
                </tr>
              ))}
              {filtered.length === 0 && (
                <tr>
                  <td colSpan={4} className="px-6 py-8 text-center text-sm text-gray-400 dark:text-gray-600">
                    No tokens found matching "{search}"
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </DashboardLayout>
  );
}
