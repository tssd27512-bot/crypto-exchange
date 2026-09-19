import { useState } from 'react';
import { Link } from 'react-router-dom';
import {
  ChevronDown, TrendingUp, TrendingDown, Info, Check,
} from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import { dashboardMarketData } from '@/data/mockData';

function formatPrice(price: number) {
  if (price < 1) return `$${price.toFixed(4)}`;
  if (price < 100) return `$${price.toFixed(2)}`;
  return `$${price.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function Trade() {
  const [side, setSide] = useState<'buy' | 'sell'>('buy');
  const [selectedCoin, setSelectedCoin] = useState(dashboardMarketData[0]);
  const [coinDropdown, setCoinDropdown] = useState(false);
  const [amount, setAmount] = useState('');
  const [price, setPrice] = useState(selectedCoin.price.toString());
  const [confirmed, setConfirmed] = useState(false);

  const mockOrderBook = [
    { price: selectedCoin.price * 1.002, amount: 0.5, side: 'sell' as const },
    { price: selectedCoin.price * 1.001, amount: 1.2, side: 'sell' as const },
    { price: selectedCoin.price * 1.0005, amount: 0.8, side: 'sell' as const },
    { price: selectedCoin.price * 0.9995, amount: 1.5, side: 'buy' as const },
    { price: selectedCoin.price * 0.999, amount: 2.0, side: 'buy' as const },
    { price: selectedCoin.price * 0.998, amount: 0.7, side: 'buy' as const },
  ];

  return (
    <DashboardLayout title="Trade">
      <PageHeader title="Trade" subtitle="Place orders across 800+ markets" />

      <div className="grid lg:grid-cols-3 gap-6">
        {/* Left: Order form */}
        <div className="lg:col-span-1 space-y-4">
          {/* Coin selector */}
          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-5">
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Market</label>
            <div className="relative">
              <button
                onClick={() => setCoinDropdown(!coinDropdown)}
                className="w-full flex items-center justify-between px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white hover:border-brand-500 dark:hover:border-brand-600 transition-all"
              >
                <span className="flex items-center gap-2">
                  <span
                    className="w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold text-white"
                    style={{ backgroundColor: selectedCoin.color }}
                  >
                    {selectedCoin.symbol[0]}
                  </span>
                  <span className="font-semibold">{selectedCoin.symbol}/USDT</span>
                </span>
                <ChevronDown className="w-4 h-4 text-gray-400" />
              </button>
              {coinDropdown && (
                <div className="absolute top-full left-0 right-0 mt-1 rounded-xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-xl overflow-hidden z-10 max-h-64 overflow-y-auto scrollbar-hide">
                  {dashboardMarketData.map((coin) => (
                    <button
                      key={coin.symbol}
                      onClick={() => {
                        setSelectedCoin(coin);
                        setPrice(coin.price.toString());
                        setCoinDropdown(false);
                      }}
                      className="w-full flex items-center gap-3 px-4 py-2.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-white/5 transition-colors text-left"
                    >
                      <span
                        className="w-6 h-6 rounded-full flex items-center justify-center text-[10px] font-bold text-white"
                        style={{ backgroundColor: coin.color }}
                      >
                        {coin.symbol[0]}
                      </span>
                      <span className="font-semibold w-12">{coin.symbol}</span>
                      <span className="text-gray-500 dark:text-gray-400">{coin.name}</span>
                    </button>
                  ))}
                </div>
              )}
            </div>
          </div>

          {/* Buy/Sell tabs */}
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

            {confirmed ? (
              <div className="text-center py-6">
                <div className="w-12 h-12 rounded-full bg-green-50 dark:bg-green-500/10 flex items-center justify-center mx-auto mb-3">
                  <Check className="w-6 h-6 text-green-500" />
                </div>
                <p className="text-sm font-semibold text-gray-900 dark:text-white mb-1">Order Placed (Demo)</p>
                <p className="text-xs text-gray-500 dark:text-gray-400 mb-4">
                  This is a demo — no real order was executed.
                </p>
                <button
                  onClick={() => setConfirmed(false)}
                  className="text-sm font-medium text-brand-600 dark:text-brand-400 hover:text-brand-700 dark:hover:text-brand-300 transition-colors"
                >
                  Place another order
                </button>
              </div>
            ) : (
              <form
                onSubmit={(e) => {
                  e.preventDefault();
                  setConfirmed(true);
                }}
                className="space-y-4"
              >
                <div>
                  <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1.5">Price (USDT)</label>
                  <input
                    type="number"
                    required
                    value={price}
                    onChange={(e) => setPrice(e.target.value)}
                    className="w-full px-4 py-2.5 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                  />
                </div>
                <div>
                  <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1.5">Amount ({selectedCoin.symbol})</label>
                  <input
                    type="number"
                    required
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    placeholder="0.00"
                    className="w-full px-4 py-2.5 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                  />
                </div>
                <div className="flex gap-2">
                  {['25%', '50%', '75%', '100%'].map((pct) => (
                    <button
                      key={pct}
                      type="button"
                      className="flex-1 py-1.5 text-xs font-medium rounded-lg bg-gray-100 dark:bg-white/5 text-gray-500 dark:text-gray-400 hover:bg-brand-50 dark:hover:bg-brand-950/40 hover:text-brand-600 dark:hover:text-brand-400 transition-colors"
                    >
                      {pct}
                    </button>
                  ))}
                </div>
                <div className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 px-4 py-3 text-xs text-gray-500 dark:text-gray-400 flex justify-between">
                  <span>Total</span>
                  <span className="font-semibold text-gray-900 dark:text-white">
                    ${((parseFloat(amount) || 0) * (parseFloat(price) || 0)).toFixed(2)} USDT
                  </span>
                </div>
                <button
                  type="submit"
                  className={`w-full py-3.5 text-sm font-semibold text-white rounded-xl transition-all ${
                    side === 'buy'
                      ? 'bg-green-500 hover:bg-green-600'
                      : 'bg-red-500 hover:bg-red-600'
                  }`}
                >
                  {side === 'buy' ? 'Buy' : 'Sell'} {selectedCoin.symbol}
                </button>
              </form>
            )}
          </div>
        </div>

        {/* Right: Chart + Order book */}
        <div className="lg:col-span-2 space-y-4">
          {/* Price chart placeholder */}
          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
            <div className="flex items-center justify-between mb-4">
              <div className="flex items-center gap-3">
                <span
                  className="w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold text-white"
                  style={{ backgroundColor: selectedCoin.color }}
                >
                  {selectedCoin.symbol[0]}
                </span>
                <div>
                  <span className="text-sm font-semibold text-gray-900 dark:text-white">{selectedCoin.symbol}/USDT</span>
                  <span className="text-xs text-gray-500 dark:text-gray-400 ml-2">{formatPrice(selectedCoin.price)}</span>
                </div>
              </div>
              <span className={`text-sm font-medium ${selectedCoin.change24h >= 0 ? 'text-green-500' : 'text-red-500'}`}>
                {selectedCoin.change24h >= 0 ? '+' : ''}{selectedCoin.change24h.toFixed(2)}%
              </span>
            </div>
            <div className="h-48 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 flex items-center justify-center">
              <p className="text-sm text-gray-400 dark:text-gray-600">Price chart placeholder</p>
            </div>
          </div>

          {/* Order book */}
          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-4">Order Book</h3>
            <div className="grid grid-cols-3 gap-2 text-xs font-medium text-gray-500 dark:text-gray-400 mb-2 px-2">
              <span>Price (USDT)</span>
              <span className="text-right">Amount</span>
              <span className="text-right">Total</span>
            </div>
            <div className="space-y-1">
              {mockOrderBook.map((order, i) => (
                <div key={i} className="grid grid-cols-3 gap-2 text-xs px-2 py-1.5 rounded-lg hover:bg-gray-50 dark:hover:bg-white/5 transition-colors">
                  <span className={`flex items-center gap-1 font-medium ${order.side === 'sell' ? 'text-red-500' : 'text-green-500'}`}>
                    {order.side === 'sell' ? <TrendingDown className="w-3 h-3" /> : <TrendingUp className="w-3 h-3" />}
                    {formatPrice(order.price)}
                  </span>
                  <span className="text-right text-gray-600 dark:text-gray-300">{order.amount.toFixed(4)}</span>
                  <span className="text-right text-gray-500 dark:text-gray-400">{formatPrice(order.price * order.amount)}</span>
                </div>
              ))}
            </div>
          </div>

          {/* Demo note */}
          <div className="flex items-start gap-2 rounded-xl bg-brand-50 dark:bg-brand-950/30 border border-brand-200/30 dark:border-brand-800/20 px-4 py-3">
            <Info className="w-4 h-4 text-brand-600 dark:text-brand-400 shrink-0 mt-0.5" />
            <p className="text-xs text-brand-700 dark:text-brand-300 leading-relaxed">
              This is a demo trading interface. No real orders are executed and no real funds are involved.
            </p>
          </div>
        </div>
      </div>
    </DashboardLayout>
  );
}
