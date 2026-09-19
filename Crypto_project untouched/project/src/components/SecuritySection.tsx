import { Shield, Eye, Lock, Fingerprint } from 'lucide-react';
import { securityFeatures } from '@/data/mockData';
import { useReveal } from '@/hooks/useReveal';

const iconMap: Record<string, typeof Shield> = {
  shield: Shield,
  eye: Eye,
  'lock-keyhole': Lock,
  fingerprint: Fingerprint,
};

export default function SecuritySection() {
  const { ref, inView } = useReveal();

  return (
    <section id="security" className="py-16 lg:py-24 bg-surface-light-2 dark:bg-surface-dark relative overflow-hidden">
      <div className="absolute top-0 right-0 w-[500px] h-[500px] bg-brand-500/5 rounded-full blur-[120px]" />

      <div
        ref={ref}
        className={`reveal ${inView ? 'in-view' : ''} relative max-w-7xl mx-auto px-4 sm:px-6 lg:px-8`}
      >
        <div className="grid lg:grid-cols-2 gap-12 lg:gap-16 items-center">
          {/* Left: Heading + copy */}
          <div>
            <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-brand-50 dark:bg-brand-950/40 border border-brand-200/40 dark:border-brand-800/30 mb-5">
              <Shield className="w-4 h-4 text-brand-600 dark:text-brand-400" />
              <span className="text-xs font-medium text-brand-700 dark:text-brand-300">Security First</span>
            </div>
            <h2 className="text-3xl sm:text-4xl font-bold text-gray-900 dark:text-white mb-5 leading-tight">
              Security You Can{' '}
              <span className="text-gradient">Rely On</span>
            </h2>
            <p className="text-gray-600 dark:text-gray-400 mb-6 leading-relaxed">
              Our platform employs a multi-layered security framework designed to
              protect your assets at every level. With regular independent reviews
              and encrypted cold storage, we maintain the highest standards of
              protection for all users.
            </p>
            <a
              href="#"
              className="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-brand-600 dark:text-brand-400 border border-brand-200 dark:border-brand-700/40 rounded-lg hover:bg-brand-50 dark:hover:bg-brand-950/40 transition-all"
            >
              Learn More About Our Security
            </a>
          </div>

          {/* Right: Feature cards */}
          <div className="grid sm:grid-cols-2 gap-4">
            {securityFeatures.map((feature, i) => {
              const Icon = iconMap[feature.icon];
              return (
                <div
                  key={feature.title}
                  className="group rounded-2xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/5 p-5 hover:border-brand-300 dark:hover:border-brand-600/40 transition-all duration-300 hover:-translate-y-1"
                >
                  <div className="w-11 h-11 rounded-xl bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center mb-4 group-hover:glow-purple transition-all">
                    <Icon className="w-5 h-5 text-brand-600 dark:text-brand-400" />
                  </div>
                  <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-2 leading-snug">
                    {feature.title}
                  </h3>
                  <p className="text-xs text-gray-500 dark:text-gray-400 leading-relaxed">
                    {feature.description}
                  </p>
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </section>
  );
}
