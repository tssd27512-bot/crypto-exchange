import { UserPlus, CreditCard, TrendingUp, ArrowDownToLine } from 'lucide-react';
import { howItWorks } from '@/data/mockData';
import { useReveal } from '@/hooks/useReveal';

const iconMap: Record<string, typeof UserPlus> = {
  'user-plus': UserPlus,
  'credit-card': CreditCard,
  'trending-up': TrendingUp,
  'arrow-down-to-line': ArrowDownToLine,
};

export default function HowItWorks() {
  const { ref, inView } = useReveal();

  return (
    <section className="py-16 lg:py-24 bg-surface-light dark:bg-surface-dark-2">
      <div
        ref={ref}
        className={`reveal ${inView ? 'in-view' : ''} max-w-7xl mx-auto px-4 sm:px-6 lg:px-8`}
      >
        <div className="text-center mb-12">
          <h2 className="text-3xl sm:text-4xl font-bold text-gray-900 dark:text-white mb-3">
            Start Trading in 4 Simple Steps
          </h2>
          <p className="text-gray-500 dark:text-gray-400 max-w-2xl mx-auto">
            From sign-up to your first trade in minutes — no complexity, no friction.
          </p>
        </div>

        <div className="grid sm:grid-cols-2 lg:grid-cols-4 gap-6 relative">
          {/* Connecting line on desktop */}
          <div className="hidden lg:block absolute top-12 left-[12.5%] right-[12.5%] h-0.5 border-t-2 border-dashed border-gray-200 dark:border-white/10" />

          {howItWorks.map((step, i) => {
            const Icon = iconMap[step.icon];
            return (
              <div
                key={step.title}
                className="relative group text-center"
              >
                {/* Number badge */}
                <div className="relative inline-flex items-center justify-center mb-5">
                  <div className="w-12 h-12 rounded-full bg-white dark:bg-surface-dark-3 border-2 border-brand-200 dark:border-brand-700/40 flex items-center justify-center font-bold text-brand-600 dark:text-brand-400 text-lg group-hover:border-brand-500 group-hover:glow-purple transition-all">
                    {i + 1}
                  </div>
                </div>

                {/* Icon */}
                <div className="w-14 h-14 rounded-2xl bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center mx-auto mb-4 group-hover:scale-110 transition-transform">
                  <Icon className="w-7 h-7 text-brand-600 dark:text-brand-400" />
                </div>

                <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
                  {step.title}
                </h3>
                <p className="text-sm text-gray-500 dark:text-gray-400 leading-relaxed max-w-[220px] mx-auto">
                  {step.description}
                </p>
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
