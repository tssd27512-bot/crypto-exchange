/**
 * The data-access port the admin-chat handler needs.
 *
 * The handler depends on this interface, never on supabase-js directly, so the
 * whole request pipeline can be exercised in a unit test with an in-memory
 * implementation (see tests/handler.test.ts) — no database, no credentials.
 * `supabase_store.ts` is the production implementation.
 */

export interface AdminRecord {
  id: string;
  username: string;
  password_hash: string;
}

export interface SessionRecord {
  id: string;
  username: string;
  issued_at: string;
  expires_at: string;
  revoked_at: string | null;
}

export interface NewSessionRecord {
  id: string;
  username: string;
  issuedAt: string;
  expiresAt: string;
  ip: string | null;
  userAgent: string | null;
}

export interface LoginAttemptRecord {
  ip: string | null;
  username: string | null;
  success: boolean;
}

export interface LoginFailureSnapshot {
  /** Failure timestamps in unix seconds, ascending. */
  ipFailures: number[];
  usernameFailures: number[];
}

export interface ConversationRecord {
  id: string;
  [key: string]: unknown;
}

export interface MessageRecord {
  id: string;
  [key: string]: unknown;
}

/** Raised by the store when a required table/function does not exist yet. */
export class MissingRelationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "MissingRelationError";
  }
}

export interface AdminStore {
  findAdminByUsername(username: string): Promise<AdminRecord | null>;
  verifyPassword(hash: string, plain: string): Promise<boolean>;
  updateAdminPassword(newPlain: string): Promise<void>;

  createSession(session: NewSessionRecord): Promise<void>;
  getSession(id: string): Promise<SessionRecord | null>;
  revokeSession(id: string): Promise<void>;
  revokeSessionsExcept(username: string, keepSessionId: string | null): Promise<number>;

  loginFailureSnapshot(input: {
    ip: string | null;
    username: string | null;
    windowSeconds: number;
  }): Promise<LoginFailureSnapshot>;
  recordLoginAttempt(attempt: LoginAttemptRecord): Promise<void>;

  listConversations(): Promise<ConversationRecord[]>;
  listMessages(conversationId: string): Promise<MessageRecord[]>;
  insertAgentMessage(conversationId: string, content: string): Promise<void>;
  touchConversation(conversationId: string): Promise<void>;
  closeConversation(conversationId: string): Promise<void>;
}

/**
 * True when an error means "this table/function is not deployed yet" (the
 * migration has not been applied), as opposed to a real failure. The handler
 * uses this to keep working in a degraded, stateless mode instead of locking
 * the owner out when the function is deployed before the migration.
 *
 * Recognised shapes:
 *   - Postgres 42P01 (undefined_table) / 42883 (undefined_function)
 *   - PostgREST PGRST202 / PGRST205 ("... in the schema cache")
 *   - any message hinting at a missing relation or an unknown RPC
 */
export function isMissingRelationError(error: unknown): boolean {
  if (!error) return false;
  const code = String((error as { code?: unknown }).code ?? "");
  if (code === "42P01" || code === "42883" || code === "PGRST202" || code === "PGRST205") {
    return true;
  }
  const message = String((error as { message?: unknown }).message ?? error);
  return /does not exist|Could not find the (function|table)|schema cache/i.test(message);
}
