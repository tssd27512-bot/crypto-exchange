/**
 * Single place that reads the Supabase config out of the Vite environment.
 *
 * Why this exists: `AdminPanel.tsx` used to build its endpoint as
 *   `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/admin-chat`
 * and POST to `${EDGE_URL}/login`. If `VITE_SUPABASE_URL` was set with a
 * trailing slash (both `https://x.supabase.co` and `https://x.supabase.co/`
 * are valid-looking values) the request went to `.../admin-chat//login`, and
 * if the variable was missing entirely the request went to
 * `undefined/functions/v1/admin-chat/login` — a relative URL on the site
 * itself. Either way the caller saw a confusing failure with no clue why.
 *
 * So: trim + strip trailing slashes once, here, and fail with a message that
 * names the missing variable instead of firing a request at `undefined/...`.
 */

// Static member access on import.meta.env: Vite replaces these textually at
// build time. A dynamic lookup (import.meta.env[name]) is NOT substituted and
// would silently yield undefined in a production bundle.
const RAW_SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
const RAW_SUPABASE_ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY;

function str(value: unknown): string {
  return typeof value === 'string' ? value.trim() : '';
}

/** Supabase project base URL, normalised to have no trailing slash. */
export const SUPABASE_URL = str(RAW_SUPABASE_URL).replace(/\/+$/, '');

/** Supabase anon (public) key. Ships in the client bundle by design. */
export const SUPABASE_ANON_KEY = str(RAW_SUPABASE_ANON_KEY);

const EDGE_FUNCTION_PATH = '/functions/v1/admin-chat';

/** Names of any required env vars that are missing or blank. */
export function missingSupabaseEnvVars(): string[] {
  const missing: string[] = [];
  if (!SUPABASE_URL) missing.push('VITE_SUPABASE_URL');
  if (!SUPABASE_ANON_KEY) missing.push('VITE_SUPABASE_ANON_KEY');
  return missing;
}

function requireEnvVars(): void {
  const missing = missingSupabaseEnvVars();
  if (missing.length > 0) {
    throw new Error(
      `Supabase is not configured: ${missing.join(', ')} ${missing.length === 1 ? 'is' : 'are'} ` +
        `missing from the build environment. Set ${missing.join(' and ')} and rebuild.`,
    );
  }
}

/** Base URL of the admin-chat edge function, without a trailing slash. */
export function adminChatUrl(): string {
  requireEnvVars();
  return `${SUPABASE_URL}${EDGE_FUNCTION_PATH}`;
}

/**
 * Headers every admin-chat request needs. Declared as a function (not a
 * module-level object) so the missing-env error surfaces in the UI at the
 * moment of the request rather than blanking the whole page on import.
 */
export function adminChatHeaders(): Record<string, string> {
  requireEnvVars();
  return {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
    apikey: SUPABASE_ANON_KEY,
  };
}
