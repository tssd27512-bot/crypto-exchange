/**
 * Login rate limiting.
 *
 * Two independent buckets, both counting *failed* login attempts in a sliding
 * window:
 *   - per client IP,      default 20 failures / 15 min
 *   - per username,       default  8 failures / 15 min
 *
 * The counting itself is durable (a Postgres table, see the
 * `admin_login_rate_limit` migration); this module holds the pure decision
 * logic so it can be unit-tested without a database, plus the client-IP
 * extraction the handler feeds it.
 *
 * Numbers are deliberately low-ish: this is a single-operator admin login, not
 * a public API. A successful login resets nothing automatically — see the
 * migration's `admin_record_login_attempt` for the window semantics.
 *
 * No Deno-specific APIs (WebCrypto-free, Headers is standard) — testable under
 * Deno, Bun and Node. See tests/rate_limit.test.ts.
 */

export const DEFAULT_LOGIN_IP_LIMIT = 20;
export const DEFAULT_LOGIN_USERNAME_LIMIT = 8;
export const DEFAULT_LOGIN_WINDOW_SECONDS = 900; // 15 minutes

/** Hard bounds so a typo in a secret cannot disable limiting or lock everyone out forever. */
const MIN_LIMIT = 1;
const MAX_LIMIT = 10_000;
const MIN_WINDOW_SECONDS = 30;
const MAX_WINDOW_SECONDS = 24 * 60 * 60;

export interface RateLimitPolicy {
  ipLimit: number;
  usernameLimit: number;
  windowSeconds: number;
}

/**
 * Headers a client IP may arrive in, in priority order. Supabase's edge
 * runtime (and the proxies in front of it) put the caller's address in
 * `x-forwarded-for`; the others are kept for deployments behind a different
 * gateway. When none of them is present the IP bucket cannot be applied — the
 * username bucket still is, and the handler logs that the IP was unknown.
 */
export const CLIENT_IP_HEADERS = [
  "x-forwarded-for",
  "cf-connecting-ip",
  "fly-client-ip",
  "x-real-ip",
  "x-client-ip",
] as const;

export function parseBoundedInt(
  raw: string | undefined | null,
  fallback: number,
  min: number,
  max: number,
): number {
  const parsed = Number.parseInt(String(raw ?? "").trim(), 10);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.min(max, Math.max(min, parsed));
}

export function parseRateLimitPolicy(
  getEnv: (name: string) => string | undefined,
): RateLimitPolicy {
  return {
    ipLimit: parseBoundedInt(
      getEnv("ADMIN_LOGIN_IP_LIMIT"),
      DEFAULT_LOGIN_IP_LIMIT,
      MIN_LIMIT,
      MAX_LIMIT,
    ),
    usernameLimit: parseBoundedInt(
      getEnv("ADMIN_LOGIN_USERNAME_LIMIT"),
      DEFAULT_LOGIN_USERNAME_LIMIT,
      MIN_LIMIT,
      MAX_LIMIT,
    ),
    windowSeconds: parseBoundedInt(
      getEnv("ADMIN_LOGIN_WINDOW_SECONDS"),
      DEFAULT_LOGIN_WINDOW_SECONDS,
      MIN_WINDOW_SECONDS,
      MAX_WINDOW_SECONDS,
    ),
  };
}

/**
 * Normalise one address out of a header value. Returns null when the value is
 * not usable, so the caller can fall back to username-only limiting rather than
 * bucketing every anonymous caller together (which would let one attacker lock
 * the owner out from anywhere).
 */
export function normalizeIp(raw: string | undefined | null): string | null {
  if (typeof raw !== "string") return null;
  let value = raw.trim();
  if (!value) return null;
  // x-forwarded-for is a comma-separated chain: the first entry is the client.
  const comma = value.indexOf(",");
  if (comma !== -1) value = value.slice(0, comma).trim();
  if (!value) return null;
  if (value.startsWith("[")) {
    const close = value.indexOf("]");
    if (close === -1) return null;
    value = value.slice(1, close); // bracketed IPv6, possibly with :port outside
  } else if (/^\d{1,3}(\.\d{1,3}){3}:\d+$/.test(value)) {
    value = value.slice(0, value.lastIndexOf(":")); // IPv4:port
  }
  value = value.trim().toLowerCase();
  if (!value || value.length > 45) return null;
  // Keep it to characters an IP literal (v4 or v6) can contain.
  if (!/^[0-9a-f.:]+$/.test(value)) return null;
  return value;
}

/** First usable client IP out of the request headers, or null. */
export function clientIpFromHeaders(headers: Headers): string | null {
  for (const name of CLIENT_IP_HEADERS) {
    const candidate = normalizeIp(headers.get(name));
    if (candidate) return candidate;
  }
  return null;
}

export interface RateLimitSnapshot {
  /** Failure timestamps (unix seconds, ascending) for the client IP bucket. */
  ipFailures: number[];
  /** Failure timestamps (unix seconds, ascending) for the username bucket. */
  usernameFailures: number[];
}

export interface RateLimitDecision {
  blocked: boolean;
  /** Which bucket blocked the request, or null when it is allowed. */
  scope: "ip" | "username" | null;
  /** Seconds until the blocking bucket is usable again (0 when not blocked). */
  retryAfterSeconds: number;
  ipFailures: number;
  usernameFailures: number;
}

/**
 * Timestamps arrive from PostgREST as ISO strings; turn them into unix seconds
 * for the comparison below. Unparseable entries are dropped rather than
 * poisoning the whole bucket.
 */
export function failuresToEpochSeconds(timestamps: readonly unknown[]): number[] {
  const out: number[] = [];
  for (const value of timestamps) {
    if (typeof value !== "string" && typeof value !== "number") continue;
    const ms = typeof value === "number" ? value * 1000 : Date.parse(value);
    if (Number.isFinite(ms)) out.push(Math.floor(ms / 1000));
  }
  return out.sort((a, b) => a - b);
}

/**
 * How long until `count >= limit` is false again, i.e. until enough of the
 * oldest failures have fallen out of the window. Returns 0 when not blocked.
 */
function retryAfterSeconds(
  failures: readonly number[],
  limit: number,
  nowSeconds: number,
  windowSeconds: number,
): number {
  if (failures.length < limit) return 0;
  // The failure that has to age out for the count to drop below the limit.
  const offset = failures.length - limit;
  const expiresAt = failures[offset] + windowSeconds;
  return Math.max(1, Math.ceil(expiresAt - nowSeconds));
}

/**
 * Decide whether a login attempt may proceed.
 *
 * `limit` is the number of failures allowed *before* blocking, so with an IP
 * limit of 20 the 21st failed attempt in the window is refused.
 */
export function evaluateLoginRateLimit(input: {
  snapshot: RateLimitSnapshot;
  policy: RateLimitPolicy;
  nowSeconds: number;
}): RateLimitDecision {
  const { snapshot, policy, nowSeconds } = input;

  const ipRetry = retryAfterSeconds(
    snapshot.ipFailures,
    policy.ipLimit,
    nowSeconds,
    policy.windowSeconds,
  );
  const usernameRetry = retryAfterSeconds(
    snapshot.usernameFailures,
    policy.usernameLimit,
    nowSeconds,
    policy.windowSeconds,
  );

  const decision: RateLimitDecision = {
    blocked: ipRetry > 0 || usernameRetry > 0,
    scope: null,
    retryAfterSeconds: 0,
    ipFailures: snapshot.ipFailures.length,
    usernameFailures: snapshot.usernameFailures.length,
  };

  if (!decision.blocked) {
    return decision;
  }
  // Report the bucket that keeps the caller out longest.
  if (ipRetry >= usernameRetry) {
    decision.scope = "ip";
    decision.retryAfterSeconds = ipRetry;
  } else {
    decision.scope = "username";
    decision.retryAfterSeconds = usernameRetry;
  }
  return decision;
}
