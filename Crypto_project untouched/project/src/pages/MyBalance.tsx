import { Link } from 'react-router-dom';
import { Wallet, ArrowDownToLine, ArrowUpFromLine, PieChart } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';

export default function MyBalance() {
  return (
    <DashboardLayout title="My Balance">
      <PageHeader title="My Balance" subtitle="Your portfolio overview" />

      <div className="max-w-3xl space-y-6">
        {/* Total balance */}
        <div className="rounded-2xl bg-gradient-to-br from-surface-light dark:from-surface-dark-2 to-surface-light-2 dark:to-surface-dark-3 border border-gray-200 dark:border-white/5 p-6 card-glow">
          <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">Total Balance</p>
          <div className="flex items-center gap-3 mb-4">
            <h3 className="text-4xl font-bold text-gray-900 dark:text-white">$0.00</h3>
            <span className="px-2.5 py-1 rounded-md text-xs font-medium bg-brand-50 dark:bg-brand-950/40 text-brand-700 dark:text-brand-300 border border-brand-200/40 dark:border-brand-800/30">
              USD
            </span>
          </div>
          <div className="flex gap-3">
            <Link
              to="/deposit"
              className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
            >
              <ArrowDownToLine className="w-4 h-4" />
              Deposit
            </Link>
            <Link
              to="/withdraw"
              className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-gray-700 dark:text-gray-200 bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-xl hover:border-brand-300 dark:hover:border-brand-600/50 transition-all"
            >
              <ArrowUpFromLine className="w-4 h-4" />
              Withdraw
            </Link>
          </div>
        </div>

        {/* Asset breakdown */}
        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white">Asset Breakdown</h3>
            <PieChart className="w-5 h-5 text-gray-400 dark:text-gray-500" />
          </div>

          {/* Empty state */}
          <div className="flex flex-col items-center justify-center py-12">
            <div className="w-16 h-16 rounded-full bg-gray-100 dark:bg-white/5 flex items-center justify-center mb-4">
              <Wallet className="w-8 h-8 text-gray-300 dark:text-gray-600" />
            </div>
            <p className="text-sm font-medium text-gray-900 dark:text-white mb-1">No assets yet</p>
            <p className="text-xs text-gray-500 dark:text-gray-400 mb-5">
              Your holdings will appear here once you make a deposit.
            </p>
            <Link
              to="/deposit"
              className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
            >
              <ArrowDownToLine className="w-4 h-4" />
              Make a Deposit
            </Link>
          </div>
        </div>
      </div>
    </DashboardLayout>
  );
}
