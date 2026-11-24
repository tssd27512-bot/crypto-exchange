import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import {
  Building2, Bitcoin, ArrowRight, Wallet, ChevronDown,
  ArrowDownToLine, Loader2, AlertCircle,
} from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import {
  fetchMyBalances,
  fetchMyWithdrawals,
  fetchWithdrawalNetworks,
  formatUnits,
  parseUnits,
  quoteWithdrawalFee,
  toApiFailure,
  units,
  useQuery,
  useRealtimeTable,
  type BalanceRow,
  type QueryResult,
  type WithdrawalNetworkRow,
  type WithdrawalRow,
} from '@/lib/api';
import { EmptyState, ErrorBlock, InfoNote, LoadingBlock, UnavailableBlock } from '@/components/DataState';

type Method = 'bank' | 'crypto';

export default function Withdraw() {
  const balances = useQuery<BalanceRow[]>('wd-balances', fetchMyBalances);
  const networks = useQuery<WithdrawalNetworkRow[]>('wd-networks', fetchWithdrawalNetworks);
  const history = useQuery<WithdrawalRow[]>('wd-history', fetchMyWithdrawals);

  useRealtimeTable('withdrawal_requests', { onChange: history.reload });
  useRealtimeTable('balances', { onChange: balances.reload });

  const [method, setMethod] = useState<Method>('crypto');
  const [assetSymbol, setAssetSymbol] = useState<string | null>(null);
  const [coinDropdown, setCoinDropdown] = useState(false);
  const [amount, setAmount] = useState('');
  const [walletAddress, setWalletAddress] = useState('');
  const [fee, setFee] = useState<string | null>(null);
  const [feeError, setFeeError] = useState<string | null>(null);

  const balanceRows = balances.state.status === 'ready' ? balances.state.data : [];
  const networkRows = networks.state.status === 'ready' ? networks.state.data : [];

  const heldBalances = balanceRows.filter((b) => units(b.total_units) > 0n || units(b.available_units) > 0n);
  const selected = useMemo(
    () => heldBalances.find((b) => b.symbol === assetSymbol) ?? heldBalances[0] ?? null,
    [heldBalances, assetSymbol],
  );

  const assetNetworks = selected
    ? networkRows.filter((n) => n.asset_id === selected.asset_id)
    : [];
  const network = assetNetworks[0]?.network ?? null;

  const amountUnits = selected ? parseUnits(amount || '0', selected.base_decimals) : null;

  useEffect(() => {
    setFee(null);
    setFeeError(null);
    if (!selected || !network || amountUnits === null || amountUnits === 0n) return;
    let cancelled = false;
    quoteWithdrawalFee(selected.symbol, network, amountUnits)
      .then((res) => {
        if (cancelled) return;
        setFee(String(res));
      })
      .catch((err) => {
        if (cancelled) return;
        setFeeError(toApiFailure(err).message);
      });
    return () => {
      cancelled = true;
    };
  }, [selected, network, amountUnits]);

  const hasFunds = heldBalances.length > 0;

  return (
    <DashboardLayout title="Withdraw">
      <PageHeader title="Withdraw" subtitle="Withdrawals run through the exchange's own withdrawal state machine" />

      <div className="max-w-2xl space-y-6">
        {/* Balance display */}
        <div className="rounded-2xl bg-gradient-to-br from-surface-light dark:from-surface-dark-2 to-surface-light-2 dark:to-surface-dark-3 border border-gray-200 dark:border-white/5 p-6 card-glow">
          <p className="text-sm text-gray-500 dark:text-gray-400 mb-1">Available Balance</p>
          {balances.state.status === 'loading' ? (
            <div className="flex items-center gap-2 text-gray-400">
              <Loader2 className="w-5 h-5 animate-spin" /> <span className="text-sm">Loading…</span>
            </div>
          ) : balances.state.status === 'unavailable' ? (
            <p className="text-sm text-gray-500 dark:text-gray-400">
              Not available yet — the exchange backend has not been deployed to this project.
            </p>
          ) : balances.state.status === 'error' ? (
            <p className="text-sm text-red-600 dark:text-red-400">Could not load your balances.</p>
          ) : selected ? (
            <div className="flex items-center gap-3">
              <h3 className="text-3xl font-bold text-gray-900 dark:text-white">
                {formatUnits(selected.available_units, selected.base_decimals)}
              </h3>
              <span className="px-2.5 py-1 rounded-md text-xs font-medium bg-gray-100 dark:bg-white/5 text-gray-500 dark:text-gray-400">
                {selected.symbol}
              </span>
              {units(selected.locked_units) > 0n && (
                <span className="text-xs text-gray-500 dark:text-gray-400">
                  {formatUnits(selected.locked_units, selected.base_decimals)} locked
                </span>
              )}
            </div>
          ) : (
            <h3 className="text-3xl font-bold text-gray-900 dark:text-white">0</h3>
          )}
        </div>

        {!hasFunds ? (
          <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-10 text-center">
            <div className="w-16 h-16 rounded-full bg-gray-100 dark:bg-white/5 flex items-center justify-center mx-auto mb-5">
              <Wallet className="w-8 h-8 text-gray-300 dark:text-gray-600" />
            </div>
            <h3 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
              No funds available to withdraw yet
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400 mb-6">
              {balances.state.status === 'ready'
                ? 'Your account holds no balance yet, so there is nothing to withdraw.'
                : 'Your balances are not available yet — the exchange backend has not been deployed to this project.'}
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

            {method === 'bank' ? (
              <EmptyState
                icon={<Building2 className="w-6 h-6 text-gray-300 dark:text-gray-600" />}
                title="Bank withdrawals are not open yet"
                description="No fiat payout provider is configured, so no bank withdrawal can be requested."
              />
            ) : (
              <form onSubmit={(e) => e.preventDefault()} className="space-y-5">
                {/* Asset */}
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Asset</label>
                  <div className="relative">
                    <button
                      type="button"
                      onClick={() => setCoinDropdown(!coinDropdown)}
                      className="w-full flex items-center justify-between px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white hover:border-brand-500 dark:hover:border-brand-600 transition-all"
                    >
                      <span className="flex items-center gap-2">
                        <span className="font-semibold">{selected?.symbol}</span>
                        <span className="text-gray-500 dark:text-gray-400">
                          {formatUnits(selected?.available_units, selected?.base_decimals ?? 8)} available
                        </span>
                      </span>
                      <ChevronDown className="w-4 h-4 text-gray-400" />
                    </button>
                    {coinDropdown && (
                      <div className="absolute top-full left-0 right-0 mt-1 rounded-xl bg-white dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 shadow-xl overflow-hidden z-10">
                        {heldBalances.map((b) => (
                          <button
                            key={b.asset_id}
                            type="button"
                            onClick={() => {
                              setAssetSymbol(b.symbol);
                              setCoinDropdown(false);
                            }}
                            className="w-full flex items-center gap-3 px-4 py-2.5 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-white/5 transition-colors text-left"
                          >
                            <span className="font-semibold w-12">{b.symbol}</span>
                            <span className="text-gray-500 dark:text-gray-400">
                              {formatUnits(b.available_units, b.base_decimals)} available
                            </span>
                          </button>
                        ))}
                      </div>
                    )}
                  </div>
                </div>

                {/* Amount */}
                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">Amount</label>
                  <div className="relative">
                    <input
                      type="text"
                      inputMode="decimal"
                      value={amount}
                      onChange={(e) => setAmount(e.target.value)}
                      placeholder="0.00"
                      className="w-full pl-4 pr-20 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all"
                    />
                    <button
                      type="button"
                      onClick={() =>
                        setAmount(formatUnits(selected?.available_units, selected?.base_decimals ?? 8))
                      }
                      className="absolute right-3 top-1/2 -translate-y-1/2 px-2.5 py-1 text-xs font-semibold text-brand-600 dark:text-brand-400 bg-brand-50 dark:bg-brand-950/40 rounded-md hover:bg-brand-100 dark:hover:bg-brand-950/60 transition-colors"
                    >
                      Max
                    </button>
                  </div>
                  {selected && amount !== '' && amountUnits === null && (
                    <p className="text-[11px] text-amber-600 dark:text-amber-400 mt-1">
                      Enter a decimal amount with at most {selected.base_decimals} decimals.
                    </p>
                  )}
                </div>

                {/* Network + fee */}
                <div className="rounded-xl bg-gray-50 dark:bg-surface-dark-3 px-4 py-3 text-xs text-gray-500 dark:text-gray-400 space-y-1">
                  <div className="flex justify-between">
                    <span>Network</span>
                    <span className="font-semibold text-gray-900 dark:text-white">
                      {network ?? (networks.state.status === 'ready' ? 'none configured' : '—')}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span>Fee (engine quote)</span>
                    <span className="font-semibold text-gray-900 dark:text-white">
                      {feeError
                        ? 'unavailable'
                        : fee !== null && selected
                        ? `${formatUnits(fee, selected.base_decimals)} ${selected.symbol}`
                        : '—'}
                    </span>
                  </div>
                </div>

                <div>
                  <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1.5">
                    Destination Wallet Address
                  </label>
                  <input
                    type="text"
                    value={walletAddress}
                    onChange={(e) => setWalletAddress(e.target.value)}
                    placeholder="Enter wallet address"
                    className="w-full px-4 py-3 text-sm rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-200 dark:border-white/10 text-gray-900 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:outline-none focus:border-brand-500 dark:focus:border-brand-600 focus:ring-2 focus:ring-brand-500/20 transition-all font-mono"
                  />
                </div>

                <button
                  type="button"
                  disabled
                  className="w-full inline-flex items-center justify-center gap-2 px-6 py-3.5 text-sm font-semibold text-white bg-gradient-to-r from-brand-600 to-brand-700 rounded-xl transition-all opacity-50 cursor-not-allowed"
                >
                  Withdraw Funds
                  <ArrowRight className="w-4 h-4" />
                </button>

                <div className="flex items-start gap-2 rounded-xl bg-amber-50 dark:bg-amber-500/10 border border-amber-200/40 dark:border-amber-500/20 px-4 py-3">
                  <AlertCircle className="w-4 h-4 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" />
                  <p className="text-xs text-amber-700 dark:text-amber-300 leading-relaxed">
                    Withdrawal requests cannot be created from the browser yet: the backend exposes
                    <code className="mx-1 font-mono">record_withdrawal_request</code>
                    to the operator/service role only, and no custody provider is configured. The form above
                    is not submitting anything — nothing is held or sent.
                  </p>
                </div>
              </form>
            )}
          </div>
        )}

        <WithdrawalHistory history={history} balances={balanceRows} />

        <InfoNote>
          Withdrawals move through pending → approved → processing → completed, enforced by the backend's
          state machine. Funds are held only when an operator approves the request.
        </InfoNote>
      </div>
    </DashboardLayout>
  );
}

function WithdrawalHistory({
  history,
  balances,
}: {
  history: QueryResult<WithdrawalRow[]>;
  balances: BalanceRow[];
}) {
  const rows = history.state.status === 'ready' ? history.state.data : [];
  const decimalsFor = (assetId: string) =>
    balances.find((b) => b.asset_id === assetId)?.base_decimals ?? 8;
  const symbolFor = (assetId: string) => balances.find((b) => b.asset_id === assetId)?.symbol ?? '—';

  return (
    <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
      <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-4">Your Withdrawals</h3>
      {history.state.status === 'loading' ? (
        <LoadingBlock label="Loading withdrawals…" compact />
      ) : history.state.status === 'unavailable' ? (
        <UnavailableBlock failure={history.state.failure} onRetry={history.reload} compact />
      ) : history.state.status === 'error' ? (
        <ErrorBlock failure={history.state.failure} onRetry={history.reload} compact />
      ) : rows.length === 0 ? (
        <EmptyState
          title="No withdrawals yet"
          description="Requests recorded against your account will appear here with their status."
          compact
        />
      ) : (
        <div className="space-y-2">
          {rows.map((w) => (
            <div
              key={w.id}
              className="flex items-center justify-between gap-3 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 px-3 py-2.5"
            >
              <div className="min-w-0">
                <p className="text-xs font-semibold text-gray-900 dark:text-white">
                  {formatUnits(w.amount_units, decimalsFor(w.asset_id))} {symbolFor(w.asset_id)} · {w.network}
                </p>
                <p className="text-[11px] text-gray-500 dark:text-gray-400 truncate font-mono">
                  {w.destination_address}
                </p>
              </div>
              <div className="text-right shrink-0">
                <p className="text-[11px] font-medium text-gray-700 dark:text-gray-300">{w.status}</p>
                <p className="text-[11px] text-gray-400 dark:text-gray-500">
                  {new Date(w.requested_at).toLocaleDateString()}
                </p>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
