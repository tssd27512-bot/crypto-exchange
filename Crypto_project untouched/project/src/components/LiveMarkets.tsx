import { TrendingUp } from 'lucide-react';
import { useReveal } from '@/hooks/useReveal';
import { EmptyState } from '@/components/DataState';

/**
 * Landing-page market section.
 *
 * The exchange has no market-data provider configured and the backend is not
 * deployed, so there are no prices, 24h changes or volumes to show. Rather than
 * render invented numbers, this section states plainly that the data is not
 * available yet. The layout and styling are unchanged; only the data is gone.
 */
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
            <div className="w-2 h-2 rounded-full bg-gray-400 dark:bg-gray-500" />
            <span className="text-xs font-medium text-brand-700 dark:text-brand-300">Markets</span>
          </div>
          <h2 className="text-3xl sm:text-4xl font-bold text-gray-900 dark:text-white mb-3">
            Market Prices
          </h2>
          <p className="text-gray-500 dark:text-gray-400 max-w-2xl mx-auto">
            Prices and 24-hour performance across the listed assets will appear here once a
            market-data provider is configured.
          </p>
        </div>

        {/* Ticker strip — no feed, no figures */}
        <div className="relative mb-8 overflow-hidden rounded-xl border border-gray-200 dark:border-white/5 bg-white dark:bg-surface-dark-3 py-3">
          <div className="px-6 py-1 text-center">
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Market data not available yet
            </p>
            <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">
              A market-data provider is not configured yet, so no ticker is shown.
            </p>
          </div>
        </div>

        {/* Markets panel — honest empty state in place of the price table */}
        <div className="rounded-2xl border border-gray-200 dark:border-white/5 bg-white dark:bg-surface-dark-3 overflow-hidden card-glow">
          <div className="px-6 py-10">
            <EmptyState
              title="Market data not available yet"
              description="No prices, 24-hour change or volume are displayed because a market-data provider is not configured yet. Nothing here is simulated."
              icon={<TrendingUp className="w-6 h-6 text-gray-300 dark:text-gray-600" />}
            />
          </div>
        </div>
      </div>
    </section>
  );
}
