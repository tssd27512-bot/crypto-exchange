import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Building2, CreditCard, Bitcoin, Copy, Check,
  ChevronDown, ArrowRight, Info, Clock, DollarSign, ShieldCheck,
} from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import {
  fetchAssets,
  fetchDepositNetworks,
  fetchMyDepositAddresses,
  fetchMyDeposits,
  formatUnits,
  useQuery,
  useRealtimeTable,
  type AssetRow,
  type DepositAddressRow,
  type DepositNetworkRow,
  type DepositRow,
  type QueryResult,
} from '@/lib/api';
import { EmptyState, ErrorBlock, InfoNote, LoadingBlock, UnavailableBlock } from '@/components/DataState';

type Method = 'bank' | 'card' | 'crypto';

export default function Deposit() {
  const assets = useQuery<AssetRow[]>('dep-assets', fetchAssets);
  const networks = useQuery<DepositNetworkRow[]>('dep-networks', fetchDepositNetworks);
  const addresses = useQuery<DepositAddressRow[]>('dep-addresses', fetchMyDepositAddresses);
  const deposits = useQuery<DepositRow[]>('dep-history', fetchMyDeposits);

  useRealtimeTable('deposits', { onChange: deposits.reload });

  const [method, setMethod] = useState<Method>('crypto');
  const [assetSymbol, setAssetSymbol] = useState<string | null>(null);
  const [coinDropdown, setCoinDropdown] = useState(false);
  const [copied, setCopied] = useState(false);

  const assetRows = assets.state.status === 'ready' ? assets.state.data : [];
  const networkRows = networks.state.status === 'ready' ? networks.state.data : [];
  const addressRows = addresses.state.status === 'ready' ? addresses.state.data : [];

  const selectedAsset = useMemo(
    () => assetRows.find((a) => a.symbol === assetSymbol) ?? assetRows[0] ?? null,
    [assetRows, assetSymbol],
  );

  const selectedAddress = selectedAsset
    ? addressRows.find((a) => a.asset_id === selectedAsset.id) ?? null
    : null;

  const assetNetworks = selectedAsset
    ? networkRows.filter((n) => n.asset_id === selectedAsset.id)
    : [];

  const handleCopy = () => {
    if (!selectedAddress) return;
    navigator.clipboard?.writeText(selectedAddress.address);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <DashboardLayout title="Deposit">
      <PageHeader title="Deposit" subtitle="Deposits are credited from the exchange's own deposit ledger" />

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
              <div className="space-y-4">
                <EmptyState
                  icon={<Building2 className="w-6 h-6 text-gray-300 dark:text-gray-600" />}
                  title={`${method === 'bank' ? 'Bank transfer' : 'Card'} deposits are not open yet`}
                  description="No fiat payment provider is configured for this exchange, so no card or bank deposit can be started. This page will show the provider's flow once one is connected."
                />
                <InfoNote>
                  Nothing is charged and no payment details are collected while the provider is not
                  configured.
                </InfoNote>
              </div>
            )}

            {method === 'crypto' && (
              <div className="space-y-5">
                {assets.state.status === 'unavailable' ? (
                  <UnavailableBlock failure={assets.state.failure} onRetry={assets.reload} compact />
                ) : assets.state.status === 'loading' ? (
                  <LoadingBlock label="Loading assets…" compact />
                ) : assetRows.length === 0 ? (
                  <EmptyState title="No assets configured" description="The backend has no deposit assets yet." compact />
                ) : (
                  <>
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
                            <span className="font-semibold">{selectedAsset?.symbol}</span>
                            <span className="text-gray-500 dark:text-gray-400">{selectedAsset?.name}</span>
                          </span>
                          <ChevronDown className="w-4 h-4 text-gray-400" />
                        </button>
                        {coinDropdown && (
                          <div className="absolute top-full left-0 right-0 mt-1 rounded-xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-xl overflow-hidden z-10">
                            {assetRows.map((coin) => (
                              <button
                                key={coin.id}
                                onClick={() => {
                                  setAssetSymbol(coin.symbol);
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

                    {/* Network + address */}
                    {selectedAddress ? (
                      <div>
                        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                          Deposit Address ({selectedAddress.network})
                        </label>
                        <div className="flex gap-2">
                          <input
                            type="text"
                            readOnly
                            value={selectedAddress.address}
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
                        <p className="text-[11px] text-gray-400 dark:text-gray-500 mt-1">
                          Only send {selectedAsset?.symbol} on {selectedAddress.network} to this address.
                        </p>
                      </div>
                    ) : (
                      <div className="rounded-xl border border-dashed border-gray-200 dark:border-white/10 bg-gray-50 dark:bg-surface-dark-3 p-5">
                        <p className="text-sm font-medium text-gray-900 dark:text-white mb-1">
                          No deposit address assigned yet
                        </p>
                        <p className="text-xs text-gray-500 dark:text-gray-400">
                          {addresses.state.status === 'unavailable'
                            ? 'Deposit addresses are issued by the custody provider, and the deposit backend has not been deployed to this project yet.'
                            : addresses.state.status === 'error'
                            ? 'Your deposit addresses could not be loaded.'
                            : 'Addresses are issued per user by the custody provider. None has been issued for your account yet — deposits cannot be sent until one is.'}
                        </p>
                      </div>
                    )}

                    {assetNetworks.length > 0 && (
                      <div className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 p-4">
                        <p className="text-xs font-medium text-gray-600 dark:text-gray-300 mb-2">
                          Networks configured for {selectedAsset?.symbol}
                        </p>
                        <div className="space-y-1.5">
                          {assetNetworks.map((n) => (
                            <div key={`${n.asset_id}-${n.network}`} className="flex items-center justify-between text-xs">
                              <span className="text-gray-600 dark:text-gray-300">
                                {n.network} {n.enabled ? '' : '(disabled)'}
                              </span>
                              <span className="text-gray-500 dark:text-gray-400">
                                min {formatUnits(n.min_amount_units, selectedAsset?.base_decimals ?? 8)} ·{' '}
                                {n.required_confirmations} confirmations
                              </span>
                            </div>
                          ))}
                        </div>
                      </div>
                    )}

                    {/* QR placeholder */}
                    <div>
                      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                        Scan to Deposit
                      </label>
                      <div className="flex flex-col items-center justify-center w-40 h-40 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border-2 border-dashed border-gray-200 dark:border-white/10 mx-auto">
                        <Bitcoin className="w-10 h-10 text-gray-300 dark:text-gray-600 mb-2" />
                        <span className="text-xs text-gray-400 dark:text-gray-600">
                          {selectedAddress ? 'QR generation not configured' : 'No address'}
                        </span>
                      </div>
                    </div>

                    <InfoNote>
                      A deposit is credited only when the exchange's own deposit ledger records it, at the
                      network's required confirmations. Nothing on this page creates or credits a deposit
                      by itself.
                    </InfoNote>
                  </>
                )}
              </div>
            )}
          </div>

          {/* Deposit history */}
          <DepositHistory deposits={deposits} assets={assetRows} />
        </div>

        {/* Right: info panel */}
        <div className="space-y-4">
          {[
            { icon: DollarSign, label: 'Minimum Deposit', value: 'Per network (see above)' },
            { icon: Clock, label: 'Processing Time', value: 'Credited after confirmations' },
            { icon: ShieldCheck, label: 'Deposit Fee', value: 'No exchange fee recorded' },
          ].map((card) => (
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

          <InfoNote>
            Deposits are credited by the exchange's own ledger from a deposit the backend has verified. No
            provider adapter (chain watcher, fiat processor) is connected yet.
          </InfoNote>
          <Link
            to="/history"
            className="inline-flex items-center gap-2 px-5 py-2.5 text-sm font-semibold text-gray-700 dark:text-gray-200 bg-white dark:bg-white/5 border border-gray-200 dark:border-white/10 rounded-xl hover:border-brand-300 dark:hover:border-brand-600/50 transition-all"
          >
            View full history
            <ArrowRight className="w-4 h-4" />
          </Link>
        </div>
      </div>
    </DashboardLayout>
  );
}

function DepositHistory({
  deposits,
  assets,
}: {
  deposits: QueryResult<DepositRow[]>;
  assets: AssetRow[];
}) {
  const rows = deposits.state.status === 'ready' ? deposits.state.data : [];
  const symbolFor = (assetId: string) => assets.find((a) => a.id === assetId);

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
      <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-4">Your Deposits</h3>
      {deposits.state.status === 'loading' ? (
        <LoadingBlock label="Loading deposits…" compact />
      ) : deposits.state.status === 'unavailable' ? (
        <UnavailableBlock failure={deposits.state.failure} onRetry={deposits.reload} compact />
      ) : deposits.state.status === 'error' ? (
        <ErrorBlock failure={deposits.state.failure} onRetry={deposits.reload} compact />
      ) : rows.length === 0 ? (
        <EmptyState
          title="No deposits yet"
          description="Deposits recorded against your account will be listed here with their confirmation status."
          compact
        />
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="border-b border-gray-200 dark:border-white/5">
                {['Asset', 'Network', 'Amount', 'Confirmations', 'Status', 'Detected'].map((h, i) => (
                  <th
                    key={h}
                    className={`py-2 text-xs font-semibold text-gray-500 dark:text-gray-400 uppercase tracking-wider ${
                      i === 0 || i === 1 ? 'text-left' : 'text-right'
                    }`}
                  >
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((d) => {
                const asset = symbolFor(d.asset_id);
                return (
                  <tr key={d.id} className="border-b border-gray-100 dark:border-white/5 last:border-0">
                    <td className="py-2.5 text-sm font-semibold text-gray-900 dark:text-white">{asset?.symbol ?? '—'}</td>
                    <td className="py-2.5 text-xs text-gray-500 dark:text-gray-400">{d.network}</td>
                    <td className="py-2.5 text-sm text-right text-gray-900 dark:text-white">
                      {formatUnits(d.amount_units, asset?.base_decimals ?? 8)}
                    </td>
                    <td className="py-2.5 text-xs text-right text-gray-500 dark:text-gray-400">
                      {d.confirmations}/{d.required_confirmations}
                    </td>
                    <td className="py-2.5 text-xs text-right text-gray-600 dark:text-gray-300">{d.status}</td>
                    <td className="py-2.5 text-xs text-right text-gray-500 dark:text-gray-400">
                      {new Date(d.detected_at).toLocaleDateString()}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
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
