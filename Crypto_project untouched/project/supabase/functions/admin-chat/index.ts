/**
 * admin-chat — Supabase edge function entrypoint.
 *
 * This file only wires the pieces together:
 *   handler.ts        request routing, auth gate, login flow
 *   session.ts        per-session expiring signed tokens
 *   rate_limit.ts     per-IP / per-username login limiting
 *   supabase_store.ts the Postgres side (service role)
 *
 * Route shapes, the auth model and every secret it needs are documented in
 * `supabase/ADMIN_AUTH.md` next to the migrations.
 *
 * History worth keeping: this function used to gate every protected route on a
 * single static shared token (ADMIN_CHAT_TOKEN), with a compiled-in fallback
 * value, and returned that same constant from /login. It also resolved its
 * route with `url.pathname.replace("/functions/v1/admin-chat", "")`, a silent
 * no-op in the real runtime, so every request — including POST /login — fell
 * through to that gate and returned 401 {"error":"Unauthorized"}. Both are
 * fixed; the static token and its fallback are gone for good.
 */

import { createHandler } from "./handler.ts";
import { createSupabaseStore } from "./supabase_store.ts";

const REQUIRED_SECRETS = [
  "SUPABASE_URL",
  "SUPABASE_SERVICE_ROLE_KEY",
  "ADMIN_SESSION_SECRET",
];

// Report presence, never values. This turns "login returns 500" into a log line
// that names the missing secret.
for (const name of REQUIRED_SECRETS) {
  if (!Deno.env.get(name)) {
    console.error(`[admin-chat] required secret ${name} is NOT set`);
  }
}
if (Deno.env.get("ADMIN_CHAT_TOKEN")) {
  console.warn(
    "[admin-chat] ADMIN_CHAT_TOKEN is set but no longer used (session tokens replaced it); " +
      "it can be removed with: supabase secrets unset ADMIN_CHAT_TOKEN",
  );
}

const handler = createHandler({
  store: createSupabaseStore(),
  getEnv: (name) => Deno.env.get(name),
  now: () => Date.now(),
  newSessionId: () => crypto.randomUUID(),
  log: (level, message) => {
    if (level === "error") console.error(message);
    else if (level === "warn") console.warn(message);
    else console.log(message);
  },
});

Deno.serve(handler);
