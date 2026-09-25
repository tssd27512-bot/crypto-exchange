/**
 * Per-session admin tokens.
 *
 * Replaces the single static shared `ADMIN_CHAT_TOKEN` that used to be both the
 * gate on every protected route and the value returned by `/login`. That value
 * never expired, was identical for every caller, and granted full admin access
 * to anyone who had ever seen it (including every previous visitor of the admin
 * panel, and anyone able to read it in transit).
 *
 * Requirements this module satisfies:
 *   - one fresh token per successful login ("per-session"),
 *   - carries an explicit expiry and is rejected after it,
 *   - unforgeable without the server secret (HMAC-SHA256),
 *   - the server can revoke it before expiry (see `sid` + the `admin_sessions`
 *     table; revocation is enforced by the handler, not here).
 *
 * Token format:  v1.<base64url(json claims)>.<base64url(HMAC-SHA256 signature)>
 * The signature covers `v1.<base64url(json claims)>` — i.e. everything except
 * the signature itself — so neither the claims nor the version tag can be
 * altered without invalidating it.
 *
 * No Deno-specific APIs are used (WebCrypto + btoa/atob only), so the module is
 * runnable under Deno (production), Bun and Node — which is what makes it
 * unit-testable outside Supabase. See tests/session.test.ts.
 */

/** Bumped only if the token wire format changes (the prefix is signed). */
export const SESSION_TOKEN_VERSION = 1;

/** 12 hours. Overridable per deployment with ADMIN_SESSION_TTL_MINUTES. */
export const DEFAULT_SESSION_TTL_MINUTES = 720;
/** Refuse to issue a session shorter than 5 minutes or longer than 7 days. */
export const MIN_SESSION_TTL_MINUTES = 5;
export const MAX_SESSION_TTL_MINUTES = 10080;

export interface SessionClaims {
  /** Token format version. */
  v: number;
  /** Session id: also the primary key of the `admin_sessions` row. */
  sid: string;
  /** Subject: the admin username the session belongs to. */
  sub: string;
  /** Issued at, unix seconds. */
  iat: number;
  /** Expires at, unix seconds. */
  exp: number;
}

export type SessionFailureReason =
  | "malformed"
  | "unsupported_version"
  | "bad_signature"
  | "expired";

export type SessionVerifyResult =
  | { ok: true; claims: SessionClaims }
  | { ok: false; reason: SessionFailureReason };

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Throws on invalid base64url input; callers turn that into "malformed". */
function base64UrlToBytes(value: string): Uint8Array {
  const padded =
    value.replace(/-/g, "+").replace(/_/g, "/") +
    "=".repeat((4 - (value.length % 4)) % 4);
  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function tokenPrefix(): string {
  return `v${SESSION_TOKEN_VERSION}`;
}

function signingInput(payloadSegment: string): string {
  return `${tokenPrefix()}.${payloadSegment}`;
}

async function importHmacKey(
  secret: string,
  usage: KeyUsage[],
): Promise<CryptoKey> {
  if (!secret) {
    throw new Error("session secret must not be empty");
  }
  return await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    usage,
  );
}

/**
 * Clamp ADMIN_SESSION_TTL_MINUTES to a sane range. A missing, blank or
 * non-numeric value falls back to the 12-hour default.
 */
export function parseSessionTtlMinutes(raw: string | undefined | null): number {
  const parsed = Number.parseInt(String(raw ?? "").trim(), 10);
  if (!Number.isFinite(parsed)) {
    return DEFAULT_SESSION_TTL_MINUTES;
  }
  return Math.min(MAX_SESSION_TTL_MINUTES, Math.max(MIN_SESSION_TTL_MINUTES, parsed));
}

export function buildSessionClaims(options: {
  sessionId: string;
  username: string;
  nowMs: number;
  ttlMinutes: number;
}): SessionClaims {
  const iat = Math.floor(options.nowMs / 1000);
  return {
    v: SESSION_TOKEN_VERSION,
    sid: options.sessionId,
    sub: options.username,
    iat,
    exp: iat + options.ttlMinutes * 60,
  };
}

/** Sign a fresh session token. Async because WebCrypto is. */
export async function signSessionToken(
  claims: SessionClaims,
  secret: string,
): Promise<string> {
  const payloadSegment = bytesToBase64Url(
    encoder.encode(JSON.stringify(claims)),
  );
  const input = signingInput(payloadSegment);
  const key = await importHmacKey(secret, ["sign"]);
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, encoder.encode(input)),
  );
  return `${input}.${bytesToBase64Url(signature)}`;
}

function isSessionClaims(value: unknown): value is SessionClaims {
  if (typeof value !== "object" || value === null) return false;
  const c = value as Record<string, unknown>;
  return (
    typeof c.sid === "string" &&
    c.sid.length > 0 &&
    typeof c.sub === "string" &&
    c.sub.length > 0 &&
    typeof c.iat === "number" &&
    Number.isFinite(c.iat) &&
    typeof c.exp === "number" &&
    Number.isFinite(c.exp)
  );
}

/**
 * Verify a session token: signature first, then expiry.
 *
 * Signature checking happens before the claims are parsed, and the comparison
 * is `crypto.subtle.verify`, which is constant-time — a hand-rolled string
 * comparison would leak the expected signature one byte at a time.
 */
export async function verifySessionToken(
  token: string | null | undefined,
  secret: string,
  nowMs: number,
): Promise<SessionVerifyResult> {
  if (typeof token !== "string" || token.length === 0) {
    return { ok: false, reason: "malformed" };
  }

  const segments = token.split(".");
  if (segments.length !== 3) {
    return { ok: false, reason: "malformed" };
  }
  const [prefix, payloadSegment, signatureSegment] = segments;
  if (prefix !== tokenPrefix()) {
    return { ok: false, reason: "unsupported_version" };
  }
  if (
    !/^[A-Za-z0-9_-]+$/.test(payloadSegment) ||
    !/^[A-Za-z0-9_-]+$/.test(signatureSegment)
  ) {
    return { ok: false, reason: "malformed" };
  }

  let signatureBytes: Uint8Array;
  try {
    signatureBytes = base64UrlToBytes(signatureSegment);
  } catch {
    return { ok: false, reason: "malformed" };
  }

  let signatureValid = false;
  try {
    const key = await importHmacKey(secret, ["verify"]);
    signatureValid = await crypto.subtle.verify(
      "HMAC",
      key,
      signatureBytes,
      encoder.encode(signingInput(payloadSegment)),
    );
  } catch {
    // A wrong signature length makes some runtimes throw instead of returning
    // false. Either way the token is not trustworthy.
    return { ok: false, reason: "malformed" };
  }
  if (!signatureValid) {
    return { ok: false, reason: "bad_signature" };
  }

  let payload: unknown;
  try {
    payload = JSON.parse(decoder.decode(base64UrlToBytes(payloadSegment)));
  } catch {
    return { ok: false, reason: "malformed" };
  }
  if (
    typeof payload !== "object" ||
    payload === null ||
    (payload as Record<string, unknown>).v !== SESSION_TOKEN_VERSION
  ) {
    return { ok: false, reason: "unsupported_version" };
  }
  if (!isSessionClaims(payload)) {
    return { ok: false, reason: "malformed" };
  }

  const nowSeconds = Math.floor(nowMs / 1000);
  if (nowSeconds >= payload.exp) {
    return { ok: false, reason: "expired" };
  }

  return { ok: true, claims: payload };
}
