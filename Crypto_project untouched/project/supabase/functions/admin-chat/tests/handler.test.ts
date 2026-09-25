import { beforeEach, describe, expect, test } from "bun:test";
import {
  MissingRelationError,
  type AdminRecord,
  type AdminStore,
  type ConversationRecord,
  type LoginFailureSnapshot,
  type MessageRecord,
  type NewSessionRecord,
  type SessionRecord,
} from "../admin_store.ts";
import { createHandler, normalizeRoute } from "../handler.ts";
import { signSessionToken, verifySessionToken } from "../session.ts";

const SECRET = "unit-test-session-secret-0123456789abcdef";
const ADMIN_PASSWORD = "admin123";
const ENDPOINT = "https://project.supabase.co/functions/v1/admin-chat";

/**
 * In-memory AdminStore. Everything the handler touches goes through here, so
 * these tests exercise the real request pipeline (routing, gate, login, rate
 * limiting, session lifecycle) without a database or credentials.
 */
class FakeStore implements AdminStore {
  admins: AdminRecord[] = [
    { id: "a1", username: "admin", password_hash: `bcrypt:${ADMIN_PASSWORD}` },
  ];
  sessions = new Map<string, SessionRecord>();
  attempts: { ip: string | null; username: string | null; success: boolean; atSeconds: number }[] = [];
  conversations: ConversationRecord[] = [
    { id: "c1", visitor_id: "v1", visitor_name: "Guest", status: "open" },
  ];
  messages: MessageRecord[] = [{ id: "m1", conversation_id: "c1", sender: "visitor", content: "hi" }];

  /** Simulated failures. */
  snapshotError: Error | null = null;
  recordAttemptError: Error | null = null;
  sessionsTableMissing = false;

  now: () => number = () => Date.now();

  private guardSessions(): void {
    if (this.sessionsTableMissing) {
      throw new MissingRelationError('relation "public.admin_sessions" does not exist');
    }
  }

  async findAdminByUsername(username: string) {
    return this.admins.find((a) => a.username === username) ?? null;
  }

  async verifyPassword(hash: string, plain: string) {
    return hash === `bcrypt:${plain}`;
  }

  async updateAdminPassword(newPlain: string) {
    this.admins = this.admins.map((a) =>
      a.username === "admin" ? { ...a, password_hash: `bcrypt:${newPlain}` } : a
    );
  }

  async createSession(session: NewSessionRecord) {
    this.guardSessions();
    this.sessions.set(session.id, {
      id: session.id,
      username: session.username,
      issued_at: session.issuedAt,
      expires_at: session.expiresAt,
      revoked_at: null,
    });
  }

  async getSession(id: string) {
    this.guardSessions();
    return this.sessions.get(id) ?? null;
  }

  async revokeSession(id: string) {
    this.guardSessions();
    const row = this.sessions.get(id);
    if (row) row.revoked_at = new Date(this.now()).toISOString();
  }

  async revokeSessionsExcept(username: string, keepSessionId: string | null) {
    this.guardSessions();
    let count = 0;
    for (const row of this.sessions.values()) {
      if (row.username === username && row.id !== keepSessionId && !row.revoked_at) {
        row.revoked_at = new Date(this.now()).toISOString();
        count++;
      }
    }
    return count;
  }

  async loginFailureSnapshot(input: {
    ip: string | null;
    username: string | null;
    windowSeconds: number;
  }): Promise<LoginFailureSnapshot> {
    if (this.snapshotError) throw this.snapshotError;
    const nowSeconds = Math.floor(this.now() / 1000);
    const inWindow = this.attempts.filter(
      (a) => !a.success && a.atSeconds > nowSeconds - input.windowSeconds,
    );
    return {
      ipFailures: input.ip
        ? inWindow.filter((a) => a.ip === input.ip).map((a) => a.atSeconds).sort((x, y) => x - y)
        : [],
      usernameFailures: input.username
        ? inWindow
          .filter((a) => a.username?.toLowerCase() === input.username!.toLowerCase())
          .map((a) => a.atSeconds)
          .sort((x, y) => x - y)
        : [],
    };
  }

  async recordLoginAttempt(attempt: { ip: string | null; username: string | null; success: boolean }) {
    if (this.recordAttemptError) throw this.recordAttemptError;
    this.attempts.push({ ...attempt, atSeconds: Math.floor(this.now() / 1000) });
  }

  async listConversations() {
    return this.conversations;
  }

  async listMessages(conversationId: string) {
    return this.messages.filter((m) => m.conversation_id === conversationId);
  }

  async insertAgentMessage(conversationId: string, content: string) {
    this.messages = [
      ...this.messages,
      { id: `m${this.messages.length + 1}`, conversation_id: conversationId, sender: "agent", content },
    ];
  }

  async touchConversation(conversationId: string) {
    this.conversations = this.conversations.map((c) =>
      c.id === conversationId ? { ...c, updated_at: new Date(this.now()).toISOString() } : c
    );
  }

  async closeConversation(conversationId: string) {
    this.conversations = this.conversations.map((c) =>
      c.id === conversationId ? { ...c, status: "closed" } : c
    );
  }
}

let store: FakeStore;
let logs: string[];
let clock: number;

function buildHandler(env: Record<string, string | undefined> = {}) {
  const values = { ADMIN_SESSION_SECRET: SECRET, ...env };
  return createHandler({
    store,
    getEnv: (name) => values[name],
    now: () => clock,
    newSessionId: (() => {
      let n = 0;
      return () => `session-${++n}`;
    })(),
    log: (level, message) => logs.push(`${level}: ${message}`),
  });
}

function post(
  handler: (req: Request) => Promise<Response>,
  path: string,
  body: unknown,
  headers: Record<string, string> = {},
) {
  return handler(
    new Request(`${ENDPOINT}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-forwarded-for": "203.0.113.7", ...headers },
      body: JSON.stringify(body),
    }),
  );
}

/** Log in and return the session token. */
async function login(handler: (req: Request) => Promise<Response>) {
  const res = await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD });
  expect(res.status).toBe(200);
  const body = await res.json() as { token: string; username: string; expiresAt: string };
  return body;
}

beforeEach(() => {
  store = new FakeStore();
  store.now = () => clock;
  logs = [];
  clock = Date.UTC(2025, 9, 9, 8, 53, 20); // fixed clock: 2025-10-09T08:53:20Z
});

describe("normalizeRoute", () => {
  test("resolves every path shape the runtime has been observed to send", () => {
    const cases: Record<string, string> = {
      "/functions/v1/admin-chat/login": "/login",
      "/admin-chat/login": "/login",
      "/login": "/login",
      "//login": "/login",
      "/functions/v1/admin-chat//login": "/login",
      "/login/": "/login",
      "/functions/v1/admin-chat/conversations": "/conversations",
      "/admin-chat/messages": "/messages",
      "https://project.supabase.co/functions/v1/admin-chat/login?x=1": "/login",
    };
    for (const [raw, expected] of Object.entries(cases)) {
      expect(normalizeRoute(raw)).toBe(expected);
    }
  });

  test("keeps an unknown path so it can be reported as a 404", () => {
    expect(normalizeRoute(`${ENDPOINT}/zzz`)).toBe("/zzz");
    // Prefix stripping stops at the first known route; with no known route in
    // the path only the last segment survives. The 404 log line carries the
    // full raw URL, so nothing is lost for diagnosis.
    expect(normalizeRoute("/functions/v1/admin-chat/zzz/nested")).toBe("/nested");
  });

  test("does not throw on a relative or empty url", () => {
    expect(normalizeRoute("")).toBe("/");
    expect(normalizeRoute("/admin-chat")).toBe("/admin-chat");
  });
});

describe("POST /login", () => {
  test("returns a fresh signed token instead of the shared static one", async () => {
    const handler = buildHandler();
    const body = await login(handler);

    expect(body.username).toBe("admin");
    expect(body.token).not.toBe("Samistrongkey2026");
    expect(body.token.split(".")[0]).toBe("v1");
    expect(Date.parse(body.expiresAt)).toBe(Date.parse("2025-10-09T08:53:20Z") + 12 * 3600 * 1000);

    const verified = await verifySessionToken(body.token, SECRET, clock);
    expect(verified.ok).toBe(true);
    if (verified.ok) expect(verified.claims.sid).toBe("session-1");

    // The session was persisted, and the success was audited.
    expect(store.sessions.get("session-1")?.username).toBe("admin");
    expect(store.attempts).toHaveLength(1);
    expect(store.attempts[0]).toMatchObject({ ip: "203.0.113.7", username: "admin", success: true });
  });

  test("two logins get two independent tokens", async () => {
    const handler = buildHandler();
    const first = await login(handler);
    const second = await login(handler);
    expect(first.token).not.toBe(second.token);
    expect(store.sessions.size).toBe(2);
  });

  test("401 Invalid credentials on a wrong password, and the failure is recorded", async () => {
    const handler = buildHandler();
    const res = await post(handler, "/login", { username: "admin", password: "wrong" });
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "Invalid credentials" });
    expect(store.attempts).toEqual([
      { ip: "203.0.113.7", username: "admin", success: false, atSeconds: Math.floor(clock / 1000) },
    ]);
  });

  test("401 for an unknown username, without revealing that it is unknown", async () => {
    const handler = buildHandler();
    const res = await post(handler, "/login", { username: "someone", password: "x" });
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "Invalid credentials" });
    // No bcrypt work happens for a missing row at all.
    expect(store.attempts).toHaveLength(1);
  });

  test("400 when username or password is missing", async () => {
    const handler = buildHandler();
    expect((await post(handler, "/login", { username: "admin" })).status).toBe(400);
    expect((await post(handler, "/login", { password: "x" })).status).toBe(400);
    expect((await post(handler, "/login", { username: "admin", password: "" })).status).toBe(400);
  });

  test("400 on absurdly long input, before any bcrypt work", async () => {
    const handler = buildHandler();
    const res = await post(handler, "/login", {
      username: "admin",
      password: "p".repeat(500),
    });
    expect(res.status).toBe(400);
    expect(store.attempts).toHaveLength(0);
  });

  test("500 naming ADMIN_SESSION_SECRET when the secret is missing", async () => {
    const handler = buildHandler({ ADMIN_SESSION_SECRET: undefined });
    const res = await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD });
    expect(res.status).toBe(500);
    const body = await res.json() as { error: string };
    expect(body.error).toContain("ADMIN_SESSION_SECRET");
    // No session row and no audit row: the request never reached the credentials.
    expect(store.sessions.size).toBe(0);
  });

  test("405 for a GET", async () => {
    const handler = buildHandler();
    const res = await handler(new Request(`${ENDPOINT}/login`, { method: "GET" }));
    expect(res.status).toBe(405);
  });

  test("the login route is reachable without any header (the original bug)", async () => {
    const handler = buildHandler();
    const res = await handler(
      new Request(`${ENDPOINT}/login`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: "admin", password: ADMIN_PASSWORD }),
      }),
    );
    expect(res.status).toBe(200);
  });
});

describe("login rate limiting", () => {
  test("allows up to the username limit, then answers 429 with Retry-After", async () => {
    const handler = buildHandler({ ADMIN_LOGIN_USERNAME_LIMIT: "3", ADMIN_LOGIN_IP_LIMIT: "100" });

    for (let i = 0; i < 3; i++) {
      const res = await post(handler, "/login", { username: "admin", password: "wrong" }, {
        "x-forwarded-for": `198.51.100.${i}`, // a different IP each time: only the username bucket can trip
      });
      expect(res.status).toBe(401);
    }

    const blocked = await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD }, {
      "x-forwarded-for": "198.51.100.99",
    });
    expect(blocked.status).toBe(429);
    expect(blocked.headers.get("Retry-After")).toBe("900");
    const body = await blocked.json() as { code: string; scope: string; retryAfterSeconds: number };
    expect(body.code).toBe("rate_limited");
    expect(body.scope).toBe("username");
    expect(body.retryAfterSeconds).toBe(900);
    // Blocked before the credential check: not even the correct password works.
    expect(store.sessions.size).toBe(0);
    // ...and the blocked attempt is not recorded as a new failure.
    expect(store.attempts).toHaveLength(3);
  });

  test("429 once one IP exceeds the IP limit, even across usernames", async () => {
    const handler = buildHandler({ ADMIN_LOGIN_IP_LIMIT: "2", ADMIN_LOGIN_USERNAME_LIMIT: "100" });
    await post(handler, "/login", { username: "admin", password: "wrong" });
    await post(handler, "/login", { username: "someone-else", password: "wrong" });
    const blocked = await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD });
    expect(blocked.status).toBe(429);
    expect((await blocked.json() as { scope: string }).scope).toBe("ip");
  });

  test("the window slides: old failures stop counting", async () => {
    const handler = buildHandler({ ADMIN_LOGIN_USERNAME_LIMIT: "1", ADMIN_LOGIN_IP_LIMIT: "100" });
    await post(handler, "/login", { username: "admin", password: "wrong" });
    expect((await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD })).status).toBe(429);

    clock += 15 * 60 * 1000 + 1000; // past the 15 minute window
    const res = await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD });
    expect(res.status).toBe(200);
  });

  test("a successful login does not itself count as a failure", async () => {
    const handler = buildHandler({ ADMIN_LOGIN_USERNAME_LIMIT: "1", ADMIN_LOGIN_IP_LIMIT: "1" });
    expect((await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD })).status).toBe(200);
    expect((await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD })).status).toBe(200);
    expect(store.attempts.every((a) => a.success)).toBe(true);
  });

  test("fails open when the limiter store is unavailable, and says so in the log", async () => {
    const handler = buildHandler();
    store.snapshotError = new Error("connection reset by peer");
    const res = await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD });
    expect(res.status).toBe(200);
    expect(logs.some((l) => l.includes("rate-limit check unavailable"))).toBe(true);
  });

  test("a failed audit write does not break a successful login", async () => {
    const handler = buildHandler();
    store.recordAttemptError = new Error("deadlock detected");
    const res = await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD });
    expect(res.status).toBe(200);
    expect(logs.some((l) => l.includes("could not record login attempt"))).toBe(true);
  });

  test("without any client IP header the username bucket still blocks", async () => {
    const handler = buildHandler({ ADMIN_LOGIN_USERNAME_LIMIT: "1", ADMIN_LOGIN_IP_LIMIT: "100" });
    const noIp = (body: unknown) =>
      handler(
        new Request(`${ENDPOINT}/login`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }),
      );
    expect((await noIp({ username: "admin", password: "wrong" })).status).toBe(401);
    expect((await noIp({ username: "admin", password: ADMIN_PASSWORD })).status).toBe(429);
    expect(logs.some((l) => l.includes("no client IP"))).toBe(true);
  });
});

describe("protected routes", () => {
  test("a valid session token is accepted from the body and from the header", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);

    const body = await post(handler, "/conversations", { token });
    expect(body.status).toBe(200);
    expect((await body.json() as { conversations: unknown[] }).conversations).toHaveLength(1);

    const header = await post(handler, "/conversations", {}, { "X-Admin-Token": token });
    expect(header.status).toBe(200);
  });

  test("401 invalid_session without a token, and for garbage", async () => {
    const handler = buildHandler();
    const missing = await post(handler, "/conversations", {});
    expect(missing.status).toBe(401);
    expect((await missing.json() as { code: string }).code).toBe("invalid_session");

    const garbage = await post(handler, "/conversations", { token: "Samistrongkey2026" });
    expect(garbage.status).toBe(401);
    expect((await garbage.json() as { code: string }).code).toBe("invalid_session");
  });

  test("a token signed with another secret is refused", async () => {
    const handler = buildHandler();
    const forged = await signSessionToken(
      { v: 1, sid: "session-1", sub: "admin", iat: 0, exp: Math.floor(clock / 1000) + 600 },
      "a-different-secret-entirely-0000000000",
    );
    const res = await post(handler, "/conversations", { token: forged });
    expect(res.status).toBe(401);
  });

  test("once the session expires every protected route answers 401 session_expired", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);
    expect((await post(handler, "/conversations", { token })).status).toBe(200);

    clock += 12 * 60 * 60 * 1000 + 1000; // past the 12h default TTL
    const res = await post(handler, "/conversations", { token });
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({
      error: "Session expired. Please sign in again.",
      code: "session_expired",
    });
  });

  test("a custom TTL from ADMIN_SESSION_TTL_MINUTES is honoured", async () => {
    const handler = buildHandler({ ADMIN_SESSION_TTL_MINUTES: "30" });
    const body = await login(handler);
    expect(Date.parse(body.expiresAt)).toBe(clock + 30 * 60 * 1000);

    clock += 31 * 60 * 1000;
    expect((await post(handler, "/conversations", { token: body.token })).status).toBe(401);
  });

  test("a revoked session is refused before it expires", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);
    store.sessions.get("session-1")!.revoked_at = new Date(clock).toISOString();

    const res = await post(handler, "/conversations", { token });
    expect(res.status).toBe(401);
    expect((await res.json() as { code: string }).code).toBe("session_revoked");
  });

  test("a session row that disappears (deleted) is refused", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);
    store.sessions.clear();
    const res = await post(handler, "/conversations", { token });
    expect(res.status).toBe(401);
    expect((await res.json() as { code: string }).code).toBe("session_revoked");
  });

  test("known route with the wrong method is a 405, not a 401", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);
    const res = await post(handler, "/conversations", { token });
    expect(res.status).toBe(200);

    const get = await handler(
      new Request(`${ENDPOINT}/conversations`, { method: "GET", headers: { "X-Admin-Token": token } }),
    );
    expect(get.status).toBe(405);
  });

  test("an unknown route is a 404 naming the path (not a misleading 401)", async () => {
    const handler = buildHandler();
    const res = await post(handler, "/zzz", {});
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "Not found", path: "/zzz" });
  });

  test("OPTIONS is answered without auth for CORS preflight", async () => {
    const handler = buildHandler();
    const res = await handler(new Request(`${ENDPOINT}/login`, { method: "OPTIONS" }));
    expect(res.status).toBe(200);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
    expect(res.headers.get("Access-Control-Expose-Headers")).toContain("Retry-After");
  });
});

describe("chat routes", () => {
  test("messages / reply / close behave as before, behind the session gate", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);

    const messages = await post(handler, "/messages", { token, conversationId: "c1" });
    expect(messages.status).toBe(200);
    expect((await messages.json() as { messages: unknown[] }).messages).toHaveLength(1);

    expect((await post(handler, "/messages", { token })).status).toBe(400);

    const reply = await post(handler, "/reply", { token, conversationId: "c1", content: "hello" });
    expect(reply.status).toBe(200);
    expect(store.messages.at(-1)).toMatchObject({ sender: "agent", content: "hello" });

    expect((await post(handler, "/reply", { token, conversationId: "c1" })).status).toBe(400);

    const closed = await post(handler, "/close", { token, conversationId: "c1" });
    expect(closed.status).toBe(200);
    expect(store.conversations[0].status).toBe("closed");
  });
});

describe("POST /logout", () => {
  test("revokes the presented session", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);
    expect(store.sessions.get("session-1")?.revoked_at).toBeNull();

    const res = await post(handler, "/logout", { token });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ success: true });
    expect(store.sessions.get("session-1")?.revoked_at).not.toBeNull();

    expect((await post(handler, "/conversations", { token })).status).toBe(401);
  });

  test("is idempotent for a missing, garbage or expired token", async () => {
    const handler = buildHandler();
    expect((await post(handler, "/logout", {})).status).toBe(200);
    expect((await post(handler, "/logout", { token: "garbage" })).status).toBe(200);
    const { token } = await login(handler);
    clock += 13 * 60 * 60 * 1000;
    expect((await post(handler, "/logout", { token })).status).toBe(200);
  });

  test("only ever revokes the caller's own session", async () => {
    const handler = buildHandler();
    const first = await login(handler);
    const second = await login(handler);
    await post(handler, "/logout", { token: second.token });
    expect(store.sessions.get("session-1")?.revoked_at).toBeNull();
    expect(store.sessions.get("session-2")?.revoked_at).not.toBeNull();
    expect((await post(handler, "/conversations", { token: first.token })).status).toBe(200);
  });
});

describe("POST /change-password", () => {
  test("requires the current password", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);
    const res = await post(handler, "/change-password", {
      token,
      currentPassword: "not-it",
      newPassword: "another-good-password",
    });
    expect(res.status).toBe(401);
    expect(store.admins[0].password_hash).toBe(`bcrypt:${ADMIN_PASSWORD}`);
  });

  test("rejects a short or unchanged new password", async () => {
    const handler = buildHandler();
    const { token } = await login(handler);
    const short = await post(handler, "/change-password", {
      token,
      currentPassword: ADMIN_PASSWORD,
      newPassword: "short",
    });
    expect(short.status).toBe(400);

    const same = await post(handler, "/change-password", {
      token,
      currentPassword: ADMIN_PASSWORD,
      newPassword: ADMIN_PASSWORD,
    });
    expect(same.status).toBe(400);
    expect(store.admins[0].password_hash).toBe(`bcrypt:${ADMIN_PASSWORD}`);
  });

  test("changes the password, keeps the caller's session and drops the others", async () => {
    const handler = buildHandler();
    const first = await login(handler);
    const second = await login(handler);

    const res = await post(handler, "/change-password", {
      token: first.token,
      currentPassword: ADMIN_PASSWORD,
      newPassword: "brand-new-password",
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ success: true, otherSessionsRevoked: 1 });

    // The other session is gone, this one survives.
    expect((await post(handler, "/conversations", { token: second.token })).status).toBe(401);
    expect((await post(handler, "/conversations", { token: first.token })).status).toBe(200);

    // The new password works; the old one does not.
    expect((await post(handler, "/login", { username: "admin", password: ADMIN_PASSWORD })).status).toBe(401);
    const relogin = await post(handler, "/login", { username: "admin", password: "brand-new-password" });
    expect(relogin.status).toBe(200);
  });
});

describe("deployment order resilience (function before migration)", () => {
  test("login still works and the token is honoured when admin_sessions is missing", async () => {
    const handler = buildHandler();
    store.sessionsTableMissing = true;

    const body = await login(handler); // 200, degraded
    expect(logs.some((l) => l.includes("admin_sessions"))).toBe(true);

    const res = await post(handler, "/conversations", { token: body.token });
    expect(res.status).toBe(200);
  });

  test("the signed token is still unforgeable in that degraded mode", async () => {
    const handler = buildHandler();
    store.sessionsTableMissing = true;
    await post(handler, "/conversations", { token: "v1.eyJhIjoxfQ.AAAA" });
    expect((await post(handler, "/conversations", { token: "v1.eyJhIjoxfQ.AAAA" })).status).toBe(401);
  });
});
