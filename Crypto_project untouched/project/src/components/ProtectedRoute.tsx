import { ReactNode } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { Loader2, ShieldAlert } from 'lucide-react';
import { useAuth } from '@/hooks/useAuth';

/**
 * Everything under the trading dashboard requires a Supabase session. While the
 * session is still being resolved we show a quiet loader instead of flashing the
 * sign-in page; with no session we redirect, remembering where the user was.
 */
export default function ProtectedRoute({ children }: { children: ReactNode }) {
  const { session, loading, unavailable } = useAuth();
  const location = useLocation();

  if (loading) {
    return (
      <div className="min-h-screen bg-surface-light-2 dark:bg-surface-dark flex items-center justify-center">
        <div className="flex items-center gap-3 text-sm text-gray-500 dark:text-gray-400">
          <Loader2 className="w-5 h-5 animate-spin" />
          Checking your session…
        </div>
      </div>
    );
  }

  if (!session) {
    if (unavailable) {
      return (
        <div className="min-h-screen bg-surface-light-2 dark:bg-surface-dark flex items-center justify-center p-6">
          <div className="max-w-md rounded-2xl bg-white dark:bg-surface-dark-2 border border-gray-200 dark:border-white/5 card-glow p-6 text-center">
            <ShieldAlert className="w-8 h-8 text-amber-500 mx-auto mb-3" />
            <h2 className="text-lg font-semibold text-gray-900 dark:text-white mb-2">
              Sign-in is not available yet
            </h2>
            <p className="text-sm text-gray-500 dark:text-gray-400">{unavailable}</p>
          </div>
        </div>
      );
    }
    return <Navigate to="/sign-in" replace state={{ from: location.pathname }} />;
  }

  return <>{children}</>;
}
