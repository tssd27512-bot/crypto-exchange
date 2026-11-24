/**
 * Stage 6 — the session the whole app reads.
 *
 * Supabase Auth is the only identity source (SCHEMA.md §4: identity is always
 * auth.users.id taken from the verified JWT). Nothing here stores a user id,
 * and no protected page renders before the session has been resolved.
 */
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  ReactNode,
} from 'react';
import type { Session, User } from '@supabase/supabase-js';
import { supabase } from '@/lib/supabase';
import { backendConfigured } from '@/lib/api';

export interface SignUpMeta {
  firstName?: string;
  lastName?: string;
}

interface AuthContextValue {
  session: Session | null;
  user: User | null;
  /** True until the first session read has completed (success or failure). */
  loading: boolean;
  /** Set when the Supabase client is not configured in this build. */
  unavailable: string | null;
  displayName: string;
  initials: string;
  signIn: (email: string, password: string) => Promise<{ error: string | null }>;
  signUp: (
    email: string,
    password: string,
    meta: SignUpMeta,
  ) => Promise<{ error: string | null; needsEmailConfirmation: boolean }>;
  signOut: () => Promise<void>;
}

const AuthContext = createContext<AuthContextValue | null>(null);

function friendlyAuthError(message: string): string {
  const text = message.toLowerCase();
  if (text.includes('invalid login credentials')) return 'Email or password is incorrect.';
  if (text.includes('email not confirmed')) return 'Confirm your email address before signing in.';
  if (text.includes('user already registered')) return 'An account with that email already exists.';
  if (text.includes('password should be at least')) return message;
  if (text.includes('failed to fetch') || text.includes('network')) {
    return 'Could not reach the authentication service. Check your connection and try again.';
  }
  return message;
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [unavailable, setUnavailable] = useState<string | null>(null);

  useEffect(() => {
    if (!backendConfigured) {
      setUnavailable(
        'Authentication is not configured in this build (VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY are missing).',
      );
      setLoading(false);
      return;
    }

    let cancelled = false;

    supabase.auth
      .getSession()
      .then(({ data, error }) => {
        if (cancelled) return;
        if (error) setUnavailable(friendlyAuthError(error.message));
        setSession(data.session ?? null);
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        setUnavailable(
          err instanceof Error ? friendlyAuthError(err.message) : 'Could not read the session.',
        );
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    const { data: sub } = supabase.auth.onAuthStateChange((_event, next) => {
      setSession(next);
      setLoading(false);
    });

    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
    };
  }, []);

  const signIn = useCallback(async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    return { error: error ? friendlyAuthError(error.message) : null };
  }, []);

  const signUp = useCallback(async (email: string, password: string, meta: SignUpMeta) => {
    const { data, error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: {
          first_name: meta.firstName ?? null,
          last_name: meta.lastName ?? null,
        },
      },
    });
    if (error) return { error: friendlyAuthError(error.message), needsEmailConfirmation: false };
    // Supabase returns no session when the project requires email confirmation.
    return { error: null, needsEmailConfirmation: !data.session };
  }, []);

  const signOut = useCallback(async () => {
    await supabase.auth.signOut();
  }, []);

  const user = session?.user ?? null;

  const displayName = useMemo(() => {
    if (!user) return '';
    const meta = (user.user_metadata ?? {}) as Record<string, unknown>;
    const first = typeof meta.first_name === 'string' ? meta.first_name : '';
    const last = typeof meta.last_name === 'string' ? meta.last_name : '';
    const full = `${first} ${last}`.trim();
    if (full) return full;
    return user.email ?? 'Signed in';
  }, [user]);

  const initials = useMemo(() => {
    if (!user) return '··';
    const meta = (user.user_metadata ?? {}) as Record<string, unknown>;
    const first = typeof meta.first_name === 'string' ? meta.first_name : '';
    const last = typeof meta.last_name === 'string' ? meta.last_name : '';
    const fromName = `${first.charAt(0)}${last.charAt(0)}`.toUpperCase();
    if (fromName) return fromName;
    return (user.email ?? '?').charAt(0).toUpperCase();
  }, [user]);

  const value: AuthContextValue = {
    session,
    user,
    loading,
    unavailable,
    displayName,
    initials,
    signIn,
    signUp,
    signOut,
  };

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthContextValue {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside <AuthProvider>');
  return ctx;
}
