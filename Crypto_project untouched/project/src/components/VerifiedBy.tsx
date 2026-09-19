import { BadgeCheck } from 'lucide-react';
import { verifiedBy } from '@/data/mockData';
import { useReveal } from '@/hooks/useReveal';

export default function VerifiedBy() {
  const { ref, inView } = useReveal();

  return (
    <section className="py-12 lg:py-16 bg-surface-light-2 dark:bg-surface-dark border-y border-gray-200/50 dark:border-white/5">
      <div
        ref={ref}
        className={`reveal ${inView ? 'in-view' : ''} max-w-7xl mx-auto px-4 sm:px-6 lg:px-8`}
      >
        <p className="text-center text-sm font-medium text-gray-400 dark:text-gray-500 uppercase tracking-wider mb-8">
          Verified by Industry Leaders
        </p>
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-6">
          {verifiedBy.map((name) => (
            <div
              key={name}
              className="group flex items-center justify-center gap-2 py-4 px-6 rounded-xl border border-gray-200 dark:border-white/5 bg-white dark:bg-surface-dark-3 hover:border-brand-300 dark:hover:border-brand-600/30 transition-all"
            >
              <BadgeCheck className="w-5 h-5 text-gray-300 dark:text-gray-600 group-hover:text-brand-500 transition-colors" />
              <span className="text-base font-semibold text-gray-400 dark:text-gray-600 group-hover:text-gray-700 dark:group-hover:text-gray-300 transition-colors">
                {name}
              </span>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
