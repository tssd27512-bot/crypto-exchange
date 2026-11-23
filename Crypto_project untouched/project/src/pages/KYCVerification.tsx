import { Clock, Check, Info, ShieldCheck, FileCheck, Lock } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import {
  fetchKycLevels,
  fetchMyKycStatus,
  useQuery,
  type KycLevelRow,
  type KycStatusRow,
} from '@/lib/api';
import { ErrorBlock, InfoNote, LoadingBlock, UnavailableBlock } from '@/components/DataState';

export default function KYCVerification() {
  const status = useQuery<KycStatusRow | null>('kyc-status', fetchMyKycStatus);
  const levels = useQuery<KycLevelRow[]>('kyc-levels', fetchKycLevels);

  const currentLevel = status.state.status === 'ready' ? status.state.data?.level ?? null : null;
  const levelRows = levels.state.status === 'ready' ? levels.state.data : [];
  const currentLevelName =
    currentLevel !== null ? levelRows.find((l) => l.level === currentLevel)?.name ?? `level ${currentLevel}` : null;

  return (
    <DashboardLayout title="KYC Verification">
      <PageHeader title="KYC Verification" subtitle="Your identity tier, read from the exchange backend" />

      <div className="max-w-2xl space-y-6">
        {/* Status badge — real value from my_kyc_status() */}
        {status.state.status === 'loading' ? (
          <LoadingBlock label="Reading your KYC status…" compact />
        ) : status.state.status === 'unavailable' ? (
          <UnavailableBlock failure={status.state.failure} onRetry={status.reload} compact />
        ) : status.state.status === 'error' ? (
          <ErrorBlock failure={status.state.failure} onRetry={status.reload} compact />
        ) : (
          <div className="flex items-center gap-3 rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-5">
            <div
              className={`w-10 h-10 rounded-xl flex items-center justify-center ${
                currentLevel && currentLevel > 0
                  ? 'bg-green-50 dark:bg-green-500/10'
                  : 'bg-yellow-50 dark:bg-yellow-500/10'
              }`}
            >
              {currentLevel && currentLevel > 0 ? (
                <Check className="w-5 h-5 text-green-500" />
              ) : (
                <Clock className="w-5 h-5 text-yellow-500" />
              )}
            </div>
            <div>
              <div className="flex items-center gap-2">
                <span className="text-sm font-semibold text-gray-900 dark:text-white">
                  {currentLevelName ?? 'Unknown level'}
                </span>
                <span
                  className={`px-2 py-0.5 rounded-md text-xs font-medium border ${
                    currentLevel && currentLevel > 0
                      ? 'bg-green-50 dark:bg-green-500/10 text-green-600 dark:text-green-400 border-green-200/40 dark:border-green-500/20'
                      : 'bg-yellow-50 dark:bg-yellow-500/10 text-yellow-600 dark:text-yellow-400 border-yellow-200/40 dark:border-yellow-500/20'
                  }`}
                >
                  {currentLevel === null ? 'no status' : `level ${currentLevel}`}
                </span>
              </div>
              <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
                {status.state.data?.provider
                  ? `Checked by ${status.state.data.provider}`
                  : 'No verification provider has checked this account.'}
                {status.state.data?.updated_at
                  ? ` · updated ${new Date(status.state.data.updated_at).toLocaleDateString()}`
                  : ''}
              </p>
            </div>
          </div>
        )}

        {/* Tiers */}
        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
          <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-4">Verification tiers</h3>
          {levels.state.status === 'unavailable' ? (
            <UnavailableBlock failure={levels.state.failure} onRetry={levels.reload} compact />
          ) : levels.state.status === 'loading' ? (
            <LoadingBlock label="Loading tiers…" compact />
          ) : levels.state.status === 'error' ? (
            <ErrorBlock failure={levels.state.failure} onRetry={levels.reload} compact />
          ) : (
            <div className="space-y-2">
              {levelRows.map((l) => {
                const reached = currentLevel !== null && l.level <= currentLevel;
                return (
                  <div
                    key={l.level}
                    className="flex items-start gap-3 rounded-xl bg-gray-50 dark:bg-surface-dark-3 border border-gray-100 dark:border-white/5 px-4 py-3"
                  >
                    <div
                      className={`w-7 h-7 rounded-full flex items-center justify-center shrink-0 ${
                        reached ? 'bg-green-500 text-white' : 'bg-gray-200 dark:bg-white/10 text-gray-400'
                      }`}
                    >
                      {reached ? <Check className="w-4 h-4" /> : <Lock className="w-3.5 h-3.5" />}
                    </div>
                    <div>
                      <p className="text-sm font-medium text-gray-900 dark:text-white capitalize">
                        {l.name}
                      </p>
                      <p className="text-xs text-gray-500 dark:text-gray-400">{l.description}</p>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        {/* Submission path */}
        <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
          <div className="flex items-start gap-3">
            <div className="w-10 h-10 rounded-xl bg-brand-50 dark:bg-brand-950/40 flex items-center justify-center shrink-0">
              <FileCheck className="w-5 h-5 text-brand-600 dark:text-brand-400" />
            </div>
            <div>
              <p className="text-sm font-semibold text-gray-900 dark:text-white mb-1">
                Identity checks are not open yet
              </p>
              <p className="text-xs text-gray-500 dark:text-gray-400 leading-relaxed">
                No KYC provider is connected, so no document can be uploaded and no application can be
                submitted from this page. When a provider is connected, this is where the check starts;
                a verification level is only ever granted by the exchange backend after the provider
                approves it.
              </p>
            </div>
          </div>
        </div>

        {/* Security note */}
        <div className="flex items-start gap-3 rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-5">
          <ShieldCheck className="w-5 h-5 text-brand-600 dark:text-brand-400 shrink-0 mt-0.5" />
          <div>
            <p className="text-sm font-medium text-gray-900 dark:text-white mb-1">Your data is protected</p>
            <p className="text-xs text-gray-500 dark:text-gray-400 leading-relaxed">
              The exchange database stores no identity documents and no personal data — only opaque
              references supplied by the provider, with a guard that rejects personal-data fields.
            </p>
          </div>
        </div>

        <InfoNote>
          <span className="inline-flex items-center gap-1.5">
            <Info className="w-3.5 h-3.5" />
            Your tier comes from the backend's own KYC record; nothing on this page can raise it.
          </span>
        </InfoNote>
      </div>
    </DashboardLayout>
  );
}
