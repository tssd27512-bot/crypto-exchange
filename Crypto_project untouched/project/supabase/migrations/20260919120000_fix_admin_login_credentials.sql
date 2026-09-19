/*
# Fix admin login: guarantee the default admin user and harden verify_password()

## Why (confirmed against the live project, 2026-09-19)

`POST /functions/v1/admin-chat/login` with `{"username":"admin","password":"admin123"}`
returned `401 {"error":"Unauthorized"}`. That body is produced by the admin-token
gate, never by the `/login` route, so the login route was never reached — see the
matching fix in `supabase/functions/admin-chat/index.ts`. This migration fixes the
*other* half: making sure the credentials in the database are actually usable if
and when the edge function does reach the login route.

Two live findings this migration addresses:

1. `verify_password()` only works for `$2a$` bcrypt hashes. Live probe:
     hash $2a$…10$… + plain "admin123" -> true
     hash $2b$…10$… + plain "admin123" -> false
   pgcrypto's `crypt()` does not understand the `$2b$`/`$2y$` prefixes (the default
   output of e.g. Node's bcryptjs), and a mismatch is silently reported as
   "Invalid credentials". Remapped below for ASCII passwords, where the three
   prefixes are equivalent.

2. `verify_password()` and `update_admin_password()` were granted to `anon`
   (public key, shipped in the browser bundle) and `authenticated` by migrations
   20260917170315 and 20260917170350. That is a security regression: the anon key
   is enough to use `verify_password` as a bcrypt oracle over PostgREST, and
   `update_admin_password` would let any signed-up user reset the admin password.
   This migration narrows both to `service_role` only. This is a deliberate
   behaviour change, not an accident — call it out in review.

## What it does (all steps idempotent)

1. Ensures pgcrypto exists, in the `extensions` schema Supabase uses.
2. Ensures `public.admin_users` exists with the shape from 20260916105205.
3. Inserts `admin` / `admin123` **only if the row is missing or its stored hash is
   not a usable bcrypt hash**. A row that already holds a valid bcrypt hash is
   left untouched (a NOTICE says so) — this migration must not silently reset a
   password the owner has changed.
4. Recreates `verify_password()` / `update_admin_password()` with
   `search_path = extensions, public`, a fully-qualified `public.admin_users`
   reference, and the `$2b$`/`$2y$` -> `$2a$` remap.
5. Revokes EXECUTE on both from PUBLIC, `anon` and `authenticated`; grants it to
   `service_role` only.
6. Keeps `admin_users` locked down: RLS enabled and any policy dropped, so the
   hashes are only reachable with the service role key.

## If `admin` / `admin123` still fails after this

The row exists with a valid bcrypt hash of a *different* password, and was
therefore deliberately left alone. Reset it with:
  UPDATE public.admin_users
     SET password_hash = extensions.crypt('admin123', extensions.gen_salt('bf'))
   WHERE username = 'admin';
*/

-- 1. pgcrypto. On Supabase it belongs in the "extensions" schema; a no-op when
--    it is already installed somewhere.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Resolve crypt()/gen_salt() for the rest of this file regardless of whether
-- pgcrypto ended up in "extensions" or "public". Non-existent schemas in
-- search_path are ignored, so this is safe on a project without "extensions".
SET search_path = extensions, public;

-- 2. Table shape from 20260916105205. IF NOT EXISTS keeps this a no-op on the
--    live project; schema-qualified because search_path now starts elsewhere.
CREATE TABLE IF NOT EXISTS public.admin_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username text UNIQUE NOT NULL,
  password_hash text NOT NULL,
  created_at timestamptz DEFAULT now()
);

-- 3. Guarantee the default admin user, without clobbering a changed password.
DO $$
DECLARE
  v_hash text;
BEGIN
  SELECT password_hash
    INTO v_hash
    FROM public.admin_users
   WHERE username = 'admin';

  IF NOT FOUND THEN
    INSERT INTO public.admin_users (username, password_hash)
    VALUES ('admin', crypt('admin123', gen_salt('bf')));
    RAISE NOTICE '[admin login fix] inserted default admin user (admin/admin123)';
  ELSIF v_hash IS NULL OR v_hash !~ '^\$2[aby]\$' THEN
    UPDATE public.admin_users
       SET password_hash = crypt('admin123', gen_salt('bf'))
     WHERE username = 'admin';
    RAISE NOTICE '[admin login fix] admin row had an unusable hash (%); reset to admin123',
      coalesce(left(v_hash, 12), 'NULL');
  ELSE
    RAISE NOTICE '[admin login fix] admin row already has a usable bcrypt hash; left untouched';
  END IF;
END $$;

-- 4. Helper functions.
--    CREATE OR REPLACE (not DROP + CREATE, as the previous two migrations did) so
--    there is no window in which the edge function's RPC target is missing.
CREATE OR REPLACE FUNCTION public.verify_password(hash text, plain text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = extensions, public
AS $$
DECLARE
  v_hash text;
BEGIN
  IF hash IS NULL OR plain IS NULL THEN
    RETURN false;
  END IF;

  -- pgcrypto's crypt() only understands the "$2a$" bcrypt prefix. Remap the
  -- equivalent "$2b$"/"$2y$" prefixes so a hash written by Node's bcryptjs
  -- still verifies instead of failing as "Invalid credentials".
  v_hash := hash;
  IF left(v_hash, 4) IN ('$2b$', '$2y$') THEN
    v_hash := '$2a$' || substr(v_hash, 5);
  END IF;

  RETURN crypt(plain, v_hash) = v_hash;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_admin_password(new_plain text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = extensions, public
AS $$
BEGIN
  IF new_plain IS NULL OR new_plain = '' THEN
    RAISE EXCEPTION 'new password must not be empty';
  END IF;

  UPDATE public.admin_users
     SET password_hash = crypt(new_plain, gen_salt('bf'))
   WHERE username = 'admin';
END;
$$;

-- 5. service_role only. SECURITY DEFINER means these run with elevated rights,
--    so they must not be reachable with the public anon key or by any ordinary
--    signed-in user.
REVOKE ALL ON FUNCTION public.verify_password(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_admin_password(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.verify_password(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.update_admin_password(text) TO service_role;

-- 6. Password hashes must stay unreachable from the client-side roles.
ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_users TO service_role;

DO $$
DECLARE
  p record;
BEGIN
  FOR p IN
    SELECT policyname
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename = 'admin_users'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.admin_users', p.policyname);
    RAISE NOTICE '[admin login fix] dropped policy % on public.admin_users', p.policyname;
  END LOOP;
END $$;

-- Leave the session's search_path as we found it.
RESET search_path;
