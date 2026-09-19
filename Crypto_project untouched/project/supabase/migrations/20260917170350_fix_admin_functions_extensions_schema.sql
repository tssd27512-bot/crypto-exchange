/*
# Fix admin helper functions to use extensions schema

## Problem
The crypt() and gen_salt() functions from pgcrypto are installed in the
"extensions" schema on Supabase, not "public". The helper functions had
search_path = public, so they could not find crypt()/gen_salt().

## Fix
- Update both functions to use search_path = extensions, public
- This ensures crypt() and gen_salt() are found.
*/

DROP FUNCTION IF EXISTS verify_password(text, text);
DROP FUNCTION IF EXISTS update_admin_password(text);

CREATE FUNCTION verify_password(hash text, plain text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = extensions, public
AS $$
BEGIN
  RETURN crypt(plain, hash) = hash;
END;
$$;

CREATE FUNCTION update_admin_password(new_plain text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = extensions, public
AS $$
BEGIN
  UPDATE admin_users
  SET password_hash = crypt(new_plain, gen_salt('bf'))
  WHERE username = 'admin';
END;
$$;

GRANT EXECUTE ON FUNCTION verify_password(text, text) TO service_role, authenticated, anon;
GRANT EXECUTE ON FUNCTION update_admin_password(text) TO service_role, authenticated;
