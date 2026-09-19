import { ShieldCheck, Users, Lock, Zap } from 'lucide-react';
import { trustCards } from '@/data/mockData';
import { useReveal } from '@/hooks/useReveal';

const iconMap: Record<string, typeof ShieldCheck> = {
  'shield-check': ShieldCheck,
  users: Users,
  lock: Lock,
  zap: Zap,
};

export default function TrustSection() {
  const { ref, inView } = useReveal();

  return (
    <section id="trust" className="py-16 lg:py-24 bg-surface-light-2 dark:bg-surface-dark">
      <div
        ref={ref}
        className={`reveal ${inView ? 'in-view' : ''} max-w-7xl mx-auto px-4 sm:px-6 lg:px-8`}
      >
        <div className="text-center mb-12">
          <h2 className="text-3xl sm:text-4xl font-bold text-gray-900 dark:text-white mb-3">
            Why Traders Trust GlobalTradeVX
          </h2>
          <p className="text-gray-500 dark:text-gray-400 max-w-2xl mx-auto">
            Built on a foundation of security, transparency, and performance.
          </p>
        </div>

        <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-6">
          {trustCards.map((card, i) => {
            const Icon = iconMap[card.icon];
            return (
              <div
                key={card.title}
                className="group relative rounded-2xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/5 p-6 hover:border-brand-300 dark:hover:border-brand-600/40 transition-all duration-300 hover:-translate-y-1"
                style={{ transitionDelay: `${i * 50}ms` }}
              >
                <div className="absolute inset-0 rounded-2xl bg-gradient-to-br from-brand-500/0 to-brand-500/0 group-hover:from-brand-500/5 group-hover:to-brand-700/5 transition-all duration-300" />

                <div className="relative">
                  <div className="w-12 h-12 rounded-xl bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center mb-4 group-hover:glow-purple transition-all">
                    <Icon className="w-6 h-6 text-brand-600 dark:text-brand-400" />
                  </div>
                  <div className="text-xs font-medium text-gray-500 dark:text-gray-500 uppercase tracking-wider mb-1">
                    {card.title}
                  </div>
                  <div className="text-xl font-bold text-gray-900 dark:text-white mb-1">
                    {card.value}
                  </div>
                  <div className="text-sm text-brand-600 dark:text-brand-400 font-medium mb-3">
                    {card.sub}
                  </div>
                  <p className="text-sm text-gray-500 dark:text-gray-400 leading-relaxed">
                    {card.description}
                  </p>
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
