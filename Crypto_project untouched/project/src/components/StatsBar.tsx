import { statsData } from '@/data/mockData';
import { useReveal, useCountUp } from '@/hooks/useReveal';

function StatItem({ stat, start }: { stat: typeof statsData[0]; start: boolean }) {
  const value = useCountUp(stat.value, 2000, start);

  const displayValue = stat.value < 10
    ? value.toFixed(2)
    : Math.round(value).toString();

  return (
    <div className="text-center">
      <div className="text-3xl sm:text-4xl lg:text-5xl font-bold text-gradient">
        {stat.prefix}{displayValue}{stat.suffix}
      </div>
      <div className="mt-2 text-sm text-gray-500 dark:text-gray-400 font-medium">
        {stat.label}
      </div>
    </div>
  );
}

export default function StatsBar() {
  const { ref, inView } = useReveal();

  return (
    <section className="relative py-12 lg:py-16 bg-gradient-to-r from-brand-700 via-brand-600 to-brand-700 overflow-hidden">
      <div className="absolute inset-0 grid-bg opacity-20" />
      <div className="absolute top-0 left-1/2 -translate-x-1/2 w-[800px] h-[200px] bg-white/10 rounded-full blur-[100px]" />

      <div
        ref={ref}
        className="relative max-w-7xl mx-auto px-4 sm:px-6 lg:px-8"
      >
        <div className="grid grid-cols-2 lg:grid-cols-4 gap-8">
          {statsData.map((stat) => (
            <StatItem key={stat.label} stat={stat} start={inView} />
          ))}
        </div>
      </div>
    </section>
  );
}
