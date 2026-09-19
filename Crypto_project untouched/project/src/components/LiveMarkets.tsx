import { TrendingUp, TrendingDown } from 'lucide-react';
import { marketData } from '@/data/mockData';
import { useReveal } from '@/hooks/useReveal';

function formatPrice(price: number) {
  if (price < 1) return `$${price.toFixed(4)}`;
  if (price < 100) return `$${price.toFixed(2)}`;
  return `$${price.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function LiveMarkets() {
  const { ref, inView } = useReveal();

  return (
    <section id="markets" className="py-16 lg:py-24 bg-surface-light dark:bg-surface-dark-2">
      <div
        ref={ref}
        className={`reveal ${inView ? 'in-view' : ''} max-w-7xl mx-auto px-4 sm:px-6 lg:px-8`}
      >
        {/* Section header */}
        <div className="text-center mb-10">
          <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-brand-50 dark:bg-brand-950/40 border border-brand-200/40 dark:border-brand-800/30 mb-4">
            <div className="w-2 h-2 rounded-full bg-green-500 animate-pulse" />
            <span className="text-xs font-medium text-brand-700 dark:text-brand-300">Live Markets</span>
          </div>
          <h2 className="text-3xl sm:text-4xl font-bold text-gray-900 dark:text-white mb-3">
            Real-Time Market Prices
          </h2>
          <p className="text-gray-500 dark:text-gray-400 max-w-2xl mx-auto">
            Track live prices and 24-hour performance across top digital assets.
          </p>
        </div>

        {/* Scrolling ticker */}
        <div className="relative mb-8 overflow-hidden rounded-xl border border-gray-200 dark:border-white/5 bg-white dark:bg-surface-dark-3 py-3">
          <div className="flex gap-8 animate-ticker ticker-track whitespace-nowrap">
            {[...marketData, ...marketData].map((asset, i) => (
              <div key={i} className="flex items-center gap-2 px-4">
                <div
                  className="w-7 h-7 rounded-full flex items-center justify-center text-[10px] font-bold text-white shrink-0"
                  style={{ backgroundColor: asset.color }}
                >
                  {asset.symbol[0]}
                </div>
                <span className="text-sm font-medium text-gray-700 dark:text-gray-200">{asset.symbol}</span>
                <span className="text-sm text-gray-500 dark:text-gray-400">{formatPrice(asset.price)}</span>
                <span className={`text-sm font-medium ${asset.change24h >= 0 ? 'text-green-500' : 'text-red-500'}`}>
                  {asset.change24h >= 0 ? '+' : ''}{asset.change24h.toFixed(2)}%
                </span>
              </div>
            ))}
          </div>
          {/* Fade edges */}
          <div className="absolute left-0 top-0 bottom-0 w-12 bg-gradient-to-r from-white dark:from-surface-dark-3 to-transparent pointer-events-none" />
          <div className="absolute right-0 top-0 bottom-0 w-12 bg-gradient-to-l from-white dark:from-surface-dark-3 to-transparent pointer-events-none" />
        </div>

        {/* Markets table */}
        <div className="rounded-2xl border border-gray-200 dark:border-white/5 bg-white dark:bg-surface-dark-3 overflow-hidden card-glow">
          {/* Desktop table */}
          <div className="hidden md:block overflow-x-auto">
            <table className="w-full">
              <thead>
                <tr className="border-b border-gray-200 dark:border-white/5">
                  <th className="text-left px-6 py-4 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Asset</th>
                  <th className="text-right px-6 py-4 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Price</th>
                  <th className="text-right px-6 py-4 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">24h Change</th>
                  <th className="text-right px-6 py-4 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider">Volume</th>
                  <th className="text-right px-6 py-4 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider"></th>
                </tr>
              </thead>
              <tbody>
                {marketData.map((asset) => (
                  <tr
                    key={asset.symbol}
                    className="border-b border-gray-100 dark:border-white/5 last:border-0 hover:bg-gray-50 dark:hover:bg-white/5 transition-colors"
                  >
                    <td className="px-6 py-4">
                      <div className="flex items-center gap-3">
                        <div
                          className="w-9 h-9 rounded-full flex items-center justify-center text-xs font-bold text-white"
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
                    <td className="px-6 py-4 text-right text-sm font-semibold text-gray-900 dark:text-white">
                      {formatPrice(asset.price)}
                    </td>
                    <td className="px-6 py-4 text-right">
                      <span
                        className={`inline-flex items-center gap-1 text-sm font-medium px-2 py-1 rounded-md ${
                          asset.change24h >= 0
                            ? 'text-green-600 dark:text-green-400 bg-green-50 dark:bg-green-500/10'
                            : 'text-red-600 dark:text-red-400 bg-red-50 dark:bg-red-500/10'
                        }`}
                      >
                        {asset.change24h >= 0 ? <TrendingUp className="w-3.5 h-3.5" /> : <TrendingDown className="w-3.5 h-3.5" />}
                        {asset.change24h >= 0 ? '+' : ''}{asset.change24h.toFixed(2)}%
                      </span>
                    </td>
                    <td className="px-6 py-4 text-right text-sm text-gray-600 dark:text-gray-300">
                      {asset.volume}
                    </td>
                    <td className="px-6 py-4 text-right">
                      <a href="#" className="text-sm font-medium text-brand-600 dark:text-brand-400 hover:text-brand-700 dark:hover:text-brand-300 transition-colors">
                        Trade
                      </a>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Mobile cards */}
          <div className="md:hidden divide-y divide-gray-100 dark:divide-white/5">
            {marketData.map((asset) => (
              <div key={asset.symbol} className="p-4 flex items-center justify-between">
                <div className="flex items-center gap-3">
                  <div
                    className="w-9 h-9 rounded-full flex items-center justify-center text-xs font-bold text-white"
                    style={{ backgroundColor: asset.color }}
                  >
                    {asset.symbol[0]}
                  </div>
                  <div>
                    <div className="text-sm font-semibold text-gray-900 dark:text-white">{asset.symbol}</div>
                    <div className="text-xs text-gray-500 dark:text-gray-500">{formatPrice(asset.price)}</div>
                  </div>
                </div>
                <div className="text-right">
                  <div className={`text-sm font-medium ${asset.change24h >= 0 ? 'text-green-500' : 'text-red-500'}`}>
                    {asset.change24h >= 0 ? '+' : ''}{asset.change24h.toFixed(2)}%
                  </div>
                  <div className="text-xs text-gray-500 dark:text-gray-500">{asset.volume}</div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
