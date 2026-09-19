import { useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Building2, CreditCard, Bitcoin, Copy, Check,
  ChevronDown, ArrowRight, Info, Clock, DollarSign, ShieldCheck,
} from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';

type Method = 'bank' | 'card' | 'crypto';

const cryptoCoins = [
  { symbol: 'BTC', name: 'Bitcoin', address: '12Nj9GfZN3M1yYESp3K8VWK5jAnddzaQdV' },
  { symbol: 'ETH', name: 'Ethereum', address: '0xe7d6a948a315d8d024cbf157922af4e96f47ac64' },
  { symbol: 'USDT', name: 'Tether', address: 'TXxosbC61aZADU1FmMmRBn3xMKN6kSnY3D' },
  { symbol: 'SOL', name: 'Solana', address: 'Hgws8kFaV2NJZNtsHrMhPQEsb57gbvfAZXGQW2dAebhu' },
];

const infoCards = [
  { icon: DollarSign, label: 'Minimum Deposit', value: '$10' },
  { icon: Clock, label: 'Processing Time', value: 'Instant - 30 min' },
  { icon: ShieldCheck, label: 'Fees', value: '0% for deposits' },
];

export default function Deposit() {
  const [method, setMethod] = useState<Method>('bank');
  const [amount, setAmount] = useState('');
  const [currency, setCurrency] = useState('USD');
  const [selectedCoin, setSelectedCoin] = useState(cryptoCoins[0]);
  const [coinDropdown, setCoinDropdown] = useState(false);
  const [copied, setCopied] = useState(false);
  const [success, setSuccess] = useState(false);

  const handleCopy = () => {
    navigator.clipboard?.writeText(selectedCoin.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    setSuccess(true);
  };

  if (success) {
    return (
      <DashboardLayout title="Deposit">
        <PageHeader title="Deposit" subtitle="Add funds to your account" />
        <div className="max-w-lg mx-auto rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-8 text-center">
          <div className="w-16 h-16 rounded-full bg-green-50 dark:bg-green-500/10 flex items-center justify-center mx-auto mb-5">
            <div className="w-12 h-12 rounded-full bg-green-500 flex items-center justify-center animate-pulse">
              <Check className="w-7 h-7 text-white" />
            </div>
          </div>
          <h3 className="text-xl font-bold text-gray-900 dark:text-white mb-2">Deposit Simulated</h3>
          <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">
            Your deposit request has been processed in demo mode.
          </p>
          <div className="flex items-center justify-center gap-2 mt-4 mb-6 rounded-xl bg-brand-50 dark:bg-brand-950/40 border border-brand-200/30 dark:border-brand-800/20 px-4 py-3">
            <Info className="w-4 h-4 text-brand-600 dark:text-brand-400 shrink-0" />
            <span className="text-xs text-brand-700 dark:text-brand-300">This is a demo — no real funds were moved.</span>
          </div>
          <Link
            to="/dashboard"
            className="inline-flex items-center gap-2 px-6 py-3 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
          >
            Back to Dashboard
            <ArrowRight className="w-4 h-4" />
          </Link>
        </div>
      </DashboardLayout>
    );
  }

  return (
    <DashboardLayout title="Deposit">
      <PageHeader title="Deposit" subtitle="Add funds to your account" />

      <div className="grid lg:grid-cols-3 gap-6">
        {/* Left: method + form */}
        <div className="lg:col-span-2 space-y-6">
          {/* Method selection */}
          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
            <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-4">Select a deposit method</h3>
            <div className="grid sm:grid-cols-3 gap-3">
              <MethodCard
                icon={Building2}
                label="Bank Transfer"
                active={method === 'bank'}
                onClick={() => setMethod('bank')}
              />
              <MethodCard
                icon={CreditCard}
                label="Debit/Credit Card"
                active={method === 'card'}
                onClick={() => setMethod('card')}
              />
              <MethodCard
                icon={Bitcoin}
                label="Crypto Deposit"
                active={method === 'crypto'}
                onClick={() => setMethod('crypto')}
              />
            </div>
          </div>

          {/* Form area */}
          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
            {(method === 'bank' || method === 'card') && (
              <form onSubmit={handleSubmit} className="space-y-5">
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                    Amount
                  </label>
                  <div className="flex gap-2">
                    <div className="relative flex-1">
                      <DollarSign className="absolute left-3.5 top-1/2 -translate-y-1/2 w-5 h-5 text-gray-400" />
                      <input
                        type="number"
                        required
                        min="10"
                        value={amount}
                        onChange={(e) => setAmount(e.target.value)}
                        placeholder="0.00"
                        className="w-full pl-11 pr-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                      />
                    </div>
                    <select
                      value={currency}
                      onChange={(e) => setCurrency(e.target.value)}
                      className="px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 transition-all"
                    >
                      <option value="USD">USD</option>
                      <option value="EUR">EUR</option>
                      <option value="GBP">GBP</option>
                    </select>
                  </div>
                </div>
                <button
                  type="submit"
                  className="w-full inline-flex items-center justify-center gap-2 px-6 py-3.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
                >
                  Continue
                  <ArrowRight className="w-4 h-4" />
                </button>
              </form>
            )}

            {method === 'crypto' && (
              <div className="space-y-5">
                {/* Coin selector */}
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                    Select Coin
                  </label>
                  <div className="relative">
                    <button
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

                {/* Wallet address */}
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                    Deposit Address
                  </label>
                  <div className="flex gap-2">
                    <input
                      type="text"
                      readOnly
                      value={selectedCoin.address}
                      className="flex-1 px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-600 dark:text-gray-400 font-mono"
                    />
                    <button
                      onClick={handleCopy}
                      className="px-4 py-3 text-sm font-medium rounded-xl bg-brand-50 dark:bg-brand-950/40 text-brand-600 dark:text-brand-400 border border-brand-200/40 dark:border-brand-800/30 hover:bg-brand-100 dark:hover:bg-brand-950/60 transition-all flex items-center gap-2"
                    >
                      {copied ? <Check className="w-4 h-4" /> : <Copy className="w-4 h-4" />}
                      {copied ? 'Copied' : 'Copy'}
                    </button>
                  </div>
                </div>

                {/* QR placeholder */}
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                    Scan to Deposit
                  </label>
                  <div className="flex flex-col items-center justify-center w-40 h-40 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border-2 border-dashed border-gray-200 dark:border-white/10 mx-auto">
                    <Bitcoin className="w-10 h-10 text-gray-300 dark:text-gray-600 mb-2" />
                    <span className="text-xs text-gray-400 dark:text-gray-600">QR Code</span>
                  </div>
                </div>

                <button
                  onClick={handleSubmit}
                  className="w-full inline-flex items-center justify-center gap-2 px-6 py-3.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl hover:from-brand-500 hover:to-brand-600 transition-all glow-purple"
                >
                  I've Made the Deposit
                  <ArrowRight className="w-4 h-4" />
                </button>
              </div>
            )}
          </div>
        </div>

        {/* Right: info panel */}
        <div className="space-y-4">
          {infoCards.map((card) => (
            <div key={card.label} className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-5">
              <div className="flex items-center gap-3 mb-2">
                <div className="w-10 h-10 rounded-xl bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center">
                  <card.icon className="w-5 h-5 text-brand-600 dark:text-brand-400" />
                </div>
                <div>
                  <p className="text-xs text-gray-500 dark:text-gray-400">{card.label}</p>
                  <p className="text-sm font-semibold text-gray-900 dark:text-white">{card.value}</p>
                </div>
              </div>
            </div>
          ))}

          <div className="rounded-2xl bg-brand-50 dark:bg-brand-950/30 border border-brand-200/30 dark:border-brand-800/20 p-5">
            <div className="flex items-start gap-2">
              <Info className="w-4 h-4 text-brand-600 dark:text-brand-400 shrink-0 mt-0.5" />
              <p className="text-xs text-brand-700 dark:text-brand-300 leading-relaxed">
                All deposits are processed securely. This is a demo environment — no real funds are involved.
              </p>
            </div>
          </div>
        </div>
      </div>
    </DashboardLayout>
  );
}

function MethodCard({
  icon: Icon,
  label,
  active,
  onClick,
}: {
  icon: typeof Building2;
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className={`flex flex-col items-center gap-2 p-4 rounded-xl border transition-all ${
        active
          ? 'border-brand-500 dark:border-brand-600 bg-brand-50 dark:bg-brand-950/40 glow-purple'
          : 'border-gray-200 dark:border-white/10 bg-gray-50 dark:bg-surface-dark-3 hover:border-brand-300 dark:hover:border-brand-700/40'
      }`}
    >
      <Icon className={`w-7 h-7 ${active ? 'text-brand-600 dark:text-brand-400' : 'text-gray-400 dark:text-gray-500'}`} />
      <span className={`text-xs font-medium text-center ${active ? 'text-brand-700 dark:text-brand-300' : 'text-gray-600 dark:text-gray-400'}`}>
        {label}
      </span>
    </button>
  );
}
