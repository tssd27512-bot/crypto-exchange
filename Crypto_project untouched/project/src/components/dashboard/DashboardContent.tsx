import { useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Wallet, ArrowDownToLine, LineChart,
  TrendingUp, TrendingDown, Search, BarChart3,
  PieChart, History, Loader2,
} from 'lucide-react';
import {
  fetchAppMode,
  fetchBestPrices,
  fetchMarketStats,
  fetchMarkets,
  fetchMyBalances,
  fetchMyOrders,
  fetchMyTrades,
  formatUnits,
  notionalUnits,
  units,
  useQuery,
  useRealtimeTable,
  type BalanceRow,
  type BestRow,
  type MarketRow,
  type MarketStatsRow,
  type QueryResult,
  type OrderRow,
  type TradeRow,
} from '@/lib/api';
import { ErrorBlock, LoadingBlock, UnavailableBlock } from '@/components/DataState';

export default function DashboardContent() {
  const balances = useQuery<BalanceRow[]>('dash-balances', fetchMyBalances);
  const markets = useQuery<MarketRow[]>('dash-markets', fetchMarkets);
  const best = useQuery<BestRow[]>('dash-best', fetchBestPrices);
  const stats = useQuery<MarketStatsRow[]>('dash-stats', fetchMarketStats);
  const orders = useQuery<OrderRow[]>('dash-orders', fetchMyOrders);
  const trades = useQuery<TradeRow[]>('dash-trades', fetchMyTrades);
  const mode = useQuery<string | null>('dash-mode', fetchAppMode);

  // balances, orders and trades are all in the supabase_realtime publication.
  useRealtimeTable('balances', { onChange: balances.reload });
  useRealtimeTable('orders', { onChange: orders.reload });
  useRealtimeTable('trades', { onChange: trades.reload });

  return (
    <div className="space-y-6">
      <BalanceCard
        balances={balances}
        markets={markets}
        best={best}
        mode={mode}
      />
      <AnalyticsCard orders={orders} trades={trades} />
      <QuickActions />
      <MarketTable markets={markets} best={best} stats={stats} />
      <MarketStatsCards markets={markets} stats={stats} />
    </div>
  );
}

// ---------------------------------------------------------------------------

function valueBalancesInQuote(
  balanceRows: BalanceRow[],
  marketRows: MarketRow[],
  bestRows: BestRow[],
): { totalQuoteUnits: bigint; pricedCount: number; heldCount: number; quoteDecimals: number } {
  const bestByMarket = new Map(bestRows.map((b) => [b.market_id, b]));
  // Prefer a market quoted in USDT; fall back to the first market for the asset.
  const marketByBase = new Map<string, MarketRow>();
  for (const m of marketRows) {
    const existing = marketByBase.get(m.base_symbol);
    if (!existing || (m.quote_symbol === 'USDT' && existing.quote_symbol !== 'USDT')) {
      marketByBase.set(m.base_symbol, m);
    }
  }

  let totalQuoteUnits = 0n;
  let pricedCount = 0;
  let heldCount = 0;
  let quoteDecimals = 6;

  for (const row of balanceRows) {
    const held = units(row.total_units);
    if (held === 0n) continue;
    heldCount += 1;

    if (row.symbol === 'USDT') {
      totalQuoteUnits += held;
      pricedCount += 1;
      continue;
    }

    const market = marketByBase.get(row.symbol);
    if (!market) continue;
    const bestRow = bestByMarket.get(market.market_id);
    const price = units(bestRow?.last_price_units) > 0n
      ? bestRow?.last_price_units
      : bestRow?.best_bid_units;
    if (units(price) === 0n) continue;

    totalQuoteUnits += notionalUnits(held, price, market.notional_scale);
    pricedCount += 1;
    quoteDecimals = market.quote_decimals;
  }

  return { totalQuoteUnits, pricedCount, heldCount, quoteDecimals };
}

function BalanceCard({
  balances,
  markets,
  best,
  mode,
}: {
  balances: QueryResult<BalanceRow[]>;
  markets: QueryResult<MarketRow[]>;
  best: QueryResult<BestRow[]>;
  mode: QueryResult<string | null>;
}) {
  const modeLabel = mode.state.status === 'ready' ? mode.state.data : null;
  const badge =
    modeLabel === 'live'
      ? { text: 'Live account', cls: 'bg-red-50 dark:bg-red-500/10 text-red-700 dark:text-red-300 border-red-200/40 dark:border-red-500/20' }
      : modeLabel === 'paper'
      ? { text: 'Paper account', cls: 'bg-brand-50 dark:bg-brand-950/40 text-brand-700 dark:text-brand-300 border-brand-200/40 dark:border-brand-800/30' }
      : { text: 'Mode unknown', cls: 'bg-gray-100 dark:bg-white/5 text-gray-500 dark:text-gray-400 border-gray-200 dark:border-white/10' };

  const balanceRows = balances.state.status === 'ready' ? balances.state.data : [];
  const marketRows = markets.state.status === 'ready' ? markets.state.data : [];
  const bestRows = best.state.status === 'ready' ? best.state.data : [];

  const valuation = valueBalancesInQuote(balanceRows, marketRows, bestRows);
  const loading = balances.state.status === 'loading' || markets.state.status === 'loading' || best.state.status === 'loading';

  return (
    <div className="relative rounded-2xl bg-gradient-to-br from-surface-light dark:from-surface-dark-2 to-surface-light-2 dark:to-surface-dark-3 border border-gray-200 dark:border-white/5 p-6 card-glow overflow-hidden">
      <div className="absolute top-0 right-0 w-64 h-64 bg-brand-500/5 rounded-full blur-[80px]" />
      <div className="relative flex flex-col lg:flex-row lg:items-center lg:justify-between gap-6">
        <div>
          <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">Your total portfolio value</p>
          <div className="flex items-center gap-3 mb-4">
            {loading ? (
              <div className="flex items-center gap-2 text-2xl font-bold text-gray-400">
                <Loader2 className="w-6 h-6 animate-spin" /> —
              </div>
            ) : (
              <h2 className="text-4xl font-bold text-gray-900 dark:text-white">
                {valuation.heldCount === 0
                  ? '0.00 USDT'
                  : `${formatUnits(valuation.totalQuoteUnits, valuation.quoteDecimals, 2)} USDT`}
              </h2>
            )}
            <span className={`px-2.5 py-1 rounded-md text-xs font-medium border ${badge.cls}`}>
              {badge.text}
            </span>
          </div>
          <p className="text-xs text-gray-400 dark:text-gray-500">
            {balances.state.status === 'unavailable'
              ? 'Balances are not available yet — the exchange backend has not been deployed to this project.'
              : balances.state.status === 'error'
              ? 'Your balances could not be loaded.'
              : valuation.heldCount === 0
              ? 'No holdings yet. Deposits are not open yet (no custody or payment provider is configured).'
              : valuation.pricedCount < valuation.heldCount
              ? `Valued at the exchange's own last traded price — ${valuation.heldCount - valuation.pricedCount} holding(s) have no traded price yet and are excluded.`
              : "Valued at the exchange's own last traded price."}
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

      {balances.state.status === 'error' && (
        <div className="relative mt-4">
          <ErrorBlock failure={balances.state.failure} onRetry={balances.reload} compact />
        </div>
      )}
    </div>
  );
}

function AnalyticsCard({
  orders,
  trades,
}: {
  orders: QueryResult<OrderRow[]>;
  trades: QueryResult<TradeRow[]>;
}) {
  const [tab, setTab] = useState<'overview' | 'performance' | 'breakdown'>('overview');

  const tabs = [
    { key: 'overview' as const, label: 'Overview' },
    { key: 'performance' as const, label: 'Performance' },
    { key: 'breakdown' as const, label: 'Breakdown' },
  ];

  const tradeRows = trades.state.status === 'ready' ? trades.state.data : [];
  const orderRows = orders.state.status === 'ready' ? orders.state.data : [];

  const openOrders = orderRows.filter((o) => o.status === 'new' || o.status === 'partially_filled');
  const volumeQuote = tradeRows.reduce((sum, t) => sum + units(t.quote_units), 0n);
  const feesQuote = tradeRows.reduce(
    (sum, t) => sum + units(t.taker_fee_units) + units(t.maker_fee_units),
    0n,
  );

  const stats = [
    { label: 'Trades', value: trades.state.status === 'ready' ? String(tradeRows.length) : '—' },
    { label: 'Open Orders', value: orders.state.status === 'ready' ? String(openOrders.length) : '—' },
    { label: 'Volume (quote)', value: trades.state.status === 'ready' ? formatUnits(volumeQuote, 6, 2) : '—' },
    { label: 'Fees Paid (quote)', value: trades.state.status === 'ready' ? formatUnits(feesQuote, 6, 2) : '—' },
  ];

  const blocked =
    trades.state.status === 'unavailable'
      ? trades.state.failure
      : orders.state.status === 'unavailable'
      ? orders.state.failure
      : null;

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

      {blocked ? (
        <UnavailableBlock failure={blocked} compact onRetry={() => { trades.reload(); orders.reload(); }} />
      ) : (
        <>
          <div className="grid grid-cols-2 lg:grid-cols-4 gap-4 mb-6">
            {stats.map((s) => (
              <div key={s.label} className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 p-4">
                <p className="text-xs text-gray-500 dark:text-gray-500 mb-1">{s.label}</p>
                <p className="text-xl font-bold text-gray-900 dark:text-white">{s.value}</p>
              </div>
            ))}
          </div>

          <div className="grid lg:grid-cols-2 gap-4">
            <EmptyChart title="Win / Loss Chart" icon={BarChart3} note="The backend does not compute per-trade P&L yet." />
            <EmptyChart title="Financial Summary" icon={PieChart} note="Asset allocation appears on My Balance." />
          </div>
        </>
      )}
    </div>
  );
}

function EmptyChart({
  title,
  icon: Icon,
  note,
}: {
  title: string;
  icon: typeof BarChart3;
  note?: string;
}) {
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
        <p className="text-sm text-gray-400 dark:text-gray-600">No data to chart yet</p>
        {note && <p className="text-[11px] text-gray-400 dark:text-gray-600 mt-1 text-center max-w-[220px]">{note}</p>}
      </div>
    </div>
  );
}

function QuickActions() {
  const actions = [
    { icon: ArrowDownToLine, title: 'Deposit', desc: 'See deposit status and history', path: '/deposit' },
    { icon: Wallet, title: 'Portfolio', desc: 'View your asset allocation', path: '/balance' },
    { icon: LineChart, title: 'Trade', desc: 'Place a real paper order', path: '/trade' },
    { icon: History, title: 'History', desc: 'Review your past orders and trades', path: '/history' },
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

function MarketTable({
  markets,
  best,
  stats,
}: {
  markets: QueryResult<MarketRow[]>;
  best: QueryResult<BestRow[]>;
  stats: QueryResult<MarketStatsRow[]>;
}) {
  const [search, setSearch] = useState('');

  const marketRows = markets.state.status === 'ready' ? markets.state.data : [];
  const bestRows = best.state.status === 'ready' ? best.state.data : [];
  const statRows = stats.state.status === 'ready' ? stats.state.data : [];

  const rows = marketRows.map((m) => {
    const b = bestRows.find((x) => x.market_id === m.market_id);
    const s = statRows.find((x) => x.market_id === m.market_id);
    const open = units(s?.open_price_units);
    const last = units(s?.last_price_units ?? b?.last_price_units);
    const changePct =
      open > 0n && last > 0n ? (Number(last - open) / Number(open)) * 100 : null;
    return { market: m, best: b, stats: s, changePct };
  });

  const filtered = rows.filter(
    (r) =>
      r.market.market_symbol.toLowerCase().includes(search.toLowerCase()) ||
      r.market.base_symbol.toLowerCase().includes(search.toLowerCase()),
  );

  const unavailable =
    markets.state.status === 'unavailable' || best.state.status === 'unavailable' || stats.state.status === 'unavailable';
  const blockedFailure =
    markets.state.status === 'unavailable'
      ? markets.state.failure
      : best.state.status === 'unavailable'
      ? best.state.failure
      : stats.state.status === 'unavailable'
      ? stats.state.failure
      : null;
  const loading =
    markets.state.status === 'loading' || best.state.status === 'loading' || stats.state.status === 'loading';

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow overflow-hidden">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4 p-6 pb-4">
        <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Market Overview</h3>
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

      {unavailable && blockedFailure ? (
        <div className="p-6 pt-0">
          <UnavailableBlock failure={blockedFailure} onRetry={markets.reload} compact />
        </div>
      ) : loading ? (
        <div className="p-6 pt-0">
          <LoadingBlock label="Loading markets…" />
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="border-y border-gray-200 dark:border-white/5">
                <th className="text-left px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Market</th>
                <th className="text-right px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Last Price</th>
                <th className="text-right px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">24h Change</th>
                <th className="text-right px-6 py-3 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Volume (24h)</th>
              </tr>
            </thead>
            <tbody>
              {filtered.map(({ market, best: b, stats: s, changePct }) => {
                const last = s?.last_price_units ?? b?.last_price_units;
                const volume = s?.volume_quote_units;
                return (
                  <tr
                    key={market.market_id}
                    className="border-b border-gray-100 dark:border-white/5 last:border-0 hover:bg-gray-50 dark:hover:bg-white/5 transition-colors"
                  >
                    <td className="px-6 py-3.5">
                      <div className="flex items-center gap-3">
                        <div className="w-8 h-8 rounded-full bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center text-[10px] font-bold text-white shrink-0">
                          {market.base_symbol[0]}
                        </div>
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
                      {units(volume) > 0n ? `${formatUnits(volume, market.quote_decimals, 2)} ${market.quote_symbol}` : '—'}
                    </td>
                  </tr>
                );
              })}
              {filtered.length === 0 && (
                <tr>
                  <td colSpan={4} className="px-6 py-8 text-center text-sm text-gray-400 dark:text-gray-600">
                    {rows.length === 0 ? 'No markets configured yet.' : `No markets found matching "${search}"`}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function MarketStatsCards({
  markets,
  stats,
}: {
  markets: QueryResult<MarketRow[]>;
  stats: QueryResult<MarketStatsRow[]>;
}) {
  const marketRows = markets.state.status === 'ready' ? markets.state.data : [];
  const statRows = stats.state.status === 'ready' ? stats.state.data : [];

  const totalVolume = statRows.reduce((sum, s) => sum + units(s.volume_quote_units), 0n);

  const movers = statRows
    .map((s) => {
      const open = units(s.open_price_units);
      const last = units(s.last_price_units);
      return { symbol: s.market_symbol, change: open > 0n && last > 0n ? (Number(last - open) / Number(open)) * 100 : null };
    })
    .filter((m) => m.change !== null) as { symbol: string; change: number }[];

  const top = movers.length > 0 ? movers.reduce((a, b) => (b.change > a.change ? b : a)) : null;

  const cards = [
    { label: 'Markets configured', value: markets.state.status === 'ready' ? String(marketRows.length) : '—', sub: 'Trading pairs in the paper book', icon: BarChart3 },
    { label: 'Volume (24h)', value: stats.state.status === 'ready' ? formatUnits(totalVolume, 6, 2) : '—', sub: 'Quote units across all markets', icon: LineChart },
    { label: 'Top mover (24h)', value: top ? top.symbol : '—', sub: top ? `${top.change >= 0 ? '+' : ''}${top.change.toFixed(2)}%` : 'No trades in the last 24h', icon: TrendingUp },
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
          <p className="text-2xl font-bold text-gray-900 dark:text-white">{c.value}</p>
          <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">{c.sub}</p>
        </div>
      ))}
    </div>
  );
}
