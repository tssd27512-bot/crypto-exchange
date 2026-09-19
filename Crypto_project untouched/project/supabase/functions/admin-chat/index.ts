import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers":
    "Content-Type, Authorization, X-Client-Info, Apikey, X-Admin-Token",
};

/**
 * Every route this function serves. Used both for dispatch and to strip
 * platform/gateway path prefixes in normalizeRoute().
 */
const ROUTES = new Set([
  "login",
  "change-password",
  "conversations",
  "messages",
  "reply",
  "close",
]);

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
function normalizeRoute(rawUrl: string): string {
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
class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

/**
 * Read a required function secret. Throws a clearly-named 500 instead of
 * returning a misleading 401 when the function is misconfigured.
 */
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

let supabaseClient: ReturnType<typeof createClient> | null = null;

/**
 * Lazily build the service-role client. Previously this ran at module scope
 * with `Deno.env.get(...)!`, so a missing secret crashed the whole function at
 * boot with an opaque error instead of naming the variable at fault.
 */
function db() {
  if (!supabaseClient) {
    supabaseClient = createClient(
      requireEnv("SUPABASE_URL"),
      requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false } },
    );
  }
  return supabaseClient;
}

function adminToken(): string {
  const configured = Deno.env.get("ADMIN_CHAT_TOKEN");
  if (!configured) {
    console.warn(
      "[admin-chat] ADMIN_CHAT_TOKEN is not set — falling back to the built-in " +
        "default token. Set ADMIN_CHAT_TOKEN in the function secrets.",
    );
    return "live-chat-admin-token-2024";
  }
  return configured;
}

/**
 * pgcrypto's crypt() only understands the "$2a$" bcrypt prefix; a "$2b$"/"$2y$"
 * hash (the default output of e.g. Node's bcryptjs) makes crypt() return a
 * non-matching value, so login fails with "Invalid credentials" even though the
 * password is right. For ASCII passwords the three prefixes are equivalent, so
 * remap them. The SQL helper verify_password() does the same thing; this is a
 * defensive copy for deployments where the migration has not been applied yet.
 */
function normalizeBcryptPrefix(hash: string): string {
  return hash.replace(/^\$2[by]\$/, "$2a$");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  try {
    const route = normalizeRoute(req.url);
    const body = await req.json().catch(() => ({}));

    // --- LOGIN ---
    // Deliberately before the token gate: this route is how the token is
    // obtained. It must not depend on ADMIN_CHAT_TOKEN or on any header the
    // login screen cannot send.
    if (route === "/login") {
      if (req.method !== "POST") {
        return jsonResponse(405, { error: "Method not allowed" });
      }

      const { username, password } = body;

      if (!username || !password) {
        return jsonResponse(400, { error: "Username and password required" });
      }

      const { data, error } = await db()
        .from("admin_users")
        .select("id, username, password_hash")
        .eq("username", username)
        .maybeSingle();

      if (error) {
        return jsonResponse(500, { error: `Database error: ${error.message}` });
      }
      if (!data) {
        console.error(`[admin-chat] login failed: no admin_users row for "${username}"`);
        return jsonResponse(401, { error: "Invalid credentials" });
      }

      // Verify password using pgcrypto's crypt function
      const { data: verifyData, error: verifyError } = await db().rpc(
        "verify_password",
        { hash: normalizeBcryptPrefix(data.password_hash), plain: password },
      );

      if (verifyError) {
        return jsonResponse(500, { error: `Verify error: ${verifyError.message}` });
      }
      if (!verifyData) {
        console.error(
          `[admin-chat] login failed: password mismatch for "${username}"`,
        );
        return jsonResponse(401, { error: "Invalid credentials" });
      }

      return jsonResponse(200, {
        token: adminToken(),
        username: data.username,
      });
    }

    // --- UNKNOWN ROUTE ---
    // Report this as a 404 naming the path we resolved, instead of falling
    // through to the token gate and masquerading as an auth failure.
    if (!ROUTES.has(route.replace(/^\//, ""))) {
      console.error(`[admin-chat] unrouted request: ${req.method} ${route} (from ${req.url})`);
      return jsonResponse(404, { error: "Not found", path: route });
    }

    // --- AUTH CHECK for all other routes ---
    const token = body.token || req.headers.get("X-Admin-Token");
    if (token !== adminToken()) {
      return jsonResponse(401, { error: "Unauthorized" });
    }

    // --- CHANGE PASSWORD ---
    if (route === "/change-password" && req.method === "POST") {
      const { currentPassword, newPassword } = body;

      if (!currentPassword || !newPassword) {
        return jsonResponse(400, {
          error: "Current and new password required",
        });
      }

      const { data: admin, error: adminError } = await db()
        .from("admin_users")
        .select("id, password_hash")
        .eq("username", "admin")
        .maybeSingle();

      if (adminError || !admin) {
        return jsonResponse(500, { error: "Admin user not found" });
      }

      const { data: verifyData, error: verifyError } = await db().rpc(
        "verify_password",
        {
          hash: normalizeBcryptPrefix(admin.password_hash),
          plain: currentPassword,
        },
      );

      if (verifyError || !verifyData) {
        return jsonResponse(401, { error: "Current password is incorrect" });
      }

      const { error: updateError } = await db().rpc("update_admin_password", {
        new_plain: newPassword,
      });

      if (updateError) {
        return jsonResponse(500, { error: "Failed to update password" });
      }

      return jsonResponse(200, { success: true });
    }

    // --- GET CONVERSATIONS ---
    if (route === "/conversations" && req.method === "POST") {
      const { data, error } = await db()
        .from("chat_conversations")
        .select("*")
        .order("updated_at", { ascending: false });

      if (error) {
        return jsonResponse(500, { error: error.message });
      }

      return jsonResponse(200, { conversations: data });
    }

    // --- GET MESSAGES ---
    if (route === "/messages" && req.method === "POST") {
      const { conversationId } = body;

      if (!conversationId) {
        return jsonResponse(400, { error: "Conversation ID required" });
      }

      const { data, error } = await db()
        .from("chat_messages")
        .select("*")
        .eq("conversation_id", conversationId)
        .order("created_at", { ascending: true });

      if (error) {
        return jsonResponse(500, { error: error.message });
      }

      return jsonResponse(200, { messages: data });
    }

    // --- SEND REPLY ---
    if (route === "/reply" && req.method === "POST") {
      const { conversationId, content } = body;

      if (!conversationId || !content) {
        return jsonResponse(400, {
          error: "Conversation ID and content required",
        });
      }

      const { error: msgError } = await db().from("chat_messages").insert({
        conversation_id: conversationId,
        sender: "agent",
        content,
      });

      if (msgError) {
        return jsonResponse(500, { error: msgError.message });
      }

      // Bump updated_at
      await db()
        .from("chat_conversations")
        .update({ updated_at: new Date().toISOString() })
        .eq("id", conversationId);

      return jsonResponse(200, { success: true });
    }

    // --- CLOSE CONVERSATION ---
    if (route === "/close" && req.method === "POST") {
      const { conversationId } = body;

      if (!conversationId) {
        return jsonResponse(400, { error: "Conversation ID required" });
      }

      const { error } = await db()
        .from("chat_conversations")
        .update({ status: "closed" })
        .eq("id", conversationId);

      if (error) {
        return jsonResponse(500, { error: error.message });
      }

      return jsonResponse(200, { success: true });
    }

    // Known route, wrong method.
    return jsonResponse(405, { error: "Method not allowed" });
  } catch (err) {
    if (err instanceof HttpError) {
      console.error(`[admin-chat] ${err.message}`);
      return jsonResponse(err.status, { error: err.message });
    }
    return jsonResponse(500, { error: (err as Error).message });
  }
});

function jsonResponse(status: number, data: unknown) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
