import { describe, expect, test } from "bun:test";
import {
  buildSessionClaims,
  DEFAULT_SESSION_TTL_MINUTES,
  MAX_SESSION_TTL_MINUTES,
  MIN_SESSION_TTL_MINUTES,
  parseSessionTtlMinutes,
  SESSION_TOKEN_VERSION,
  signSessionToken,
  verifySessionToken,
} from "../session.ts";

const SECRET = "test-secret-that-is-at-least-32-characters-long";
const NOW_MS = 1_760_000_000_000; // fixed clock: 2025-10-09T08:53:20Z
const NOW_S = Math.floor(NOW_MS / 1000);

function freshClaims(overrides: Partial<Parameters<typeof signSessionToken>[0]> = {}) {
  return {
    ...buildSessionClaims({
      sessionId: "11111111-1111-4111-8111-111111111111",
      username: "admin",
      nowMs: NOW_MS,
      ttlMinutes: DEFAULT_SESSION_TTL_MINUTES,
    }),
    ...overrides,
  };
}

describe("buildSessionClaims", () => {
  test("derives iat from the clock and exp from the TTL", () => {
    const claims = buildSessionClaims({
      sessionId: "sid",
      username: "admin",
      nowMs: NOW_MS,
      ttlMinutes: 60,
    });
    expect(claims.v).toBe(SESSION_TOKEN_VERSION);
    expect(claims.sid).toBe("sid");
    expect(claims.sub).toBe("admin");
    expect(claims.iat).toBe(NOW_S);
    expect(claims.exp).toBe(NOW_S + 3600);
  });
});

describe("parseSessionTtlMinutes", () => {
  test("defaults when unset, blank or nonsense", () => {
    expect(parseSessionTtlMinutes(undefined)).toBe(DEFAULT_SESSION_TTL_MINUTES);
    expect(parseSessionTtlMinutes(null)).toBe(DEFAULT_SESSION_TTL_MINUTES);
    expect(parseSessionTtlMinutes("")).toBe(DEFAULT_SESSION_TTL_MINUTES);
    expect(parseSessionTtlMinutes("not-a-number")).toBe(DEFAULT_SESSION_TTL_MINUTES);
  });

  test("clamps to the sane range", () => {
    expect(parseSessionTtlMinutes("60")).toBe(60);
    expect(parseSessionTtlMinutes("1")).toBe(MIN_SESSION_TTL_MINUTES);
    expect(parseSessionTtlMinutes("-4000")).toBe(MIN_SESSION_TTL_MINUTES);
    expect(parseSessionTtlMinutes("999999")).toBe(MAX_SESSION_TTL_MINUTES);
  });

  test("truncates a numeric prefix, as parseInt does", () => {
    expect(parseSessionTtlMinutes("45.9")).toBe(45);
  });
});

describe("signSessionToken / verifySessionToken", () => {
  test("a freshly issued token verifies and carries its claims", async () => {
    const token = await signSessionToken(freshClaims(), SECRET);
    const result = await verifySessionToken(token, SECRET, NOW_MS);
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.claims.sub).toBe("admin");
      expect(result.claims.exp).toBe(NOW_S + DEFAULT_SESSION_TTL_MINUTES * 60);
    }
  });

  test("token shape is v1.<payload>.<signature>", async () => {
    const token = await signSessionToken(freshClaims(), SECRET);
    const segments = token.split(".");
    expect(segments).toHaveLength(3);
    expect(segments[0]).toBe("v1");
    expect(segments[1]).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(segments[2]).toMatch(/^[A-Za-z0-9_-]+$/);
    // The old static token was a single opaque string with no expiry at all.
    expect(token).not.toBe("Samistrongkey2026");
  });

  test("two logins produce different tokens (per-session, not shared)", async () => {
    const a = await signSessionToken(freshClaims({ sid: "session-a" }), SECRET);
    const b = await signSessionToken(freshClaims({ sid: "session-b" }), SECRET);
    expect(a).not.toBe(b);
  });

  test("is still valid one second before exp and dead at exp", async () => {
    const claims = freshClaims({ exp: NOW_S + 10, iat: NOW_S });
    const token = await signSessionToken(claims, SECRET);

    const before = await verifySessionToken(token, SECRET, (NOW_S + 9) * 1000);
    expect(before.ok).toBe(true);

    const exactly = await verifySessionToken(token, SECRET, (NOW_S + 10) * 1000);
    expect(exactly).toEqual({ ok: false, reason: "expired" });

    const after = await verifySessionToken(token, SECRET, (NOW_S + 11) * 1000);
    expect(after).toEqual({ ok: false, reason: "expired" });
  });

  test("an already expired token is refused", async () => {
    const token = await signSessionToken(
      buildSessionClaims({ sessionId: "s", username: "admin", nowMs: NOW_MS, ttlMinutes: -1 }),
      SECRET,
    );
    expect(await verifySessionToken(token, SECRET, NOW_MS)).toEqual({
      ok: false,
      reason: "expired",
    });
  });

  test("rejects a token signed with a different secret", async () => {
    const token = await signSessionToken(freshClaims(), "some-other-secret-value-1234567890");
    expect(await verifySessionToken(token, SECRET, NOW_MS)).toEqual({
      ok: false,
      reason: "bad_signature",
    });
  });

  test("rejects a tampered payload (privilege escalation attempt)", async () => {
    const token = await signSessionToken(freshClaims({ sub: "admin" }), SECRET);
    const [prefix, payload, signature] = token.split(".");
    // Re-encode the payload with a longer lifetime / different subject.
    const forgedPayload = btoa(
      JSON.stringify({ ...freshClaims(), sub: "attacker", exp: NOW_S + 10 ** 6 }),
    )
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    const forged = `${prefix}.${forgedPayload}.${signature}`;
    expect(forged).not.toBe(token);
    expect(await verifySessionToken(forged, SECRET, NOW_MS)).toEqual({
      ok: false,
      reason: "bad_signature",
    });
    expect(payload).not.toBe(forgedPayload);
  });

  test("rejects a tampered signature", async () => {
    const token = await signSessionToken(freshClaims(), SECRET);
    const [prefix, payload, signature] = token.split(".");
    const flipped = (signature[0] === "A" ? "B" : "A") + signature.slice(1);
    expect(await verifySessionToken(`${prefix}.${payload}.${flipped}`, SECRET, NOW_MS)).toEqual({
      ok: false,
      reason: "bad_signature",
    });
  });

  test("rejects an unknown token version prefix", async () => {
    const token = await signSessionToken(freshClaims(), SECRET);
    const swapped = token.replace(/^v1\./, "v2.");
    expect(await verifySessionToken(swapped, SECRET, NOW_MS)).toEqual({
      ok: false,
      reason: "unsupported_version",
    });
  });

  test("rejects malformed input without throwing", async () => {
    for (const bad of [
      null,
      undefined,
      "",
      "not-a-token",
      "v1.only-two-parts",
      "v1..",
      "v1.!!!!.!!!!",
      "v1.a.b.c",
      `${"v1."}${"A".repeat(50)}.${"B".repeat(50)}`,
    ]) {
      const result = await verifySessionToken(bad as string, SECRET, NOW_MS);
      expect(result.ok).toBe(false);
      if (!result.ok) {
        expect(["malformed", "unsupported_version", "bad_signature"]).toContain(result.reason);
      }
    }
  });

  test("the old static token value is not accepted", async () => {
    const result = await verifySessionToken("Samistrongkey2026", SECRET, NOW_MS);
    expect(result.ok).toBe(false);
  });

  test("refuses an empty secret rather than signing with one", async () => {
    await expect(signSessionToken(freshClaims(), "")).rejects.toThrow();
  });
});
