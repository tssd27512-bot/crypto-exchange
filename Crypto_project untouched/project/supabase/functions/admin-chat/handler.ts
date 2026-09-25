/**
 * admin-chat request handler.
 *
 * Route + auth behaviour:
 *
 *   POST /login            - rate limited, then credential check. Issues a
 *                            fresh signed, expiring, revocable session token.
 *   POST /logout            - revokes the session the caller presented.
 *   POST /conversations     - \
 *   POST /messages          |  require a valid session token (body `token` or
 *   POST /reply             |  the `X-Admin-Token` header).
 *   POST /close             |
 *   POST /change-password   /  also revokes every *other* session.
 *
 * The previous static shared `ADMIN_CHAT_TOKEN` gate is gone; a token is now
 * never a constant, always per-session, and always has an expiry
 * (see session.ts). Tokens are additionally checked against the
 * `admin_sessions` table so they can be revoked before expiry — see
 * `loadSession()` for how a missing table degrades gracefully.
 *
 * Everything the handler needs from the outside world arrives through
 * `HandlerDeps`, so unit tests drive this file with an in-memory store and a
 * fake clock instead of Supabase.
 */

import {
  isMissingRelationError,
  type AdminStore,
  type ConversationRecord,
  type MessageRecord,
  type SessionRecord,
} from "./admin_store.ts";
import {
  CLIENT_IP_HEADERS,
  clientIpFromHeaders,
  evaluateLoginRateLimit,
  parseRateLimitPolicy,
  type RateLimitDecision,
  type RateLimitPolicy,
} from "./rate_limit.ts";
import {
  buildSessionClaims,
  parseSessionTtlMinutes,
  signSessionToken,
  verifySessionToken,
} from "./session.ts";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey, X-Admin-Token",
  // `Retry-After` is not a CORS-safelisted response header, so a browser cannot
  // read it on a 429 unless we expose it explicitly.
  "Access-Control-Expose-Headers": "Retry-After",
} as const;

/** Every route this function serves, used for dispatch and route normalising. */
export const ROUTES = new Set([
  "login",
  "logout",
  "change-password",
  "conversations",
  "messages",
  "reply",
  "close",
]);

/** The single admin account this deployment manages (see ADMIN_AUTH.md). */
const ADMIN_USERNAME = "admin";

/**
 * Shortest accepted replacement password. Mirrored in the admin panel's
 * client-side check and as a backstop inside `update_admin_password()`.
 */
export const MIN_ADMIN_PASSWORD_LENGTH = 8;

/** Refuse absurd inputs before spending a bcrypt comparison on them. */
const MAX_USERNAME_LENGTH = 64;
const MAX_PASSWORD_LENGTH = 200;

/**
 * Normalise the request URL to a route such as "/login".
 *
 * The edge runtime does not guarantee which of these shapes arrives in
 * `req.url`; more than one of them is observed in practice:
 *
 *   /functions/v1/admin-chat/login   (public URL, not what the runtime passes)
 *   /admin-chat/login                (function name kept, /functions/v1 stripped)
 *   /login                           (only the route left)
 *   //login                          (base URL had a trailing slash)
 *   /functions/v1/admin-chat//login  (both of the above)
 *
 * The previous implementation was
 *   url.pathname.replace("/functions/v1/admin-chat", "")
 * which is a silent no-op whenever the runtime passes a path without that
 * literal prefix. Every request then fell through to the admin-token gate and
 * returned 401 {"error":"Unauthorized"} — including POST /login, which is
 * exactly the reported bug and why no login method could ever succeed.
 *
 * Instead: collapse duplicate slashes, then drop leading segments until the
 * first remaining segment is a known route.
 */
export function normalizeRoute(rawUrl: string): string {
  let pathname: string;
  try {
    pathname = new URL(rawUrl).pathname;
  } catch {
    // Not an absolute URL — fall back to whatever looks like a path.
    pathname = rawUrl.split("?")[0] ?? "";
  }
  const segments = pathname
    .replace(/\/{2,}/g, "/")
    .split("/")
    .filter(Boolean);

  while (segments.length > 1 && !ROUTES.has(segments[0])) {
    segments.shift();
  }
  return "/" + segments.join("/");
}

/** An error that should be reported to the caller with a specific status. */
export class HttpError extends Error {
  constructor(public status: number, message: string, public code?: string) {
    super(message);
  }
}

export interface HandlerDeps {
  store: AdminStore;
  /** Reads a function secret; returns undefined when unset. */
  getEnv: (name: string) => string | undefined;
  /** Current time, epoch milliseconds. */
  now: () => number;
  /** Fresh, unguessable session id (uuid in production). */
  newSessionId: () => string;
  log: (level: "info" | "warn" | "error", message: string) => void;
}

function jsonResponse(
  status: number,
  data: unknown,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", ...extraHeaders },
  });
}

/**
 * pgcrypto's crypt() only understands the "$2a$" bcrypt prefix; a "$2b$"/"$2y$"
 * hash (the default output of e.g. Node's bcryptjs) makes crypt() return a
 * non-matching value, so login fails with "Invalid credentials" even though the
 * password is right. For ASCII passwords the three prefixes are equivalent, so
 * remap them. The SQL helper verify_password() does the same thing; this is a
 * defensive copy for deployments where the migration has not been applied yet.
 */
export function normalizeBcryptPrefix(hash: string): string {
  return hash.replace(/^\$2[by]\$/, "$2a$");
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * The HMAC secret behind every session token. Deliberately *required*: the old
 * code silently fell back to a compiled-in token, which is how a default
 * credential ended up guarding a production admin panel.
 */
function sessionSecret(deps: HandlerDeps): string {
  const secret = deps.getEnv("ADMIN_SESSION_SECRET");
  if (!secret) {
    throw new HttpError(
      500,
      "Server misconfigured: the ADMIN_SESSION_SECRET secret is not set for this " +
        "function. Set it with: supabase secrets set ADMIN_SESSION_SECRET=<random 32+ character value>",
    );
  }
  if (secret.length < 32) {
    deps.log(
      "warn",
      "[admin-chat] ADMIN_SESSION_SECRET is shorter than 32 characters; use a longer random value.",
    );
  }
  return secret;
}

/** Session lookup result: a row, no row, or "could not ask the store". */
type SessionLookup =
  | { state: "row"; row: SessionRecord }
  | { state: "none" }
  | { state: "unknown"; detail: string };

/**
 * Look the session row up so a token can be revoked before its `exp`.
 *
 * A missing table/function (migration not applied yet) or a transient error
 * degrades to "unknown", and the caller then trusts the signature + expiry it
 * already verified. That is a deliberate availability trade-off: a signed,
 * unexpired token was issued by this function, and the only thing the row adds
 * is early revocation.
 */
async function loadSession(
  deps: HandlerDeps,
  sessionId: string,
): Promise<SessionLookup> {
  try {
    const row = await deps.store.getSession(sessionId);
    return row ? { state: "row", row } : { state: "none" };
  } catch (error) {
    if (error instanceof HttpError) throw error;
    const detail = error instanceof Error ? error.message : String(error);
    if (isMissingRelationError(error)) {
      deps.log(
        "warn",
        "[admin-chat] admin_sessions is not available; verifying sessions by signature only. " +
          "Apply the admin_sessions migration to enable revocation.",
      );
    } else {
      deps.log("error", `[admin-chat] session lookup failed: ${detail}`);
    }
    return { state: "unknown", detail };
  }
}

interface AuthenticatedRequest {
  ok: true;
  claims: { sid: string; sub: string; exp: number };
}
interface RejectedRequest {
  ok: false;
  response: Response;
}

async function authenticate(
  req: Request,
  body: Record<string, unknown>,
  deps: HandlerDeps,
): Promise<AuthenticatedRequest | RejectedRequest> {
  const headerToken = req.headers.get("X-Admin-Token");
  const supplied = typeof body.token === "string" ? body.token : headerToken;

  const result = await verifySessionToken(supplied, sessionSecret(deps), deps.now());
  if (!result.ok) {
    const expired = result.reason === "expired";
    if (!expired) {
      deps.log("warn", `[admin-chat] rejected admin request: ${result.reason}`);
    }
    return {
      ok: false,
      response: jsonResponse(401, {
        error: expired
          ? "Session expired. Please sign in again."
          : "Invalid session token. Please sign in again.",
        code: expired ? "session_expired" : "invalid_session",
      }),
    };
  }

  const lookup = await loadSession(deps, result.claims.sid);
  if (lookup.state === "none") {
    return {
      ok: false,
      response: jsonResponse(401, {
        error: "Session is no longer valid. Please sign in again.",
        code: "session_revoked",
      }),
    };
  }
  if (lookup.state === "row") {
    const row = lookup.row;
    const expiresAt = Date.parse(row.expires_at);
    if (row.revoked_at) {
      return {
        ok: false,
        response: jsonResponse(401, {
          error: "Session has been revoked. Please sign in again.",
          code: "session_revoked",
        }),
      };
    }
    if (Number.isFinite(expiresAt) && expiresAt <= deps.now()) {
      return {
        ok: false,
        response: jsonResponse(401, {
          error: "Session expired. Please sign in again.",
          code: "session_expired",
        }),
      };
    }
  }
  return { ok: true, claims: result.claims };
}

/** Rate-limit decision for this attempt, failing open if the store is down. */
async function rateLimitDecision(
  deps: HandlerDeps,
  input: { ip: string | null; username: string; policy: RateLimitPolicy; nowMs: number },
): Promise<RateLimitDecision> {
  const { ip, username, policy, nowMs } = input;
  const nowSeconds = Math.floor(nowMs / 1000);
  const empty: RateLimitDecision = {
    blocked: false,
    scope: null,
    retryAfterSeconds: 0,
    ipFailures: 0,
    usernameFailures: 0,
  };

  let snapshot;
  try {
    snapshot = await deps.store.loginFailureSnapshot({
      ip,
      username,
      windowSeconds: policy.windowSeconds,
    });
  } catch (error) {
    if (error instanceof HttpError) throw error;
    const detail = error instanceof Error ? error.message : String(error);
    // Fail open: the limiter is defence in depth, and a database hiccup must
    // not become "the owner cannot log in". The failure is logged loudly.
    deps.log(
      "error",
      `[admin-chat] login rate-limit check unavailable, allowing the attempt: ${detail}`,
    );
    return empty;
  }

  return evaluateLoginRateLimit({ snapshot, policy, nowSeconds });
}

/** Best-effort bookkeeping: never let an audit write break a login. */
async function recordLoginAttempt(
  deps: HandlerDeps,
  attempt: { ip: string | null; username: string; success: boolean },
): Promise<void> {
  try {
    await deps.store.recordLoginAttempt(attempt);
  } catch (error) {
    if (error instanceof HttpError) throw error;
    const detail = error instanceof Error ? error.message : String(error);
    deps.log("warn", `[admin-chat] could not record login attempt: ${detail}`);
  }
}

async function handleLogin(
  req: Request,
  body: Record<string, unknown>,
  deps: HandlerDeps,
): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed" });
  }

  // Read the secret up front: a misconfigured deployment should fail with a
  // named 500 before it spends a login attempt or a bcrypt comparison.
  const secret = sessionSecret(deps);

  const username = typeof body.username === "string" ? body.username.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";

  if (!username || !password) {
    return jsonResponse(400, { error: "Username and password required" });
  }
  if (username.length > MAX_USERNAME_LENGTH || password.length > MAX_PASSWORD_LENGTH) {
    return jsonResponse(400, { error: "Username or password is too long" });
  }

  const ip = clientIpFromHeaders(req.headers);
  if (!ip) {
    deps.log(
      "warn",
      `[admin-chat] no client IP in any of ${CLIENT_IP_HEADERS.join(", ")}; ` +
        "per-IP login limiting is inactive for this attempt.",
    );
  }

  const policy = parseRateLimitPolicy(deps.getEnv);
  const nowMs = deps.now();
  const decision = await rateLimitDecision(deps, { ip, username, policy, nowMs });
  if (decision.blocked) {
    deps.log(
      "warn",
      `[admin-chat] login by "${username}" from ${ip ?? "unknown IP"} blocked by the ` +
        `${decision.scope} rate limit for ${decision.retryAfterSeconds}s ` +
        `(ip failures: ${decision.ipFailures}, username failures: ${decision.usernameFailures})`,
    );
    return jsonResponse(
      429,
      {
        error:
          `Too many failed login attempts. Try again in ${decision.retryAfterSeconds} seconds.`,
        code: "rate_limited",
        scope: decision.scope,
        retryAfterSeconds: decision.retryAfterSeconds,
      },
      { "Retry-After": String(decision.retryAfterSeconds) },
    );
  }

  const admin = await deps.store.findAdminByUsername(username);
  if (!admin) {
    await recordLoginAttempt(deps, { ip, username, success: false });
    deps.log("warn", `[admin-chat] login failed: no admin_users row for "${username}"`);
    return jsonResponse(401, { error: "Invalid credentials" });
  }

  const passwordMatches = await deps.store.verifyPassword(
    normalizeBcryptPrefix(admin.password_hash),
    password,
  );
  if (!passwordMatches) {
    await recordLoginAttempt(deps, { ip, username, success: false });
    deps.log("warn", `[admin-chat] login failed: password mismatch for "${username}"`);
    return jsonResponse(401, { error: "Invalid credentials" });
  }

  const ttlMinutes = parseSessionTtlMinutes(deps.getEnv("ADMIN_SESSION_TTL_MINUTES"));
  const sessionId = deps.newSessionId();
  const claims = buildSessionClaims({
    sessionId,
    username: admin.username,
    nowMs,
    ttlMinutes,
  });
  const token = await signSessionToken(claims, secret);

  try {
    await deps.store.createSession({
      id: sessionId,
      username: admin.username,
      issuedAt: new Date(claims.iat * 1000).toISOString(),
      expiresAt: new Date(claims.exp * 1000).toISOString(),
      ip,
      userAgent: req.headers.get("user-agent"),
    });
  } catch (error) {
    if (error instanceof HttpError) throw error;
    const detail = error instanceof Error ? error.message : String(error);
    if (isMissingRelationError(error)) {
      deps.log(
        "warn",
        "[admin-chat] admin_sessions is not available; issuing a token that cannot be " +
          "revoked early. Apply the admin_sessions migration.",
      );
    } else {
      // The token is signed and the signature is what authenticates it, so
      // losing the bookkeeping row must not block the owner's login.
      deps.log("error", `[admin-chat] could not persist the session row: ${detail}`);
    }
  }

  await recordLoginAttempt(deps, { ip, username, success: true });

  const session = {
    token,
    username: admin.username,
    expiresAt: new Date(claims.exp * 1000).toISOString(),
    expiresInSeconds: claims.exp - claims.iat,
  };
  return jsonResponse(200, session);
}

/**
 * Idempotent: a caller whose token has already expired (or who has already
 * logged out) still gets 200. The client clears its own storage regardless.
 */
async function handleLogout(
  req: Request,
  body: Record<string, unknown>,
  deps: HandlerDeps,
): Promise<Response> {
  if (req.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed" });
  }

  const supplied =
    typeof body.token === "string" ? body.token : req.headers.get("X-Admin-Token");
  const secret = sessionSecret(deps);
  const result = await verifySessionToken(supplied, secret, deps.now());

  if (result.ok) {
    try {
      await deps.store.revokeSession(result.claims.sid);
    } catch (error) {
      if (error instanceof HttpError) throw error;
      const detail = error instanceof Error ? error.message : String(error);
      deps.log("warn", `[admin-chat] could not revoke session ${result.claims.sid}: ${detail}`);
    }
  }

  return jsonResponse(200, { success: true });
}

async function handleChangePassword(
  body: Record<string, unknown>,
  deps: HandlerDeps,
  sessionId: string,
): Promise<Response> {
  const { currentPassword, newPassword } = body;

  if (typeof currentPassword !== "string" || typeof newPassword !== "string" ||
    !currentPassword || !newPassword) {
    return jsonResponse(400, { error: "Current and new password required" });
  }
  if (newPassword.length < MIN_ADMIN_PASSWORD_LENGTH) {
    return jsonResponse(400, {
      error: `New password must be at least ${MIN_ADMIN_PASSWORD_LENGTH} characters`,
    });
  }
  if (newPassword === currentPassword) {
    return jsonResponse(400, { error: "New password must differ from the current one" });
  }

  const admin = await deps.store.findAdminByUsername(ADMIN_USERNAME);
  if (!admin) {
    return jsonResponse(500, { error: "Admin user not found" });
  }

  const currentMatches = await deps.store.verifyPassword(
    normalizeBcryptPrefix(admin.password_hash),
    currentPassword,
  );
  if (!currentMatches) {
    deps.log("warn", "[admin-chat] change-password rejected: current password is incorrect");
    return jsonResponse(401, { error: "Current password is incorrect" });
  }

  await deps.store.updateAdminPassword(newPassword);

  // The password just changed, so every other session was authorised by
  // credentials that no longer exist. Keep this one, drop the rest.
  let revoked = 0;
  try {
    revoked = await deps.store.revokeSessionsExcept(ADMIN_USERNAME, sessionId);
  } catch (error) {
    if (error instanceof HttpError) throw error;
    const detail = error instanceof Error ? error.message : String(error);
    deps.log("warn", `[admin-chat] could not revoke other sessions: ${detail}`);
  }

  deps.log(
    "info",
    `[admin-chat] admin password changed; revoked ${revoked} other session(s)`,
  );
  return jsonResponse(200, { success: true, otherSessionsRevoked: revoked });
}

export function createHandler(deps: HandlerDeps) {
  return async function handle(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 200, headers: corsHeaders });
    }

    try {
      const route = normalizeRoute(req.url);
      let body: Record<string, unknown> = {};
      try {
        const parsed = await req.json();
        if (isPlainObject(parsed)) body = parsed;
      } catch {
        // No/invalid JSON body: keep {} so header-only auth still works.
      }

      // --- LOGIN ---
      // Deliberately before the auth gate: this route is how a session token is
      // obtained. It must not depend on any existing token or header.
      if (route === "/login") {
        return await handleLogin(req, body, deps);
      }

      // --- UNKNOWN ROUTE ---
      // Report this as a 404 naming the path we resolved, instead of falling
      // through to the auth gate and masquerading as an auth failure.
      if (!ROUTES.has(route.replace(/^\//, ""))) {
        deps.log(
          "warn",
          `[admin-chat] unrouted request: ${req.method} ${route} (from ${req.url})`,
        );
        return jsonResponse(404, { error: "Not found", path: route });
      }

      // --- LOGOUT ---
      // Idempotent, and therefore reachable without a currently valid token.
      if (route === "/logout") {
        return await handleLogout(req, body, deps);
      }

      // --- AUTH CHECK for all other routes ---
      const auth = await authenticate(req, body, deps);
      if (!auth.ok) {
        return auth.response;
      }

      if (route === "/change-password") {
        if (req.method !== "POST") {
          return jsonResponse(405, { error: "Method not allowed" });
        }
        return await handleChangePassword(body, deps, auth.claims.sid);
      }

      if (route === "/conversations") {
        if (req.method !== "POST") {
          return jsonResponse(405, { error: "Method not allowed" });
        }
        const conversations: ConversationRecord[] = await deps.store.listConversations();
        return jsonResponse(200, { conversations });
      }

      if (route === "/messages") {
        if (req.method !== "POST") {
          return jsonResponse(405, { error: "Method not allowed" });
        }
        const { conversationId } = body;
        if (typeof conversationId !== "string" || !conversationId) {
          return jsonResponse(400, { error: "Conversation ID required" });
        }
        const messages: MessageRecord[] = await deps.store.listMessages(conversationId);
        return jsonResponse(200, { messages });
      }

      if (route === "/reply") {
        if (req.method !== "POST") {
          return jsonResponse(405, { error: "Method not allowed" });
        }
        const { conversationId, content } = body;
        if (typeof conversationId !== "string" || !conversationId ||
          typeof content !== "string" || !content) {
          return jsonResponse(400, { error: "Conversation ID and content required" });
        }
        await deps.store.insertAgentMessage(conversationId, content);
        await deps.store.touchConversation(conversationId);
        return jsonResponse(200, { success: true });
      }

      if (route === "/close") {
        if (req.method !== "POST") {
          return jsonResponse(405, { error: "Method not allowed" });
        }
        const { conversationId } = body;
        if (typeof conversationId !== "string" || !conversationId) {
          return jsonResponse(400, { error: "Conversation ID required" });
        }
        await deps.store.closeConversation(conversationId);
        return jsonResponse(200, { success: true });
      }

      // Known route, wrong method.
      return jsonResponse(405, { error: "Method not allowed" });
    } catch (err) {
      if (err instanceof HttpError) {
        deps.log("error", `[admin-chat] ${err.message}`);
        return jsonResponse(err.status, {
          error: err.message,
          ...(err.code ? { code: err.code } : {}),
        });
      }
      const message = err instanceof Error ? err.message : String(err);
      deps.log("error", `[admin-chat] unhandled error: ${message}`);
      return jsonResponse(500, { error: message });
    }
  };
}
