import { useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Wallet, ArrowDownToLine, ArrowUpFromLine, LineChart,
  TrendingUp, TrendingDown, Search, BarChart3,
  PieChart, History,
} from 'lucide-react';
import { dashboardMarketData } from '@/data/mockData';

function formatPrice(price: number) {
  if (price < 1) return `$${price.toFixed(4)}`;
  if (price < 100) return `$${price.toFixed(2)}`;
  return `$${price.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function DashboardContent() {
  return (
    <div className="space-y-6">
      <BalanceCard />
      <AnalyticsCard />
      <QuickActions />
      <MarketOverview />
      <MarketStats />
    </div>
  );
}

function BalanceCard() {
  return (
    <div className="relative rounded-2xl bg-gradient-to-br from-surface-light dark:from-surface-dark-2 to-surface-light-2 dark:to-surface-dark-3 border border-gray-200 dark:border-white/5 p-6 card-glow overflow-hidden">
      <div className="absolute top-0 right-0 w-64 h-64 bg-brand-500/5 rounded-full blur-[80px]" />
      <div className="relative flex flex-col lg:flex-row lg:items-center lg:justify-between gap-6">
        <div>
          <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">Your total portfolio value</p>
          <div className="flex items-center gap-3 mb-4">
            <h2 className="text-4xl font-bold text-gray-900 dark:text-white">$0.00</h2>
            <span className="px-2.5 py-1 rounded-md text-xs font-medium bg-brand-50 dark:bg-brand-950/40 text-brand-700 dark:text-brand-300 border border-brand-200/40 dark:border-brand-800/30">
              Fresh Demo Account
            </span>
          </div>
          <p className="text-xs text-gray-400 dark:text-gray-500">
            Deposit funds to start trading across 800+ markets
          </p>
        </div>
        <div className="flex gap-3">
          <Link to="/deposit" className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple">
            <ArrowDownToLine className="w-4 h-4" />
            Deposit
          </Link>
          <Link to="/trade" className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-gray-700 dark:text-gray-200 bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-xl hover:border-brand-300 dark:hover:border-brand-600/50 transition-all">
            <LineChart className="w-4 h-4" />
            Trade
          </Link>
        </div>
      </div>
    </div>
  );
}

function AnalyticsCard() {
  const [tab, setTab] = useState<'overview' | 'performance' | 'breakdown'>('overview');

  const tabs = [
    { key: 'overview' as const, label: 'Overview' },
    { key: 'performance' as const, label: 'Performance' },
    { key: 'breakdown' as const, label: 'Breakdown' },
  ];

  const stats = [
    { label: 'Total Trades', value: '0' },
    { label: 'Win Rate', value: '0%' },
    { label: 'Net Profit', value: '$0.00' },
    { label: 'Total Volume', value: '$0.00' },
  ];

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-6 card-glow">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 mb-6">
        <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Trading Analytics</h3>
        <div className="flex gap-1 p-1 rounded-xl bg-gray-100 dark:bg-white/5">
          {tabs.map((t) => (
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
      </div>

      {/* Stats grid */}
      <div className="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
        {stats.map((s) => (
          <div key={s.label} className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 p-4">
            <p className="text-xs text-gray-500 dark:text-gray-500 mb-1">{s.label}</p>
            <p className="text-xl font-bold text-gray-900 dark:text-white">{s.value}</p>
          </div>
        ))}
      </div>

      {/* Charts with empty states */}
      <div className="grid lg:grid-cols-2 gap-4">
        <EmptyChart title="Win / Loss Chart" icon={BarChart3} />
        <EmptyChart title="Financial Summary" icon={PieChart} />
      </div>
    </div>
  );
}

function EmptyChart({ title, icon: Icon }: { title: string; icon: typeof BarChart3 }) {
  return (
    <div className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 p-6 min-h-[200px] flex flex-col">
      <div className="flex items-center gap-2 mb-4">
        <Icon className="w-4 h-4 text-gray-400 dark:text-gray-500" />
        <span className="text-sm font-medium text-gray-600 dark:text-gray-300">{title}</span>
      </div>
      <div className="flex-1 flex flex-col items-center justify-center">
        <div className="w-12 h-12 rounded-full bg-gray-200 dark:bg-white/5 flex items-center justify-center mb-3">
          <Icon className="w-6 h-6 text-gray-300 dark:text-gray-600" />
        </div>
        <p className="text-sm text-gray-400 dark:text-gray-600">No trade data available</p>
      </div>
    </div>
  );
}

function QuickActions() {
  const actions = [
    { icon: ArrowDownToLine, title: 'Deposit', desc: 'Add funds to your account', path: '/deposit' },
    { icon: Wallet, title: 'Portfolio', desc: 'View your asset allocation', path: '/balance' },
    { icon: LineChart, title: 'Trade', desc: 'Start trading 800+ markets', path: '/trade' },
    { icon: History, title: 'Trade History', desc: 'Review your past trades', path: '/trade' },
  ];

  return (
    <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-4">
      {actions.map((a) => (
        <Link
          key={a.title}
          to={a.path}
          className="group rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-5 text-left hover:border-brand-300 dark:hover:border-brand-600/40 hover:-translate-y-1 transition-all duration-300"
        >
          <div className="w-11 h-11 rounded-xl bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center mb-3 group-hover:glow-purple transition-all">
            <a.icon className="w-5 h-5 text-brand-600 dark:text-brand-400" />
          </div>
          <h4 className="text-sm font-semibold text-gray-900 dark:text-white mb-1">{a.title}</h4>
          <p className="text-xs text-gray-500 dark:text-gray-400 leading-relaxed">{a.desc}</p>
        </Link>
      ))}
    </div>
  );
}

function MarketOverview() {
  const [search, setSearch] = useState('');

  const filtered = dashboardMarketData.filter(
    (a) =>
      a.symbol.toLowerCase().includes(search.toLowerCase()) ||
      a.name.toLowerCase().includes(search.toLowerCase())
  );

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow overflow-hidden">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 p-6 pb-4">
        <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Market Overview</h3>
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

      {/* Table */}
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
                    <div
                      className="w-8 h-8 rounded-full flex items-center justify-center text-[10px] font-bold text-white shrink-0"
                      style={{ backgroundColor: asset.color }}
                    >
                      {asset.symbol[0]}
                    </div>
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
                  <span
                    className={`inline-flex items-center gap-1 text-sm font-medium ${
                      asset.change24h >= 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'
                    }`}
                  >
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
  );
}

function MarketStats() {
  const topGainer = [...dashboardMarketData].sort((a, b) => b.change24h - a.change24h)[0];

  const cards = [
    {
      label: 'BTC Dominance',
      value: '52.3%',
      sub: 'Of total market cap',
      icon: BarChart3,
    },
    {
      label: 'Total Volume (24h)',
      value: '$54.8B',
      sub: 'Across all assets',
      icon: LineChart,
    },
    {
      label: 'Top Gainer',
      value: topGainer.symbol,
      sub: `${formatPrice(topGainer.price)} (+${topGainer.change24h.toFixed(2)}%)`,
      icon: TrendingUp,
      color: topGainer.color,
    },
  ];

  return (
    <div className="grid sm:grid-cols-3 gap-4">
      {cards.map((c) => (
        <div
          key={c.label}
          className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-5 card-glow"
        >
          <div className="flex items-center justify-between mb-3">
            <p className="text-xs text-gray-500 dark:text-gray-400">{c.label}</p>
            <div className="w-8 h-8 rounded-lg bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center">
              <c.icon className="w-4 h-4 text-brand-600 dark:text-brand-400" />
            </div>
          </div>
          <div className="flex items-center gap-2">
            {c.color && (
              <div
                className="w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold text-white"
                style={{ backgroundColor: c.color }}
              >
                {c.value[0]}
              </div>
            )}
            <p className="text-2xl font-bold text-gray-900 dark:text-white">{c.value}</p>
          </div>
          <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">{c.sub}</p>
        </div>
      ))}
    </div>
  );
}
