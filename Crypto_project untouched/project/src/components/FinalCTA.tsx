import { Link } from 'react-router-dom';
import { ArrowRight } from 'lucide-react';
import { useReveal } from '@/hooks/useReveal';

export default function FinalCTA() {
  const { ref, inView } = useReveal();

  return (
    <section id="compliance" className="py-16 lg:py-24 bg-surface-light dark:bg-surface-dark-2">
      <div
        ref={ref}
        className={`reveal ${inView ? 'in-view' : ''} max-w-7xl mx-auto px-4 sm:px-6 lg:px-8`}
      >
        <div className="relative rounded-3xl overflow-hidden bg-gradient-to-br from-brand-700 via-brand-600 to-brand-800 px-6 py-16 lg:px-16 lg:py-24 text-center">
          {/* Background effects */}
          <div className="absolute inset-0 grid-bg opacity-20" />
          <div className="absolute top-0 left-1/4 w-[300px] h-[300px] bg-white/10 rounded-full blur-[80px] animate-float" />
          <div className="absolute bottom-0 right-1/4 w-[250px] h-[250px] bg-brand-400/20 rounded-full blur-[80px] animate-float" style={{ animationDelay: '3s' }} />

          <div className="relative">
            <h2 className="text-3xl sm:text-4xl lg:text-5xl font-bold text-white mb-5 leading-tight">
              Ready to Trade with Confidence?
            </h2>
            <p className="text-lg text-brand-100 mb-8 max-w-2xl mx-auto">
              Join over 5 million traders worldwide. Create your free account and
              start trading in minutes.
            </p>
            <Link
              to="/sign-up"
              className="inline-flex items-center gap-2 px-8 py-4 text-base font-semibold text-brand-700 bg-white rounded-xl hover:bg-brand-50 transition-all hover:scale-[1.02] shadow-xl"
            >
              Start Trading
              <ArrowRight className="w-5 h-5" />
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}
