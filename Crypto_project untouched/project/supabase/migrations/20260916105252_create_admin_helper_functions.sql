/*
# Create admin password helper functions

## Purpose
Helper functions for the admin-chat edge function to verify and update admin passwords.

## Functions

### verify_password(hash text, plain text) returns boolean
- Uses pgcrypto's crypt() to compare a plaintext password against a stored hash.
- Returns true if the password matches the hash.

### update_admin_password(new_plain text) returns void
- Hashes the new password and updates the admin user's password_hash.
- Uses pgcrypto's crypt() with a new salt.

## Security
- Both functions are SECURITY DEFINER so they can run with elevated privileges.
- verify_password is callable by the service role (used by edge function).
- update_admin_password is callable by the service role (used by edge function).
- Neither function is callable by anon or authenticated roles (no EXECUTE grants).
*/

CREATE OR REPLACE FUNCTION verify_password(hash text, plain text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN crypt(plain, hash) = hash;
END;
$$;

CREATE OR REPLACE FUNCTION update_admin_password(new_plain text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  UPDATE admin_users
  SET password_hash = crypt(new_plain, gen_salt('bf'))
  WHERE username = 'admin';
END;
$$;

-- Revoke execute from public, grant only to service_role
REVOKE EXECUTE ON FUNCTION verify_password(text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION update_admin_password(text) FROM PUBLIC;
