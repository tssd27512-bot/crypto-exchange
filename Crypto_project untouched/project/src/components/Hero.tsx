import { Link } from 'react-router-dom';
import { ShieldCheck, ArrowRight, TrendingUp, Activity } from 'lucide-react';

export default function Hero() {
  return (
    <section
      id="hero"
      className="relative pt-28 lg:pt-36 pb-16 lg:pb-24 overflow-hidden bg-surface-light-2 dark:bg-surface-dark"
    >
      {/* Background effects */}
      <div className="absolute inset-0 grid-bg opacity-40" />
      <div className="absolute top-0 right-0 w-[600px] h-[600px] bg-brand-500/10 rounded-full blur-[120px]" />
      <div className="absolute bottom-0 left-0 w-[400px] h-[400px] bg-brand-700/10 rounded-full blur-[100px]" />

      <div className="relative max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="grid lg:grid-cols-2 gap-12 lg:gap-8 items-center">
          {/* Left: Content */}
          <div className="text-center lg:text-left">
            {/* Trust badge */}
            <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-brand-50 dark:bg-brand-950/50 border border-brand-200/50 dark:border-brand-700/30 mb-6">
              <ShieldCheck className="w-4 h-4 text-brand-600 dark:text-brand-400" />
              <span className="text-xs font-medium text-brand-700 dark:text-brand-300">
                Trusted by 5M+ users worldwide
              </span>
            </div>

            {/* Headline */}
            <h1 className="text-4xl sm:text-5xl lg:text-6xl font-bold tracking-tight text-gray-900 dark:text-white leading-[1.1] mb-6">
              Trade Crypto with{' '}
              <span className="text-gradient">Confidence</span>{' '}
              and Security
            </h1>

            {/* Subheadline */}
            <p className="text-base sm:text-lg text-gray-600 dark:text-gray-400 mb-8 max-w-xl mx-auto lg:mx-0 leading-relaxed">
              Access 200+ digital assets with industry-leading low fees and deep
              liquidity. Experience a professional-grade trading platform built for
              traders of every level.
            </p>

            {/* CTAs */}
            <div className="flex flex-col sm:flex-row gap-4 justify-center lg:justify-start mb-10">
              <Link
                to="/sign-up"
                className="inline-flex items-center justify-center gap-2 px-7 py-3.5 text-base font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple-strong hover:scale-[1.02]"
              >
                Get Started
                <ArrowRight className="w-5 h-5" />
              </Link>
              <a
                href="#markets"
                className="inline-flex items-center justify-center gap-2 px-7 py-3.5 text-base font-semibold text-gray-700 dark:text-gray-200 bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-xl hover:border-brand-300 dark:hover:border-brand-600/50 transition-all"
              >
                <Activity className="w-5 h-5" />
                Explore Markets
              </a>
            </div>

            {/* Mini stats row */}
            <div className="flex flex-wrap gap-6 justify-center lg:justify-start">
              {[
                { label: 'Assets', value: '200+' },
                { label: 'Low Fees', value: '0.05%' },
                { label: 'Daily Volume', value: '$8.4B' },
              ].map((s) => (
                <div key={s.label} className="text-center lg:text-left">
                  <div className="text-2xl font-bold text-gray-900 dark:text-white">{s.value}</div>
                  <div className="text-xs text-gray-500 dark:text-gray-500">{s.label}</div>
                </div>
              ))}
            </div>
          </div>

          {/* Right: Animated chart */}
          <div className="relative">
            <HeroChart />
          </div>
        </div>
      </div>
    </section>
  );
}

function HeroChart() {
  // Chart path data - a rising trend line
  const chartPoints = [
    { x: 20, y: 180 },
    { x: 60, y: 160 },
    { x: 100, y: 140 },
    { x: 140, y: 155 },
    { x: 180, y: 110 },
    { x: 220, y: 90 },
    { x: 260, y: 100 },
    { x: 300, y: 65 },
    { x: 340, y: 45 },
    { x: 380, y: 55 },
    { x: 420, y: 30 },
  ];

  const linePath = chartPoints
    .map((p, i) => (i === 0 ? `M ${p.x} ${p.y}` : `L ${p.x} ${p.y}`))
    .join(' ');

  const areaPath = `${linePath} L 420 220 L 20 220 Z`;

  return (
    <div className="relative w-full max-w-lg mx-auto">
      {/* Floating price chips */}
      <div className="absolute -top-4 -left-2 z-20 animate-float" style={{ animationDelay: '0s' }}>
        <div className="px-3 py-2 rounded-xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-lg flex items-center gap-2">
          <div className="w-6 h-6 rounded-full bg-[#f7931a] flex items-center justify-center text-[10px] font-bold text-white">B</div>
          <div>
            <div className="text-xs font-semibold text-gray-900 dark:text-white">BTC</div>
            <div className="text-xs text-green-500">+2.34%</div>
          </div>
        </div>
      </div>

      <div className="absolute top-1/2 -right-2 z-20 animate-float" style={{ animationDelay: '2s' }}>
        <div className="px-3 py-2 rounded-xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-lg flex items-center gap-2">
          <div className="w-6 h-6 rounded-full bg-[#627eea] flex items-center justify-center text-[10px] font-bold text-white">E</div>
          <div>
            <div className="text-xs font-semibold text-gray-900 dark:text-white">ETH</div>
            <div className="text-xs text-green-500">+3.12%</div>
          </div>
        </div>
      </div>

      <div className="absolute -bottom-2 left-8 z-20 animate-float" style={{ animationDelay: '4s' }}>
        <div className="px-3 py-2 rounded-xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-lg flex items-center gap-2">
          <div className="w-6 h-6 rounded-full bg-[#9945ff] flex items-center justify-center text-[10px] font-bold text-white">S</div>
          <div>
            <div className="text-xs font-semibold text-gray-900 dark:text-white">SOL</div>
            <div className="text-xs text-green-500">+5.67%</div>
          </div>
        </div>
      </div>

      {/* Chart card */}
      <div className="relative rounded-3xl bg-white dark:bg-surface-dark-2 border border-gray-200/50 dark:border-white/5 shadow-2xl card-glow p-6 overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between mb-6">
          <div className="flex items-center gap-2">
            <TrendingUp className="w-5 h-5 text-brand-500" />
            <span className="text-sm font-semibold text-gray-900 dark:text-white">BTC/USDT</span>
          </div>
          <div className="flex items-center gap-2">
            <div className="w-2 h-2 rounded-full bg-green-500 animate-pulse" />
            <span className="text-xs text-gray-500 dark:text-gray-400">Live</span>
          </div>
        </div>

        {/* Price */}
        <div className="mb-4">
          <div className="text-3xl font-bold text-gray-900 dark:text-white">$67,234.50</div>
          <div className="text-sm text-green-500 font-medium">+$1,542.20 (+2.34%)</div>
        </div>

        {/* SVG Chart */}
        <div className="relative h-56">
          <svg viewBox="0 0 440 220" className="w-full h-full" preserveAspectRatio="none">
            <defs>
              <linearGradient id="areaGrad" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="#7c3aed" stopOpacity="0.3" />
                <stop offset="100%" stopColor="#7c3aed" stopOpacity="0" />
              </linearGradient>
              <linearGradient id="lineGrad" x1="0" y1="0" x2="1" y2="0">
                <stop offset="0%" stopColor="#7c3aed" />
                <stop offset="100%" stopColor="#a78bfa" />
              </linearGradient>
              <filter id="glow">
                <feGaussianBlur stdDeviation="3" result="coloredBlur" />
                <feMerge>
                  <feMergeNode in="coloredBlur" />
                  <feMergeNode in="SourceGraphic" />
                </feMerge>
              </filter>
            </defs>

            {/* Grid lines */}
            {[40, 80, 120, 160, 200].map((y) => (
              <line key={y} x1="0" y1={y} x2="440" y2={y} stroke="currentColor" className="text-gray-100 dark:text-white/5" strokeWidth="1" />
            ))}

            {/* Area fill */}
            <path d={areaPath} fill="url(#areaGrad)" />

            {/* Line */}
            <path
              d={linePath}
              fill="none"
              stroke="url(#lineGrad)"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              filter="url(#glow)"
            />

            {/* Data points */}
            {chartPoints.map((p, i) => (
              <circle
                key={i}
                cx={p.x}
                cy={p.y}
                r="3"
                fill="#7c3aed"
                className="animate-spark"
                style={{ animationDelay: `${i * 0.2}s` }}
              />
            ))}

            {/* Last point highlight */}
            <circle cx={420} cy={30} r="6" fill="#7c3aed" opacity="0.3" className="animate-pulse" />
            <circle cx={420} cy={30} r="4" fill="#fff" stroke="#7c3aed" strokeWidth="2" />
          </svg>
        </div>

        {/* Time labels */}
        <div className="flex justify-between mt-2 text-xs text-gray-400 dark:text-gray-500">
          <span>00:00</span>
          <span>06:00</span>
          <span>12:00</span>
          <span>18:00</span>
          <span>24h</span>
        </div>
      </div>
    </div>
  );
}
