import { useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Building2, Bitcoin, ArrowRight, Wallet, ChevronDown,
  Info, ArrowDownToLine,
} from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';

type Method = 'bank' | 'crypto';

const cryptoCoins = [
  { symbol: 'BTC', name: 'Bitcoin' },
  { symbol: 'ETH', name: 'Ethereum' },
  { symbol: 'USDT', name: 'Tether' },
  { symbol: 'SOL', name: 'Solana' },
];

const MOCK_BALANCE = 0;

export default function Withdraw() {
  const [method, setMethod] = useState<Method>('bank');
  const [amount, setAmount] = useState('');
  const [selectedCoin, setSelectedCoin] = useState(cryptoCoins[0]);
  const [coinDropdown, setCoinDropdown] = useState(false);
  const [walletAddress, setWalletAddress] = useState('');

  const hasFunds = MOCK_BALANCE > 0;

  return (
    <DashboardLayout title="Withdraw">
      <PageHeader title="Withdraw" subtitle="Withdraw funds from your account" />

      <div className="max-w-2xl space-y-6">
        {/* Balance display */}
        <div className="rounded-2xl bg-gradient-to-br from-surface-light dark:from-surface-dark-2 to-surface-light-2 dark:to-surface-dark-3 border border-gray-200 dark:border-white/5 p-6 card-glow">
          <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">Available Balance</p>
          <div className="flex items-center gap-3">
            <h3 className="text-3xl font-bold text-gray-900 dark:text-white">
              ${MOCK_BALANCE.toFixed(2)}
            </h3>
            <span className="px-2.5 py-1 rounded-md text-xs font-medium bg-gray-100 dark:bg-white/5 text-gray-500 dark:text-gray-400">
              USD
            </span>
          </div>
        </div>

        {!hasFunds ? (
          /* Empty state */
          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-10 text-center">
            <div className="w-16 h-16 rounded-full bg-gray-100 dark:bg-white/5 flex items-center justify-center mx-auto mb-5">
              <Wallet className="w-8 h-8 text-gray-300 dark:text-gray-600" />
            </div>
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
              No funds available to withdraw yet
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400 mb-6">
              Make a deposit first to start trading and withdraw your earnings.
            </p>
            <Link
              to="/deposit"
              className="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
            >
              <ArrowDownToLine className="w-4 h-4" />
              Go to Deposit
            </Link>
          </div>
        ) : (
          /* Withdrawal form */
          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
            {/* Method tabs */}
            <div className="flex gap-1 p-1 rounded-xl bg-gray-100 dark:bg-white/5 mb-6">
              <button
                onClick={() => setMethod('bank')}
                className={`flex-1 flex items-center justify-center gap-2 px-4 py-2.5 text-sm font-medium rounded-lg transition-all ${
                  method === 'bank'
                    ? 'bg-white dark:bg-surface-dark-3 text-brand-700 dark:text-brand-300 shadow-sm'
                    : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200'
                }`}
              >
                <Building2 className="w-4 h-4" />
                Bank Transfer
              </button>
              <button
                onClick={() => setMethod('crypto')}
                className={`flex-1 flex items-center justify-center gap-2 px-4 py-2.5 text-sm font-medium rounded-lg transition-all ${
                  method === 'crypto'
                    ? 'bg-white dark:bg-surface-dark-3 text-brand-700 dark:text-brand-300 shadow-sm'
                    : 'text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200'
                }`}
              >
                <Bitcoin className="w-4 h-4" />
                Crypto
              </button>
            </div>

            <form onSubmit={(e) => e.preventDefault()} className="space-y-5">
              {/* Amount */}
              <div>
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                  Amount
                </label>
                <div className="relative">
                  <span className="absolute left-3.5 top-1/2 -translate-y-1/2 text-gray-400 text-sm">$</span>
                  <input
                    type="number"
                    required
                    value={amount}
                    onChange={(e) => setAmount(e.target.value)}
                    placeholder="0.00"
                    className="w-full pl-8 pr-20 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                  />
                  <button
                    type="button"
                    onClick={() => setAmount(MOCK_BALANCE.toFixed(2))}
                    className="absolute right-3 top-1/2 -translate-y-1/2 px-2.5 py-1 text-xs font-semibold text-brand-600 dark:text-brand-400 bg-brand-50 dark:bg-brand-950/40 rounded-md hover:bg-brand-100 dark:hover:bg-brand-950/60 transition-colors"
                  >
                    Max
                  </button>
                </div>
              </div>

              {/* Crypto: coin selector + wallet address */}
              {method === 'crypto' && (
                <>
                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                      Coin
                    </label>
                    <div className="relative">
                      <button
                        type="button"
                        onClick={() => setCoinDropdown(!coinDropdown)}
                        className="w-full flex items-center justify-between px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white hover:border-brand-500 dark:hover:border-brand-600 transition-all"
                      >
                        <span className="flex items-center gap-2">
                          <span className="font-semibold">{selectedCoin.symbol}</span>
                          <span className="text-gray-500 dark:text-gray-400">{selectedCoin.name}</span>
                        </span>
                        <ChevronDown className="w-4 h-4 text-gray-400" />
                      </button>
                      {coinDropdown && (
                        <div className="absolute top-full left-0 right-0 mt-1 rounded-xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-xl overflow-hidden z-10">
                          {cryptoCoins.map((coin) => (
                            <button
                              key={coin.symbol}
                              type="button"
                              onClick={() => {
                                setSelectedCoin(coin);
                                setCoinDropdown(false);
                              }}
                              className="w-full flex items-center gap-3 px-4 py-2.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-white/5 transition-colors text-left"
                            >
                              <span className="font-semibold w-12">{coin.symbol}</span>
                              <span className="text-gray-500 dark:text-gray-400">{coin.name}</span>
                            </button>
                          ))}
                        </div>
                      )}
                    </div>
                  </div>

                  <div>
                    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                      Destination Wallet Address
                    </label>
                    <input
                      type="text"
                      required
                      value={walletAddress}
                      onChange={(e) => setWalletAddress(e.target.value)}
                      placeholder="Enter wallet address"
                      className="w-full px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all font-mono"
                    />
                  </div>
                </>
              )}

              <button
                type="submit"
                className="w-full inline-flex items-center justify-center gap-2 px-6 py-3.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
              >
                Withdraw Funds
                <ArrowRight className="w-4 h-4" />
              </button>
            </form>
          </div>
        )}

        {/* Info note */}
        <div className="flex items-start gap-2 rounded-xl bg-brand-50 dark:bg-brand-950/30 border border-brand-200/30 dark:border-brand-800/20 px-4 py-3">
          <Info className="w-4 h-4 text-brand-600 dark:text-brand-400 shrink-0 mt-0.5" />
          <p className="text-xs text-brand-700 dark:text-brand-300 leading-relaxed">
            Withdrawals are processed within 1-3 business days. This is a demo — no real funds are involved.
          </p>
        </div>
      </div>
    </DashboardLayout>
  );
}
