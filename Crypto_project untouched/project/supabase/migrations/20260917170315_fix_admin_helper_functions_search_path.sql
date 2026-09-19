/*
# Fix admin helper functions search_path

## Problem
The verify_password and update_admin_password functions are SECURITY DEFINER
but have no search_path set. This means they may fail to find the crypt() and
gen_salt() functions from the pgcrypto extension, depending on the caller's
search_path. The edge function calls these via RPC with the service role key.

## Fix
- Recreate both functions with an explicit search_path that includes public
  (where pgcrypto functions live).
- Grant EXECUTE to the service_role and authenticated roles explicitly.
*/

DROP FUNCTION IF EXISTS verify_password(text, text);
DROP FUNCTION IF EXISTS update_admin_password(text);

CREATE FUNCTION verify_password(hash text, plain text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN crypt(plain, hash) = hash;
END;
$$;

CREATE FUNCTION update_admin_password(new_plain text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE admin_users
  SET password_hash = crypt(new_plain, gen_salt('bf'))
  WHERE username = 'admin';
END;
$$;

-- Grant execute to service_role (used by edge function) and authenticated
GRANT EXECUTE ON FUNCTION verify_password(text, text) TO service_role, authenticated, anon;
GRANT EXECUTE ON FUNCTION update_admin_password(text) TO service_role, authenticated;
