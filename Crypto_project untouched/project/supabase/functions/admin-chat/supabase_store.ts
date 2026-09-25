/**
 * Production AdminStore: Supabase (Postgres + PostgREST) behind the service
 * role key. The client is built lazily so a missing secret names the variable
 * at request time instead of crashing the function at boot.
 */

import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import {
  MissingRelationError,
  type AdminRecord,
  type AdminStore,
  type ConversationRecord,
  type MessageRecord,
  type SessionRecord,
} from "./admin_store.ts";
import { HttpError } from "./handler.ts";

type SupabaseClient = ReturnType<typeof createClient>;

/** PostgREST/Postgres error shape, as handed back by supabase-js. */
interface SupabaseError {
  message?: string;
  code?: string;
  details?: string;
  hint?: string;
}

/**
 * Turn a supabase-js error into a real Error, preserving the Postgres/PostgREST
 * `code` so `isMissingRelationError()` can recognise an unapplied migration.
 */
function toError(error: SupabaseError | null, context: string): Error {
  const message = error?.message || context;
  if (
    error?.code === "42P01" ||
    error?.code === "42883" ||
    error?.code === "PGRST202" ||
    error?.code === "PGRST205" ||
    /does not exist|schema cache/i.test(message)
  ) {
    return new MissingRelationError(message);
  }
  const wrapped = new Error(message) as Error & { code?: string };
  if (error?.code) wrapped.code = error.code;
  return wrapped;
}

let sharedClient: SupabaseClient | null = null;

function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new HttpError(
      500,
      `Server misconfigured: the ${name} secret is not set for this function. ` +
        `Set it with: supabase secrets set ${name}=<value>`,
    );
  }
  return value;
}

function db(): SupabaseClient {
  if (!sharedClient) {
    sharedClient = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } },
    );
  }
  return sharedClient;
}

export function createSupabaseStore(): AdminStore {
  return {
    async findAdminByUsername(username): Promise<AdminRecord | null> {
      const { data, error } = await db()
        .from("admin_users")
        .select("id, username, password_hash")
        .eq("username", username)
        .maybeSingle();
      if (error) throw toError(error, "admin_users lookup failed");
      return (data as AdminRecord | null) ?? null;
    },

    async verifyPassword(hash, plain): Promise<boolean> {
      const { data, error } = await db().rpc("verify_password", {
        hash,
        plain,
      });
      if (error) throw toError(error, "verify_password failed");
      return data === true;
    },

    async updateAdminPassword(newPlain): Promise<void> {
      const { error } = await db().rpc("update_admin_password", {
        new_plain: newPlain,
      });
      if (error) throw toError(error, "update_admin_password failed");
    },

    async createSession(session): Promise<void> {
      const { error } = await db().from("admin_sessions").insert({
        id: session.id,
        username: session.username,
        issued_at: session.issuedAt,
        expires_at: session.expiresAt,
        ip: session.ip,
        user_agent: session.userAgent,
      });
      if (error) throw toError(error, "admin_sessions insert failed");
    },

    async getSession(id): Promise<SessionRecord | null> {
      const { data, error } = await db()
        .from("admin_sessions")
        .select("id, username, issued_at, expires_at, revoked_at")
        .eq("id", id)
        .maybeSingle();
      if (error) throw toError(error, "admin_sessions lookup failed");
      return (data as SessionRecord | null) ?? null;
    },

    async revokeSession(id): Promise<void> {
      const { error } = await db()
        .from("admin_sessions")
        .update({ revoked_at: new Date().toISOString() })
        .eq("id", id)
        .is("revoked_at", null);
      if (error) throw toError(error, "admin_sessions revoke failed");
    },

    async revokeSessionsExcept(username, keepSessionId): Promise<number> {
      const { data, error } = await db().rpc("admin_revoke_sessions", {
        p_username: username,
        p_keep_session: keepSessionId,
      });
      if (error) throw toError(error, "admin_revoke_sessions failed");
      return typeof data === "number" ? data : 0;
    },

    async loginFailureSnapshot({ ip, username, windowSeconds }) {
      const { data, error } = await db().rpc("admin_login_failures", {
        p_ip: ip,
        p_username: username,
        p_window_seconds: windowSeconds,
      });
      if (error) throw toError(error, "admin_login_failures failed");
      // A set-returning function comes back as an array of rows.
      const row = (Array.isArray(data) ? data[0] : data) as
        | { ip_failures?: string[]; username_failures?: string[] }
        | undefined;
      return {
        ipFailures: row?.ip_failures ?? [],
        usernameFailures: row?.username_failures ?? [],
      };
    },

    async recordLoginAttempt(attempt): Promise<void> {
      const { error } = await db().rpc("admin_record_login_attempt", {
        p_ip: attempt.ip,
        p_username: attempt.username,
        p_success: attempt.success,
      });
      if (error) throw toError(error, "admin_record_login_attempt failed");
    },

    async listConversations(): Promise<ConversationRecord[]> {
      const { data, error } = await db()
        .from("chat_conversations")
        .select("*")
        .order("updated_at", { ascending: false });
      if (error) throw toError(error, "chat_conversations query failed");
      return (data as ConversationRecord[] | null) ?? [];
    },

    async listMessages(conversationId): Promise<MessageRecord[]> {
      const { data, error } = await db()
        .from("chat_messages")
        .select("*")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true });
      if (error) throw toError(error, "chat_messages query failed");
      return (data as MessageRecord[] | null) ?? [];
    },

    async insertAgentMessage(conversationId, content): Promise<void> {
      const { error } = await db().from("chat_messages").insert({
        conversation_id: conversationId,
        sender: "agent",
        content,
      });
      if (error) throw toError(error, "chat_messages insert failed");
    },

    async touchConversation(conversationId): Promise<void> {
      const { error } = await db()
        .from("chat_conversations")
        .update({ updated_at: new Date().toISOString() })
        .eq("id", conversationId);
      if (error) throw toError(error, "chat_conversations update failed");
    },

    async closeConversation(conversationId): Promise<void> {
      const { error } = await db()
        .from("chat_conversations")
        .update({ status: "closed" })
        .eq("id", conversationId);
      if (error) throw toError(error, "chat_conversations close failed");
    },
  };
}
