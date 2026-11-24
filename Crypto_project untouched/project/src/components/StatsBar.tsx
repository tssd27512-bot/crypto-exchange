import { BarChart3 } from 'lucide-react';
import { useReveal } from '@/hooks/useReveal';

/**
 * Landing-page statistics band.
 *
 * This used to count up hardcoded trading-volume and user figures. Those were
 * never real, so they are gone: the band now states plainly that no statistics
 * exist yet. Nothing here is simulated.
 */
export default function StatsBar() {
  const { ref, inView } = useReveal();

  return (
    <section className="relative py-12 lg:py-16 bg-gradient-to-r from-brand-700 via-brand-600 to-brand-700 overflow-hidden">
      <div className="absolute inset-0 grid-bg opacity-20" />
      <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[800px] h-[200px] bg-white/10 rounded-full blur-[100px]" />

      <div
        ref={ref}
        className={`relative max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 reveal ${inView ? 'in-view' : ''}`}
      >
        <div className="flex flex-col items-center text-center">
          <div className="w-12 h-12 rounded-full bg-white/10 border border-white/15 flex items-center justify-center mb-3">
            <BarChart3 className="w-6 h-6 text-white/80" />
          </div>
          <p className="text-lg sm:text-xl font-semibold text-white">
            Platform statistics not available yet
          </p>
          <p className="mt-2 text-sm text-white/70 max-w-xl">
            Trading volume, user counts and market data are not shown because the exchange backend
            is not deployed and a market-data provider is not configured yet.
          </p>
        </div>
      </div>
    </section>
  );
}
