import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});

const ADMIN_TOKEN = Deno.env.get("ADMIN_CHAT_TOKEN") || "live-chat-admin-token-2024";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  try {
    const url = new URL(req.url);
    const path = url.pathname.replace("/functions/v1/admin-chat", "");
    const body = await req.json().catch(() => ({}));

    // --- LOGIN ---
    if (path === "/login" && req.method === "POST") {
      const { username, password } = body;

      if (!username || !password) {
        return jsonResponse(400, { error: "Username and password required" });
      }

      const { data, error } = await supabase
        .from("admin_users")
        .select("id, username, password_hash")
        .eq("username", username)
        .maybeSingle();

      if (error) {
        return jsonResponse(500, { error: `Database error: ${error.message}` });
      }
      if (!data) {
        return jsonResponse(401, { error: "Invalid credentials" });
      }

      // Verify password using pgcrypto's crypt function
      const { data: verifyData, error: verifyError } = await supabase.rpc(
        "verify_password",
        { hash: data.password_hash, plain: password }
      );

      if (verifyError) {
        return jsonResponse(500, { error: `Verify error: ${verifyError.message}` });
      }
      if (!verifyData) {
        return jsonResponse(401, { error: "Invalid credentials" });
      }

      return jsonResponse(200, { token: ADMIN_TOKEN, username: data.username });
    }

    // --- CHANGE PASSWORD ---
    if (path === "/change-password" && req.method === "POST") {
      const { token, currentPassword, newPassword } = body;

      if (token !== ADMIN_TOKEN) {
        return jsonResponse(401, { error: "Unauthorized" });
      }

      if (!currentPassword || !newPassword) {
        return jsonResponse(400, { error: "Current and new password required" });
      }

      const { data: admin, error: adminError } = await supabase
        .from("admin_users")
        .select("id, password_hash")
        .eq("username", "admin")
        .maybeSingle();

      if (adminError || !admin) {
        return jsonResponse(500, { error: "Admin user not found" });
      }

      const { data: verifyData, error: verifyError } = await supabase.rpc(
        "verify_password",
        { hash: admin.password_hash, plain: currentPassword }
      );

      if (verifyError || !verifyData) {
        return jsonResponse(401, { error: "Current password is incorrect" });
      }

      const { error: updateError } = await supabase.rpc("update_admin_password", {
        new_plain: newPassword,
      });

      if (updateError) {
        return jsonResponse(500, { error: "Failed to update password" });
      }

      return jsonResponse(200, { success: true });
    }

    // --- AUTH CHECK for all other routes ---
    const token = body.token || req.headers.get("X-Admin-Token");
    if (token !== ADMIN_TOKEN) {
      return jsonResponse(401, { error: "Unauthorized" });
    }

    // --- GET CONVERSATIONS ---
    if (path === "/conversations" && req.method === "POST") {
      const { data, error } = await supabase
        .from("chat_conversations")
        .select("*")
        .order("updated_at", { ascending: false });

      if (error) {
        return jsonResponse(500, { error: error.message });
      }

      return jsonResponse(200, { conversations: data });
    }

    // --- GET MESSAGES ---
    if (path === "/messages" && req.method === "POST") {
      const { conversationId } = body;

      if (!conversationId) {
        return jsonResponse(400, { error: "Conversation ID required" });
      }

      const { data, error } = await supabase
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
    if (path === "/reply" && req.method === "POST") {
      const { conversationId, content } = body;

      if (!conversationId || !content) {
        return jsonResponse(400, { error: "Conversation ID and content required" });
      }

      const { error: msgError } = await supabase.from("chat_messages").insert({
        conversation_id: conversationId,
        sender: "agent",
        content,
      });

      if (msgError) {
        return jsonResponse(500, { error: msgError.message });
      }

      // Bump updated_at
      await supabase
        .from("chat_conversations")
        .update({ updated_at: new Date().toISOString() })
        .eq("id", conversationId);

      return jsonResponse(200, { success: true });
    }

    // --- CLOSE CONVERSATION ---
    if (path === "/close" && req.method === "POST") {
      const { conversationId } = body;

      if (!conversationId) {
        return jsonResponse(400, { error: "Conversation ID required" });
      }

      const { error } = await supabase
        .from("chat_conversations")
        .update({ status: "closed" })
        .eq("id", conversationId);

      if (error) {
        return jsonResponse(500, { error: error.message });
      }

      return jsonResponse(200, { success: true });
    }

    return jsonResponse(404, { error: "Not found" });
  } catch (err) {
    return jsonResponse(500, { error: (err as Error).message });
  }
});

function jsonResponse(status: number, data: unknown) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
