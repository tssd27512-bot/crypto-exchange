import { Calendar, Check, Fingerprint, Mail, ShieldCheck, User } from 'lucide-react';
import DashboardLayout, { PageHeader } from '@/components/dashboard/DashboardLayout';
import { useAuth } from '@/hooks/useAuth';
import { fetchMyKycStatus, useQuery, type KycStatusRow } from '@/lib/api';
import {
  EmptyState,
  ErrorBlock,
  InfoNote,
  LoadingBlock,
  UnavailableBlock,
} from '@/components/DataState';

/**
 * Profile Settings — the signed-in user's real account.
 *
 * Identity is Supabase Auth only (SCHEMA.md §4). Everything shown here comes
 * from the session user or from backend reads the RLS policies already allow
 * (`my_kyc_status`). Anything the account does not carry is shown as "Not set"
 * or an empty state — no placeholder identity, no invented fields.
 */
function formatDate(value: string | null | undefined): string | null {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleString('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

function Field({
  icon,
  label,
  value,
  mono = false,
}: {
  icon: React.ReactNode;
  label: string;
  value: string | null;
  mono?: boolean;
}) {
  return (
    <div className="flex items-start gap-3">
      <div className="w-9 h-9 rounded-xl bg-gray-100 dark:bg-white/5 flex items-center justify-center shrink-0">
        {icon}
      </div>
      <div className="min-w-0">
        <p className="text-xs font-medium text-gray-500 dark:text-gray-400">{label}</p>
        {value ? (
          <p
            className={`text-sm text-gray-900 dark:text-white break-all ${
              mono ? 'font-mono text-xs' : ''
            }`}
          >
            {value}
          </p>
        ) : (
          <p className="text-sm text-gray-400 dark:text-gray-500 italic">Not set</p>
        )}
      </div>
    </div>
  );
}

export default function ProfileSettings() {
  const { user, loading, unavailable, displayName, initials } = useAuth();
  const kyc = useQuery<KycStatusRow | null>('profile-kyc', fetchMyKycStatus);

  return (
    <DashboardLayout title="Profile Settings">
      <PageHeader
        title="Profile Settings"
        subtitle="Your account as held by the authentication service"
      />

      <div className="max-w-2xl space-y-6">
        {loading ? (
          <LoadingBlock label="Reading your session…" />
        ) : unavailable && !user ? (
          <ErrorBlock failure={{ kind: 'error', message: unavailable }} />
        ) : !user ? (
          <EmptyState
            title="Not signed in"
            description="Sign in to view the profile held for your account."
            icon={<User className="w-6 h-6 text-gray-300 dark:text-gray-600" />}
          />
        ) : (
          <>
            {/* Identity */}
            <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
              <div className="flex items-center gap-4">
                <div className="w-16 h-16 rounded-full bg-gradient-to-br from-brand-500 to-brand-700 flex items-center justify-center text-xl font-bold text-white">
                  {initials}
                </div>
                <div className="min-w-0">
                  <h3 className="text-lg font-semibold text-gray-900 dark:text-white break-all">
                    {displayName || user.email || 'Signed in'}
                  </h3>
                  <p className="text-sm text-gray-500 dark:text-gray-400">
                    {user.email ?? 'No email on this account'}
                  </p>
                </div>
              </div>
            </div>

            {/* Account details — straight from the session user */}
            <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
              <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-4">
                Account details
              </h3>
              <div className="space-y-4">
                <Field
                  icon={<Mail className="w-4 h-4 text-gray-400" />}
                  label="Email"
                  value={user.email ?? null}
                />
                <Field
                  icon={<User className="w-4 h-4 text-gray-400" />}
                  label="Display name"
                  value={displayName && displayName !== user.email ? displayName : null}
                />
                <Field
                  icon={<Fingerprint className="w-4 h-4 text-gray-400" />}
                  label="Account ID"
                  value={user.id}
                  mono
                />
                <Field
                  icon={<Calendar className="w-4 h-4 text-gray-400" />}
                  label="Signed up"
                  value={formatDate(user.created_at)}
                />
                <Field
                  icon={<ShieldCheck className="w-4 h-4 text-gray-400" />}
                  label="Email verified"
                  value={user.email_confirmed_at ? formatDate(user.email_confirmed_at) : null}
                />
                <Field
                  icon={<Check className="w-4 h-4 text-gray-400" />}
                  label="Last sign-in"
                  value={formatDate(user.last_sign_in_at)}
                />
              </div>
            </div>

            {/* Exchange profile data readable under existing RLS */}
            <div className="rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6">
              <h3 className="text-sm font-semibold text-gray-900 dark:text-white mb-4">
                Verification profile
              </h3>
              {kyc.state.status === 'loading' && <LoadingBlock label="Reading KYC status…" compact />}
              {kyc.state.status === 'unavailable' && (
                <UnavailableBlock failure={kyc.state.failure} onRetry={kyc.reload} compact />
              )}
              {kyc.state.status === 'error' && (
                <ErrorBlock failure={kyc.state.failure} onRetry={kyc.reload} compact />
              )}
              {kyc.state.status === 'ready' &&
                (kyc.state.data ? (
                  <div className="space-y-4">
                    <Field
                      icon={<ShieldCheck className="w-4 h-4 text-gray-400" />}
                      label="KYC level"
                      value={`Level ${kyc.state.data.level}`}
                    />
                    <Field
                      icon={<User className="w-4 h-4 text-gray-400" />}
                      label="Provider"
                      value={kyc.state.data.provider}
                    />
                    <Field
                      icon={<Calendar className="w-4 h-4 text-gray-400" />}
                      label="Level updated"
                      value={formatDate(kyc.state.data.level_changed_at)}
                    />
                  </div>
                ) : (
                  <EmptyState
                    title="No KYC record yet"
                    description="This account has no verification record. Identity submission is not enabled in this build."
                    icon={<ShieldCheck className="w-6 h-6 text-gray-300 dark:text-gray-600" />}
                    compact
                  />
                ))}
            </div>

            <InfoNote>
              Editing your name, email or password is not available in this build yet. The account
              values above are read-only and come from your signed-in session.
            </InfoNote>
          </>
        )}
      </div>
    </DashboardLayout>
  );
}
