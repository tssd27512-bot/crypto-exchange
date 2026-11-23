import { useEffect, useMemo, useState } from 'react';
import {
  ChevronDown, TrendingUp, TrendingDown, Info, Check, AlertCircle, Loader2, X,
} from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import {
  cancelOrder,
  fetchBestPrices,
  fetchMarketStats,
  fetchMarkets,
  fetchMyBalances,
  fetchMyOrders,
  fetchOrderBook,
  formatUnits,
  notionalUnits,
  parseUnits,
  placeOrder,
  toApiFailure,
  units,
  useQuery,
  useRealtimeTable,
  type BalanceRow,
  type BestRow,
  type DepthRow,
  type MarketRow,
  type MarketStatsRow,
  type OrderRow,
  type PlaceOrderResult,
  type QueryResult,
} from '@/lib/api';
import { EmptyState, ErrorBlock, InfoNote, LoadingBlock, UnavailableBlock } from '@/components/DataState';

export default function Trade() {
  const markets = useQuery<MarketRow[]>('trade-markets', fetchMarkets);
  const best = useQuery<BestRow[]>('trade-best', fetchBestPrices);
  const stats = useQuery<MarketStatsRow[]>('trade-stats', fetchMarketStats);
  const balances = useQuery<BalanceRow[]>('trade-balances', fetchMyBalances);
  const orders = useQuery<OrderRow[]>('trade-orders', fetchMyOrders);

  const [marketSymbol, setMarketSymbol] = useState<string | null>(null);
  const marketRows = markets.state.status === 'ready' ? markets.state.data : [];
  const selected = useMemo(
    () => marketRows.find((m) => m.market_symbol === marketSymbol) ?? marketRows[0] ?? null,
    [marketRows, marketSymbol],
  );

  const depth = useQuery<DepthRow[]>(
    `trade-depth:${selected?.market_id ?? 'none'}`,
    () => fetchOrderBook(selected?.market_id ?? null),
  );

  useRealtimeTable('orders', { onChange: depth.reload, enabled: Boolean(selected) });
  useRealtimeTable('trades', { onChange: depth.reload, enabled: Boolean(selected) });
  useRealtimeTable('orders', { onChange: orders.reload });
  useRealtimeTable('balances', { onChange: balances.reload });

  return (
    <DashboardLayout title="Trade">
      <PageHeader title="Trade" subtitle="Orders execute against the exchange's own order book" />

      {markets.state.status === 'unavailable' ? (
        <UnavailableBlock failure={markets.state.failure} onRetry={markets.reload} />
      ) : markets.state.status === 'error' ? (
        <ErrorBlock failure={markets.state.failure} onRetry={markets.reload} />
      ) : markets.state.status === 'loading' ? (
        <LoadingBlock label="Loading markets…" />
      ) : marketRows.length === 0 ? (
        <EmptyState
          title="No markets configured"
          description="The backend has no trading pairs yet, so there is nothing to trade."
        />
      ) : (
        <div className="grid lg:grid-cols-3 gap-6">
          {/* Left: Order form */}
          <div className="lg:col-span-1 space-y-4">
            <MarketSelector
              markets={marketRows}
              selected={selected}
              onSelect={(symbol) => setMarketSymbol(symbol)}
            />
            {selected && (
              <OrderForm
                market={selected}
                best={best}
                balances={balances}
                onPlaced={() => {
                  orders.reload();
                  depth.reload();
                  balances.reload();
                }}
              />
            )}
          </div>

          {/* Right: Price + order book + my orders */}
          <div className="lg:col-span-2 space-y-4">
            {selected && (
              <MarketHeader market={selected} best={best} stats={stats} />
            )}
            {selected && (
              <OrderBookPanel market={selected} depth={depth} />
            )}
            <MyOrders orders={orders} market={selected} onChanged={() => { orders.reload(); depth.reload(); balances.reload(); }} />
            <InfoNote>
              Orders are placed against this exchange's own matching engine, in the environment shown by
              the account badge (paper while the exchange is in paper mode). No order is routed to any
              external venue.
            </InfoNote>
          </div>
        </div>
      )}
    </DashboardLayout>
  );
}

// ---------------------------------------------------------------------------

function MarketSelector({
  markets,
  selected,
  onSelect,
}: {
  markets: MarketRow[];
  selected: MarketRow | null;
  onSelect: (symbol: string) => void;
}) {
  const [open, setOpen] = useState(false);
  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-5">
      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Market</label>
      <div className="relative">
        <button
          onClick={() => setOpen(!open)}
          className="w-full flex items-center justify-between px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white hover:border-brand-500 dark:hover:border-brand-600 transition-all"
        >
          <span className="flex items-center gap-2">
            <span className="w-6 h-6 rounded-full bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center text-[10px] font-bold text-white">
              {selected?.base_symbol[0] ?? '?'}
            </span>
            <span className="font-semibold">{selected?.market_symbol ?? 'Select a market'}</span>
          </span>
          <ChevronDown className="w-4 h-4 text-gray-400" />
        </button>
        {open && (
          <div className="absolute top-full left-0 right-0 mt-1 rounded-xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-xl overflow-hidden z-10 max-h-64 overflow-y-auto scrollbar-hide">
            {markets.map((m) => (
              <button
                key={m.market_id}
                onClick={() => {
                  onSelect(m.market_symbol);
                  setOpen(false);
                }}
                className="w-full flex items-center gap-3 px-4 py-2.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-white/5 transition-colors text-left"
              >
                <span className="w-6 h-6 rounded-full bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center text-[10px] font-bold text-white">
                  {m.base_symbol[0]}
                </span>
                <span className="font-semibold">{m.market_symbol}</span>
                <span className="text-xs text-gray-500 dark:text-gray-400">{m.environment}</span>
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function OrderForm({
  market,
  best,
  balances,
  onPlaced,
}: {
  market: MarketRow;
  best: QueryResult<BestRow[]>;
  balances: QueryResult<BalanceRow[]>;
  onPlaced: () => void;
}) {
  const [side, setSide] = useState<'buy' | 'sell'>('buy');
  const [orderType, setOrderType] = useState<'limit' | 'market'>('limit');
  const [price, setPrice] = useState('');
  const [amount, setAmount] = useState('');
  const [tif, setTif] = useState<'gtc' | 'ioc' | 'fok'>('gtc');
  const [submitting, setSubmitting] = useState(false);
  const [result, setResult] = useState<PlaceOrderResult | null>(null);
  const [error, setError] = useState<string | null>(null);

  const bestRow = best.state.status === 'ready'
    ? best.state.data.find((b) => b.market_id === market.market_id)
    : undefined;
  const lastPrice = bestRow?.last_price_units;

  // Reset the form when the market changes.
  useEffect(() => {
    setResult(null);
    setError(null);
    setAmount('');
    setPrice(lastPrice ? formatUnits(lastPrice, market.price_scale, market.price_scale) : '');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [market.market_id]);

  const balanceRows = balances.state.status === 'ready' ? balances.state.data : [];
  const baseBalance = balanceRows.find((b) => b.symbol === market.base_symbol);
  const quoteBalance = balanceRows.find((b) => b.symbol === market.quote_symbol);

  const priceUnits = parseUnits(price || '0', market.price_scale);
  const qtyUnits = parseUnits(amount || '0', market.base_decimals);
  const totalQuote =
    priceUnits !== null && qtyUnits !== null
      ? notionalUnits(qtyUnits, priceUnits, market.notional_scale)
      : null;

  const validation: string | null = (() => {
    if (orderType === 'limit' && (priceUnits === null || priceUnits === 0n)) {
      return `Enter a price with at most ${market.price_scale} decimals.`;
    }
    if (qtyUnits === null || qtyUnits === 0n) {
      return `Enter an amount with at most ${market.base_decimals} decimals.`;
    }
    if (qtyUnits < units(market.min_qty_units) && units(market.min_qty_units) > 0n) {
      return `Minimum order size is ${formatUnits(market.min_qty_units, market.base_decimals)} ${market.base_symbol}.`;
    }
    if (totalQuote !== null && units(market.min_notional_units) > 0n && totalQuote < units(market.min_notional_units)) {
      return `Minimum order value is ${formatUnits(market.min_notional_units, market.quote_decimals)} ${market.quote_symbol}.`;
    }
    return null;
  })();

  const applyPercent = (pct: number) => {
    if (!balanceRows.length) return;
    if (side === 'sell') {
      const available = units(baseBalance?.available_units);
      const qty = (available * BigInt(pct)) / 100n;
      setAmount(formatUnits(qty, market.base_decimals, market.base_decimals));
      return;
    }
    const availableQuote = units(quoteBalance?.available_units);
    const usable = (availableQuote * BigInt(pct)) / 100n;
    const priceForSize = priceUnits ?? units(lastPrice);
    if (priceForSize === 0n) return;
    // qty_units = quote_units * 10^notional_scale / price_units
    const qty = (usable * 10n ** BigInt(market.notional_scale)) / priceForSize;
    setAmount(formatUnits(qty, market.base_decimals, market.base_decimals));
  };

  const submit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError(null);
    setResult(null);
    if (validation) {
      setError(validation);
      return;
    }
    if (qtyUnits === null) return;
    setSubmitting(true);
    try {
      const placed = await placeOrder({
        marketSymbol: market.market_symbol,
        side,
        type: orderType,
        qtyUnits,
        priceUnits: orderType === 'limit' ? priceUnits : null,
        timeInForce: orderType === 'market' ? 'ioc' : tif,
      });
      setResult(placed);
      onPlaced();
    } catch (err) {
      const failure = toApiFailure(err);
      setError(failure.message + (failure.detail ? ` (${failure.detail})` : ''));
    } finally {
      setSubmitting(false);
    }
  };

  if (result) {
    const filled = units(result.filled_qty_units);
    const rejected = result.status === 'rejected';
    return (
      <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6 text-center">
        <div
          className={`w-12 h-12 rounded-full flex items-center justify-center mx-auto mb-3 ${
            rejected ? 'bg-red-50 dark:bg-red-500/10' : 'bg-green-50 dark:bg-green-500/10'
          }`}
        >
          {rejected ? (
            <AlertCircle className="w-6 h-6 text-red-500" />
          ) : (
            <Check className="w-6 h-6 text-green-500" />
          )}
        </div>
        <p className="text-sm font-semibold text-gray-900 dark:text-white mb-1">
          {rejected ? 'Order rejected' : `Order ${result.status}`}
        </p>
        <p className="text-xs text-gray-500 dark:text-gray-400 mb-1">
          {result.market} · {result.side} · {result.type?.toUpperCase()} · {result.environment} environment
        </p>
        <p className="text-xs text-gray-500 dark:text-gray-400 mb-4">
          Filled {formatUnits(result.filled_qty_units, market.base_decimals)} of{' '}
          {formatUnits(result.qty_units, market.base_decimals)} {market.base_symbol}
          {rejected && result.reject_reason ? ` · reason: ${result.reject_reason}` : ''}
        </p>
        <button
          onClick={() => setResult(null)}
          className="text-sm font-medium text-brand-600 dark:text-brand-400 hover:text-brand-700 dark:hover:text-brand-300 transition-colors"
        >
          Place another order
        </button>
      </div>
    );
  }

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-5">
      <div className="flex gap-1 p-1 rounded-xl bg-gray-100 dark:bg-white/5 mb-5">
        <button
          onClick={() => setSide('buy')}
          className={`flex-1 py-2.5 text-sm font-semibold rounded-lg transition-all ${
            side === 'buy'
              ? 'bg-green-500 text-white shadow-sm'
              : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200'
          }`}
        >
          Buy
        </button>
        <button
          onClick={() => setSide('sell')}
          className={`flex-1 py-2.5 text-sm font-semibold rounded-lg transition-all ${
            side === 'sell'
              ? 'bg-red-500 text-white shadow-sm'
              : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200'
          }`}
        >
          Sell
        </button>
      </div>

      <form onSubmit={submit} className="space-y-4">
        <div className="flex gap-2">
          {(['limit', 'market'] as const).map((t) => (
            <button
              key={t}
              type="button"
              onClick={() => setOrderType(t)}
              className={`flex-1 py-1.5 text-xs font-medium rounded-lg transition-colors ${
                orderType === t
                  ? 'bg-brand-50 dark:bg-brand-950/40 text-brand-700 dark:text-brand-300 border border-brand-200/40 dark:border-brand-800/30'
                  : 'bg-gray-100 dark:bg-white/5 text-gray-500 dark:text-gray-400 border border-transparent'
              }`}
            >
              {t === 'limit' ? 'Limit' : 'Market'}
            </button>
          ))}
        </div>

        {error && (
          <div className="flex items-start gap-2 rounded-xl bg-red-50 dark:bg-red-500/10 border border-red-200/40 dark:border-red-500/20 px-3 py-2.5">
            <AlertCircle className="w-4 h-4 text-red-600 dark:text-red-400 shrink-0 mt-0.5" />
            <span className="text-xs text-red-700 dark:text-red-300 leading-relaxed">{error}</span>
          </div>
        )}

        <div>
          <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1.5">
            Price ({market.quote_symbol})
          </label>
          <input
            type="text"
            inputMode="decimal"
            disabled={orderType === 'market'}
            value={orderType === 'market' ? '' : price}
            onChange={(e) => setPrice(e.target.value)}
            placeholder={orderType === 'market' ? 'executes at the book price' : '0.00'}
            className="w-full px-4 py-2.5 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all disabled:opacity-60"
          />
        </div>

        <div>
          <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1.5">
            Amount ({market.base_symbol})
          </label>
          <input
            type="text"
            inputMode="decimal"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder="0.00"
            className="w-full px-4 py-2.5 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
          />
          <p className="text-[11px] text-gray-400 dark:text-gray-500 mt-1">
            Available: {side === 'sell'
              ? `${formatUnits(baseBalance?.available_units, market.base_decimals)} ${market.base_symbol}`
              : `${formatUnits(quoteBalance?.available_units, market.quote_decimals)} ${market.quote_symbol}`}
          </p>
        </div>

        <div className="flex gap-2">
          {[25, 50, 75, 100].map((pct) => (
            <button
              key={pct}
              type="button"
              onClick={() => applyPercent(pct)}
              className="flex-1 py-1.5 text-xs font-medium rounded-lg bg-gray-100 dark:bg-white/5 text-gray-500 dark:text-gray-400 hover:bg-brand-50 dark:hover:bg-brand-950/40 hover:text-brand-600 dark:hover:text-brand-400 transition-colors"
            >
              {pct}%
            </button>
          ))}
        </div>

        {orderType === 'limit' && (
          <div className="flex gap-2">
            {(['gtc', 'ioc', 'fok'] as const).map((t) => (
              <button
                key={t}
                type="button"
                onClick={() => setTif(t)}
                className={`flex-1 py-1.5 text-xs font-medium rounded-lg transition-colors ${
                  tif === t
                    ? 'bg-brand-50 dark:bg-brand-950/40 text-brand-700 dark:text-brand-300 border border-brand-200/40 dark:border-brand-800/30'
                    : 'bg-gray-100 dark:bg-white/5 text-gray-500 dark:text-gray-400 border border-transparent'
                }`}
              >
                {t.toUpperCase()}
              </button>
            ))}
          </div>
        )}

        <div className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 px-4 py-3 text-xs text-gray-500 dark:text-gray-400 flex justify-between">
          <span>Total (engine notional)</span>
          <span className="font-semibold text-gray-900 dark:text-white">
            {totalQuote === null
              ? '—'
              : `${formatUnits(totalQuote, market.quote_decimals, market.quote_decimals)} ${market.quote_symbol}`}
          </span>
        </div>

        <button
          type="submit"
          disabled={submitting || Boolean(validation)}
          className={`w-full py-3.5 text-sm font-semibold text-white rounded-xl transition-all disabled:opacity-60 disabled:cursor-not-allowed ${
            side === 'buy' ? 'bg-green-500 hover:bg-green-600' : 'bg-red-500 hover:bg-red-600'
          }`}
        >
          {submitting ? (
            <span className="inline-flex items-center gap-2">
              <Loader2 className="w-4 h-4 animate-spin" /> Placing…
            </span>
          ) : (
            `${side === 'buy' ? 'Buy' : 'Sell'} ${market.base_symbol}`
          )}
        </button>
        {validation && amount !== '' && (
          <p className="text-[11px] text-amber-600 dark:text-amber-400">{validation}</p>
        )}
      </form>
    </div>
  );
}

function MarketHeader({
  market,
  best,
  stats,
}: {
  market: MarketRow;
  best: QueryResult<BestRow[]>;
  stats: QueryResult<MarketStatsRow[]>;
}) {
  const bestRow = best.state.status === 'ready'
    ? best.state.data.find((b) => b.market_id === market.market_id)
    : undefined;
  const statsRow = stats.state.status === 'ready'
    ? stats.state.data.find((s) => s.market_id === market.market_id)
    : undefined;

  const last = units(statsRow?.last_price_units ?? bestRow?.last_price_units);
  const open = units(statsRow?.open_price_units);
  const changePct = open > 0n && last > 0n ? (Number(last - open) / Number(open)) * 100 : null;

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-3">
          <span className="w-8 h-8 rounded-full bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center text-xs font-bold text-white">
            {market.base_symbol[0]}
          </span>
          <div>
            <span className="text-sm font-semibold text-gray-900 dark:text-white">{market.market_symbol}</span>
            <span className="text-xs text-gray-500 dark:text-gray-400 ml-2">
              {last > 0n ? formatUnits(last, market.price_scale, 8) : 'no trades yet'}
            </span>
          </div>
        </div>
        {changePct !== null && (
          <span className={`text-sm font-medium ${changePct >= 0 ? 'text-green-500' : 'text-red-500'}`}>
            {changePct >= 0 ? '+' : ''}{changePct.toFixed(2)}%
          </span>
        )}
      </div>
      <div className="grid grid-cols-3 gap-3 text-xs">
        <div className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 px-3 py-2">
          <p className="text-gray-500 dark:text-gray-400 mb-0.5">Best bid</p>
          <p className="font-semibold text-gray-900 dark:text-white">
            {units(bestRow?.best_bid_units) > 0n ? formatUnits(bestRow?.best_bid_units, market.price_scale, 8) : '—'}
          </p>
        </div>
        <div className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 px-3 py-2">
          <p className="text-gray-500 dark:text-gray-400 mb-0.5">Best ask</p>
          <p className="font-semibold text-gray-900 dark:text-white">
            {units(bestRow?.best_ask_units) > 0n ? formatUnits(bestRow?.best_ask_units, market.price_scale, 8) : '—'}
          </p>
        </div>
        <div className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 px-3 py-2">
          <p className="text-gray-500 dark:text-gray-400 mb-0.5">24h volume</p>
          <p className="font-semibold text-gray-900 dark:text-white">
            {units(statsRow?.volume_quote_units) > 0n
              ? formatUnits(statsRow?.volume_quote_units, market.quote_decimals, 2)
              : '—'}
          </p>
        </div>
      </div>
      <div className="h-32 mt-4 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 flex items-center justify-center">
        <p className="text-xs text-gray-400 dark:text-gray-600">
          Price chart needs a candles/reference-price feed — not configured yet
        </p>
      </div>
    </div>
  );
}

function OrderBookPanel({ market, depth }: { market: MarketRow; depth: QueryResult<DepthRow[]> }) {
  const rows = depth.state.status === 'ready' ? depth.state.data : [];
  const asks = rows
    .filter((r) => r.side === 'sell')
    .sort((a, b) => (units(a.price_units) < units(b.price_units) ? -1 : 1))
    .slice(0, 8);
  const bids = rows
    .filter((r) => r.side === 'buy')
    .sort((a, b) => (units(a.price_units) > units(b.price_units) ? -1 : 1))
    .slice(0, 8);

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
      <div className="flex items-center justify-between mb-4">
        <h3 className="text-sm font-semibold text-gray-900 dark:text-white">Order Book</h3>
        <span className="text-[11px] text-gray-400 dark:text-gray-500">
          {depth.state.status === 'ready' ? 'live from the exchange book' : ''}
        </span>
      </div>

      {depth.state.status === 'loading' ? (
        <LoadingBlock label="Loading order book…" compact />
      ) : depth.state.status === 'unavailable' ? (
        <UnavailableBlock failure={depth.state.failure} onRetry={depth.reload} compact />
      ) : depth.state.status === 'error' ? (
        <ErrorBlock failure={depth.state.failure} onRetry={depth.reload} compact />
      ) : asks.length === 0 && bids.length === 0 ? (
        <EmptyState
          title="The book is empty"
          description="No resting orders on this market yet. A limit order you place will rest here."
          compact
        />
      ) : (
        <>
          <div className="grid grid-cols-3 gap-2 text-xs font-medium text-gray-500 dark:text-gray-400 mb-2 px-2">
            <span>Price ({market.quote_symbol})</span>
            <span className="text-right">Amount ({market.base_symbol})</span>
            <span className="text-right">Total</span>
          </div>
          <div className="space-y-1">
            {[...asks].reverse().map((r, i) => (
              <DepthLine key={`a-${i}`} row={r} market={market} />
            ))}
            {asks.length > 0 && bids.length > 0 && (
              <div className="h-px bg-gray-100 dark:bg-white/5 my-1" />
            )}
            {bids.map((r, i) => (
              <DepthLine key={`b-${i}`} row={r} market={market} />
            ))}
          </div>
        </>
      )}
    </div>
  );
}

function DepthLine({ row, market }: { row: DepthRow; market: MarketRow }) {
  const total = notionalUnits(row.qty_units, row.price_units, market.notional_scale);
  const isSell = row.side === 'sell';
  return (
    <div className="grid grid-cols-3 gap-2 text-xs px-2 py-1.5 rounded-lg hover:bg-gray-50 dark:hover:bg-white/5 transition-colors">
      <span className={`flex items-center gap-1 font-medium ${isSell ? 'text-red-500' : 'text-green-500'}`}>
        {isSell ? <TrendingDown className="w-3 h-3" /> : <TrendingUp className="w-3 h-3" />}
        {formatUnits(row.price_units, market.price_scale, 8)}
      </span>
      <span className="text-right text-gray-600 dark:text-gray-300">
        {formatUnits(row.qty_units, market.base_decimals, 8)}
      </span>
      <span className="text-right text-gray-500 dark:text-gray-400">
        {formatUnits(total, market.quote_decimals, 2)}
      </span>
    </div>
  );
}

function MyOrders({
  orders,
  market,
  onChanged,
}: {
  orders: QueryResult<OrderRow[]>;
  market: MarketRow | null;
  onChanged: () => void;
}) {
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const rows = orders.state.status === 'ready' ? orders.state.data : [];
  const open = rows.filter((o) => o.status === 'new' || o.status === 'partially_filled');

  const cancel = async (id: string) => {
    setBusyId(id);
    setError(null);
    try {
      await cancelOrder(id);
      onChanged();
    } catch (err) {
      const failure = toApiFailure(err);
      setError(failure.message + (failure.detail ? ` (${failure.detail})` : ''));
    } finally {
      setBusyId(null);
    }
  };

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
      <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-4">My Open Orders</h3>

      {error && (
        <div className="mb-3 flex items-start gap-2 rounded-xl bg-red-50 dark:bg-red-500/10 border border-red-200/40 dark:border-red-500/20 px-3 py-2.5">
          <AlertCircle className="w-4 h-4 text-red-600 dark:text-red-400 shrink-0 mt-0.5" />
          <span className="text-xs text-red-700 dark:text-red-300">{error}</span>
        </div>
      )}

      {orders.state.status === 'loading' ? (
        <LoadingBlock label="Loading your orders…" compact />
      ) : orders.state.status === 'unavailable' ? (
        <UnavailableBlock failure={orders.state.failure} onRetry={orders.reload} compact />
      ) : orders.state.status === 'error' ? (
        <ErrorBlock failure={orders.state.failure} onRetry={orders.reload} compact />
      ) : open.length === 0 ? (
        <EmptyState title="No open orders" description="Orders you place that rest in the book appear here." compact />
      ) : (
        <div className="space-y-2">
          {open.map((o) => (
            <div
              key={o.id}
              className="flex items-center justify-between gap-3 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 px-3 py-2.5"
            >
              <div className="min-w-0">
                <p className="text-xs font-semibold text-gray-900 dark:text-white">
                  <span className={o.side === 'buy' ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'}>
                    {o.side.toUpperCase()}
                  </span>{' '}
                  {formatUnits(o.qty_units, market?.base_decimals ?? 8, 8)} @{' '}
                  {o.price_units ? formatUnits(o.price_units, market?.price_scale ?? 8, 8) : 'market'}
                </p>
                <p className="text-[11px] text-gray-500 dark:text-gray-400">
                  {o.status} · filled {formatUnits(o.filled_qty_units, market?.base_decimals ?? 8, 8)} ·{' '}
                  {new Date(o.created_at).toLocaleString()}
                </p>
              </div>
              <button
                onClick={() => cancel(o.id)}
                disabled={busyId === o.id}
                className="shrink-0 inline-flex items-center gap-1 px-2.5 py-1.5 text-[11px] font-medium rounded-lg bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 text-gray-600 dark:text-gray-300 hover:border-red-300 dark:hover:border-red-500/40 hover:text-red-600 dark:hover:text-red-400 transition-colors disabled:opacity-50"
              >
                {busyId === o.id ? <Loader2 className="w-3 h-3 animate-spin" /> : <X className="w-3 h-3" />}
                Cancel
              </button>
            </div>
          ))}
        </div>
      )}
      <p className="mt-3 flex items-start gap-1.5 text-[11px] text-gray-400 dark:text-gray-500">
        <Info className="w-3 h-3 mt-0.5 shrink-0" />
        Cancelling is gated by the same trading switch as placing, per the backend's mode gate.
      </p>
    </div>
  );
}
