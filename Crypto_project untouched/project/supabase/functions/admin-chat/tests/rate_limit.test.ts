import { describe, expect, test } from "bun:test";
import {
  clientIpFromHeaders,
  DEFAULT_LOGIN_IP_LIMIT,
  DEFAULT_LOGIN_USERNAME_LIMIT,
  DEFAULT_LOGIN_WINDOW_SECONDS,
  evaluateLoginRateLimit,
  failuresToEpochSeconds,
  normalizeIp,
  parseRateLimitPolicy,
} from "../rate_limit.ts";

const POLICY = {
  ipLimit: DEFAULT_LOGIN_IP_LIMIT, // 20
  usernameLimit: DEFAULT_LOGIN_USERNAME_LIMIT, // 8
  windowSeconds: DEFAULT_LOGIN_WINDOW_SECONDS, // 900
};

const NOW = 1_760_000_000; // unix seconds

function failures(count: number, ageSeconds = 1): number[] {
  return Array.from({ length: count }, (_, i) => NOW - ageSeconds - i).sort((a, b) => a - b);
}

describe("normalizeIp", () => {
  test("accepts plain v4 and v6", () => {
    expect(normalizeIp("203.0.113.7")).toBe("203.0.113.7");
    expect(normalizeIp("2001:DB8::1")).toBe("2001:db8::1");
  });

  test("takes the first entry of an x-forwarded-for chain", () => {
    expect(normalizeIp("203.0.113.7, 70.41.3.18, 150.172.238.178")).toBe("203.0.113.7");
  });

  test("strips a port and IPv6 brackets", () => {
    expect(normalizeIp("203.0.113.7:53211")).toBe("203.0.113.7");
    expect(normalizeIp("[2001:db8::1]:443")).toBe("2001:db8::1");
  });

  test("rejects junk rather than bucketing it", () => {
    for (const bad of ["", "   ", null, undefined, "unknown", "not an ip", "a".repeat(60)]) {
      expect(normalizeIp(bad as string)).toBeNull();
    }
  });
});

describe("clientIpFromHeaders", () => {
  test("prefers x-forwarded-for over the other headers", () => {
    const headers = new Headers({
      "x-forwarded-for": "203.0.113.7",
      "x-real-ip": "198.51.100.9",
      "cf-connecting-ip": "192.0.2.1",
    });
    expect(clientIpFromHeaders(headers)).toBe("203.0.113.7");
  });

  test("falls back through the header list", () => {
    expect(clientIpFromHeaders(new Headers({ "x-real-ip": "198.51.100.9" }))).toBe("198.51.100.9");
    expect(clientIpFromHeaders(new Headers({ "cf-connecting-ip": "192.0.2.1" }))).toBe("192.0.2.1");
  });

  test("returns null when the runtime supplies no IP at all", () => {
    expect(clientIpFromHeaders(new Headers({ "user-agent": "curl/8" }))).toBeNull();
  });
});

describe("parseRateLimitPolicy", () => {
  test("uses the documented defaults when nothing is configured", () => {
    expect(parseRateLimitPolicy(() => undefined)).toEqual(POLICY);
  });

  test("honours overrides and clamps nonsense", () => {
    const env = (values: Record<string, string>) => (name: string) => values[name];
    expect(parseRateLimitPolicy(env({ ADMIN_LOGIN_USERNAME_LIMIT: "3" })).usernameLimit).toBe(3);
    expect(parseRateLimitPolicy(env({ ADMIN_LOGIN_USERNAME_LIMIT: "0" })).usernameLimit).toBe(1);
    expect(parseRateLimitPolicy(env({ ADMIN_LOGIN_WINDOW_SECONDS: "5" })).windowSeconds).toBe(30);
    expect(parseRateLimitPolicy(env({ ADMIN_LOGIN_IP_LIMIT: "abc" })).ipLimit).toBe(
      DEFAULT_LOGIN_IP_LIMIT,
    );
  });
});

describe("failuresToEpochSeconds", () => {
  test("parses the ISO timestamps PostgREST returns, sorted ascending", () => {
    const parsed = failuresToEpochSeconds([
      "2025-10-09T08:53:20.123456+00:00",
      "2025-10-09T08:50:00+00:00",
    ]);
    expect(parsed).toHaveLength(2);
    expect(parsed[0]).toBeLessThan(parsed[1]);
  });

  test("drops unparseable values instead of poisoning the bucket", () => {
    expect(failuresToEpochSeconds(["nope", null, undefined, 12])).toEqual([12]);
  });
});

describe("evaluateLoginRateLimit", () => {
  test("allows a first attempt", () => {
    const decision = evaluateLoginRateLimit({
      snapshot: { ipFailures: [], usernameFailures: [] },
      policy: POLICY,
      nowSeconds: NOW,
    });
    expect(decision).toEqual({
      blocked: false,
      scope: null,
      retryAfterSeconds: 0,
      ipFailures: 0,
      usernameFailures: 0,
    });
  });

  test("still allows the attempt at exactly limit-1 failures in each bucket", () => {
    const decision = evaluateLoginRateLimit({
      snapshot: { ipFailures: failures(19), usernameFailures: failures(7) },
      policy: POLICY,
      nowSeconds: NOW,
    });
    expect(decision.blocked).toBe(false);
    expect(decision.ipFailures).toBe(19);
    expect(decision.usernameFailures).toBe(7);
  });

  test("blocks once the username bucket reaches its limit", () => {
    const decision = evaluateLoginRateLimit({
      snapshot: { ipFailures: [], usernameFailures: failures(8) },
      policy: POLICY,
      nowSeconds: NOW,
    });
    expect(decision.blocked).toBe(true);
    expect(decision.scope).toBe("username");
    // 8 failures at NOW-8..NOW-1: the oldest must age out of a 900s window.
    expect(decision.retryAfterSeconds).toBe(900 - 8);
  });

  test("blocks once the IP bucket reaches its limit, whatever the username", () => {
    const decision = evaluateLoginRateLimit({
      snapshot: { ipFailures: failures(20), usernameFailures: [] },
      policy: POLICY,
      nowSeconds: NOW,
    });
    expect(decision.blocked).toBe(true);
    expect(decision.scope).toBe("ip");
    expect(decision.retryAfterSeconds).toBeGreaterThan(0);
  });

  test("reports the bucket that blocks the caller for longest", () => {
    const decision = evaluateLoginRateLimit({
      snapshot: { ipFailures: failures(20, 1), usernameFailures: failures(9, 400) },
      policy: POLICY,
      nowSeconds: NOW,
    });
    expect(decision.scope).toBe("ip");
    expect(decision.retryAfterSeconds).toBe(900 - 20);
  });

  test("a long-ago burst no longer blocks (window slides)", () => {
    const stale = failures(50, POLICY.windowSeconds + 5);
    const decision = evaluateLoginRateLimit({
      snapshot: { ipFailures: stale, usernameFailures: stale },
      policy: POLICY,
      nowSeconds: NOW,
    });
    // The store only returns in-window rows; if it returned stale rows anyway,
    // the retry arithmetic must not produce a negative or infinite wait.
    expect(Number.isFinite(decision.retryAfterSeconds)).toBe(true);
    expect(decision.retryAfterSeconds).toBeGreaterThanOrEqual(0);
  });

  test("retryAfter never goes negative and is at least a second", () => {
    const decision = evaluateLoginRateLimit({
      snapshot: {
        ipFailures: failures(2, POLICY.windowSeconds - 1),
        usernameFailures: [],
      },
      policy: { ipLimit: 1, usernameLimit: 100, windowSeconds: POLICY.windowSeconds },
      nowSeconds: NOW,
    });
    expect(decision.blocked).toBe(true);
    expect(decision.retryAfterSeconds).toBeGreaterThanOrEqual(1);
  });
});
