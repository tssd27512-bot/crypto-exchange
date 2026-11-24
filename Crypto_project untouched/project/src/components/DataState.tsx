/**
 * Shared, honest states for data-backed panels.
 *
 * The exchange backend is not deployed to the live project yet, so "the table
 * does not exist" is an expected outcome, not a crash and not an excuse to show
 * invented numbers. Every data panel uses one of these three blocks:
 *   loading  — quiet spinner
 *   unavailable — the backend object is missing (pre-deployment)
 *   error    — a real failure, with the real message
 * plus EmptyState for a query that succeeded and legitimately returned nothing.
 */
import { ReactNode } from 'react';
import { AlertTriangle, CloudOff, Inbox, Loader2, RefreshCw } from 'lucide-react';
import type { ApiFailure } from '@/lib/api';

const card = 'rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 p-6';

export function LoadingBlock({ label = 'Loading…', compact = false }: { label?: string; compact?: boolean }) {
  return (
    <div className={`${card} ${compact ? 'py-5' : 'py-10'} flex items-center justify-center gap-3 text-sm text-gray-500 dark:text-gray-400`}>
      <Loader2 className="w-4 h-4 animate-spin" />
      {label}
    </div>
  );
}

export function UnavailableBlock({
  failure,
  onRetry,
  compact = false,
}: {
  failure: ApiFailure;
  onRetry?: () => void;
  compact?: boolean;
}) {
  return (
    <div
      className={`${card} ${compact ? 'py-5' : 'py-10'} flex flex-col items-center text-center gap-2`}
    >
      <div className="w-11 h-11 rounded-full bg-amber-50 dark:bg-amber-500/10 flex items-center justify-center">
        <CloudOff className="w-5 h-5 text-amber-500" />
      </div>
      <p className="text-sm font-medium text-gray-900 dark:text-white">Not available yet</p>
      <p className="text-xs text-gray-500 dark:text-gray-400 max-w-sm">{failure.message}</p>
      {failure.detail && (
        <p className="text-[11px] font-mono text-gray-400 dark:text-gray-600 break-all max-w-md">
          {failure.detail}
        </p>
      )}
      {onRetry && <RetryButton onClick={onRetry} />}
    </div>
  );
}

export function ErrorBlock({
  failure,
  onRetry,
  compact = false,
}: {
  failure: ApiFailure;
  onRetry?: () => void;
  compact?: boolean;
}) {
  return (
    <div
      className={`${card} ${compact ? 'py-5' : 'py-10'} flex flex-col items-center text-center gap-2`}
    >
      <div className="w-11 h-11 rounded-full bg-red-50 dark:bg-red-500/10 flex items-center justify-center">
        <AlertTriangle className="w-5 h-5 text-red-500" />
      </div>
      <p className="text-sm font-medium text-gray-900 dark:text-white">Could not load this data</p>
      <p className="text-xs text-gray-500 dark:text-gray-400 max-w-sm">{failure.message}</p>
      {failure.detail && (
        <p className="text-[11px] font-mono text-gray-400 dark:text-gray-600 break-all max-w-md">
          {failure.detail}
        </p>
      )}
      {onRetry && <RetryButton onClick={onRetry} />}
    </div>
  );
}

export function EmptyState({
  title,
  description,
  icon,
  action,
  compact = false,
}: {
  title: string;
  description?: string;
  icon?: ReactNode;
  action?: ReactNode;
  compact?: boolean;
}) {
  return (
    <div className={`flex flex-col items-center justify-center text-center ${compact ? 'py-6' : 'py-12'}`}>
      <div className="w-14 h-14 rounded-full bg-gray-100 dark:bg-white/5 flex items-center justify-center mb-3">
        {icon ?? <Inbox className="w-6 h-6 text-gray-300 dark:text-gray-600" />}
      </div>
      <p className="text-sm font-medium text-gray-900 dark:text-white mb-1">{title}</p>
      {description && <p className="text-xs text-gray-500 dark:text-gray-400 max-w-sm">{description}</p>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}

export function RetryButton({ onClick }: { onClick: () => void }) {
  return (
    <button
      onClick={onClick}
      className="mt-1 inline-flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded-lg bg-gray-100 dark:bg-white/5 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-white/10 transition-colors"
    >
      <RefreshCw className="w-3.5 h-3.5" />
      Retry
    </button>
  );
}

/** Small inline note in the existing brand tint, used for "why this is empty". */
export function InfoNote({ children }: { children: ReactNode }) {
  return (
    <div className="flex items-start gap-2 rounded-xl bg-brand-50 dark:bg-brand-950/30 border border-brand-200/30 dark:border-brand-800/20 px-4 py-3">
      <AlertTriangle className="w-4 h-4 text-brand-600 dark:text-brand-400 shrink-0 mt-0.5" />
      <p className="text-xs text-brand-700 dark:text-brand-300 leading-relaxed">{children}</p>
    </div>
  );
}
