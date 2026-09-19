import { Zap, BarChart3, Layers, Globe2 } from 'lucide-react';
import { features } from '@/data/mockData';
import { useReveal } from '@/hooks/useReveal';

const iconMap: Record<string, typeof Zap> = {
  zap: Zap,
  'bar-chart': BarChart3,
  globe: Globe2,
  earth: Layers,
};

export default function FeaturesGrid() {
  const { ref, inView } = useReveal();

  return (
    <section className="py-16 lg:py-24 bg-surface-light dark:bg-surface-dark-2">
      <div
        ref={ref}
        className={`reveal ${inView ? 'in-view' : ''} max-w-7xl mx-auto px-4 sm:px-6 lg:px-8`}
      >
        <div className="text-center mb-12">
          <h2 className="text-3xl sm:text-4xl font-bold text-gray-900 dark:text-white mb-3">
            A Platform Built for Performance
          </h2>
          <p className="text-gray-500 dark:text-gray-400 max-w-2xl mx-auto">
            Everything you need to trade efficiently, with tools designed for serious traders.
          </p>
        </div>

        <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-6">
          {features.map((feature, i) => {
            const Icon = iconMap[feature.icon];
            return (
              <div
                key={feature.title}
                className="group relative rounded-2xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/5 p-6 hover:border-brand-300 dark:hover:border-brand-600/40 transition-all duration-300 hover:-translate-y-1"
              >
                <div className="w-14 h-14 rounded-2xl bg-gradient-to-br from-brand-500/10 to-brand-700/10 dark:from-brand-500/15 dark:to-brand-700/15 flex items-center justify-center mb-5 group-hover:from-brand-500/20 group-hover:to-brand-700/20 transition-all">
                  <Icon className="w-7 h-7 text-brand-600 dark:text-brand-400" />
                </div>
                <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
                  {feature.title}
                </h3>
                <p className="text-sm text-gray-500 dark:text-gray-400 leading-relaxed">
                  {feature.description}
                </p>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
