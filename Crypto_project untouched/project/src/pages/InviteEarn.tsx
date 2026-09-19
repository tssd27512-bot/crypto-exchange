import { useState } from 'react';
import { Copy, Check, Gift, Users, DollarSign, Share2 } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';

const REFERRAL_CODE = 'GTVX-JOHN-2024';
const REFERRAL_LINK = `https://globaltradevx.com/r/${REFERRAL_CODE}`;

const stats = [
  { label: 'Total Referrals', value: '0', icon: Users },
  { label: 'Total Earned', value: '$0.00', icon: DollarSign },
  { label: 'Pending Rewards', value: '$0.00', icon: Gift },
];

export default function InviteEarn() {
  const [copied, setCopied] = useState<'code' | 'link' | null>(null);

  const copy = (text: string, type: 'code' | 'link') => {
    navigator.clipboard?.writeText(text);
    setCopied(type);
    setTimeout(() => setCopied(null), 2000);
  };

  return (
    <DashboardLayout title="Invite & Earn">
      <PageHeader title="Invite & Earn" subtitle="Invite friends and earn rewards" />

      <div className="max-w-3xl space-y-6">
        {/* Hero card */}
        <div className="relative rounded-2xl bg-gradient-to-br from-brand-700 via-brand-600 to-brand-800 p-8 overflow-hidden">
          <div className="absolute inset-0 grid-bg opacity-20" />
          <div className="absolute top-0 right-0 w-64 h-64 bg-white/10 rounded-full blur-[80px]" />
          <div className="relative">
            <div className="inline-flex items-center gap-2 px-3 py-1.5 rounded-full bg-white/10 mb-4">
              <Gift className="w-4 h-4 text-white" />
              <span className="text-xs font-medium text-white">Earn $10 per referral</span>
            </div>
            <h3 className="text-2xl font-bold text-white mb-2">Invite Friends, Earn Together</h3>
            <p className="text-sm text-brand-100 max-w-md">
              Share your referral link with friends. When they sign up and make their first deposit, you both earn rewards.
            </p>
          </div>
        </div>

        {/* Stats */}
        <div className="grid sm:grid-cols-3 gap-4">
          {stats.map((s) => (
            <div key={s.label} className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-5 card-glow">
              <div className="flex items-center justify-between mb-3">
                <p className="text-xs text-gray-500 dark:text-gray-400">{s.label}</p>
                <div className="w-8 h-8 rounded-lg bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center">
                  <s.icon className="w-4 h-4 text-brand-600 dark:text-brand-400" />
                </div>
              </div>
              <p className="text-2xl font-bold text-gray-900 dark:text-white">{s.value}</p>
            </div>
          ))}
        </div>

        {/* Referral code + link */}
        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6 space-y-4">
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Your Referral Code</label>
            <div className="flex gap-2">
              <input
                type="text"
                readOnly
                value={REFERRAL_CODE}
                className="flex-1 px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white font-mono"
              />
              <button
                onClick={() => copy(REFERRAL_CODE, 'code')}
                className="px-4 py-3 text-sm font-medium rounded-xl bg-brand-50 dark:bg-brand-950/40 text-brand-600 dark:text-brand-400 border border-brand-200/40 dark:border-brand-800/30 hover:bg-brand-100 dark:hover:bg-brand-950/60 transition-all flex items-center gap-2"
              >
                {copied === 'code' ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
                {copied === 'code' ? 'Copied' : 'Copy'}
              </button>
            </div>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Your Referral Link</label>
            <div className="flex gap-2">
              <input
                type="text"
                readOnly
                value={REFERRAL_LINK}
                className="flex-1 px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-600 dark:text-gray-400 font-mono truncate"
              />
              <button
                onClick={() => copy(REFERRAL_LINK, 'link')}
                className="px-4 py-3 text-sm font-medium rounded-xl bg-brand-50 dark:bg-brand-950/40 text-brand-600 dark:text-brand-400 border border-brand-200/40 dark:border-brand-800/30 hover:bg-brand-100 dark:hover:bg-brand-950/60 transition-all flex items-center gap-2"
              >
                {copied === 'link' ? <Check className="w-4 h-4" /> : <Share2 className="w-4 h-4" />}
                {copied === 'link' ? 'Copied' : 'Copy'}
              </button>
            </div>
          </div>
        </div>

        {/* How it works */}
        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
          <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-4">How It Works</h3>
          <div className="grid sm:grid-cols-3 gap-4">
            {[
              { step: '1', title: 'Share your link', desc: 'Send your referral link to friends.' },
              { step: '2', title: 'They sign up', desc: 'Your friend creates an account using your link.' },
              { step: '3', title: 'You both earn', desc: 'Get $10 when they make their first deposit.' },
            ].map((s) => (
              <div key={s.step} className="text-center">
                <div className="w-10 h-10 rounded-full bg-brand-50 dark:bg-brand-950/40 border-2 border-brand-200/40 dark:border-brand-800/30 flex items-center justify-center font-bold text-brand-600 dark:text-brand-400 text-sm mx-auto mb-3">
                  {s.step}
                </div>
                <h4 className="text-sm font-semibold text-gray-900 dark:text-white mb-1">{s.title}</h4>
                <p className="text-xs text-gray-500 dark:text-gray-400">{s.desc}</p>
              </div>
            ))}
          </div>
        </div>
      </div>
    </DashboardLayout>
  );
}
