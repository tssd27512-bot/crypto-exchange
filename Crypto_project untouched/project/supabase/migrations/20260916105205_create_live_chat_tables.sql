/*
# Create Live Chat Tables

## Purpose
Real-time live chat system replacing the demo AI chatbot.
Visitors chat with a real human support agent through a chat widget.
The site owner logs into an admin panel to see and reply to conversations.

## New Tables

### chat_conversations
- `id` (uuid, primary key) — unique conversation ID
- `visitor_id` (text, not null) — a random ID generated client-side per browser (stored in localStorage), identifies the visitor across sessions
- `visitor_name` (text, nullable) — optional display name the visitor can set
- `status` (text, default 'open') — 'open' or 'closed' by admin
- `created_at` (timestamptz, default now())
- `updated_at` (timestamptz, default now()) — bumped on each new message for sorting

### chat_messages
- `id` (uuid, primary key)
- `conversation_id` (uuid, FK to chat_conversations, ON DELETE CASCADE)
- `sender` (text, not null) — 'visitor' or 'agent'
- `content` (text, not null) — the message text
- `created_at` (timestamptz, default now())

### admin_users
- `id` (uuid, primary key)
- `username` (text, unique, not null) — admin login username
- `password_hash` (text, not null) — bcrypt-style hash of the password
- `created_at` (timestamptz, default now())

## Security (RLS)

### chat_conversations
- SELECT/INSERT/UPDATE for anon+authenticated (visitors need to create and read their own conversations; admin uses service role key which bypasses RLS)

### chat_messages
- SELECT/INSERT for anon+authenticated (visitors send and read messages in their conversations; admin uses service role key)

### admin_users
- No policies — only accessible via service role key (used by the edge function for admin login)

## Realtime
- Both tables added to the `supabase_realtime` publication so the frontend can subscribe to INSERT events via Supabase Realtime channels.

## Admin Authentication
- Admin login is handled by an edge function that checks the admin_users table using the service role key.
- The default admin credentials are username: `admin`, password: `admin123`.
- The password is stored as a crypt() hash (Postgres built-in pgcrypto extension).

## Important Notes
1. The admin panel uses a simple token-based auth: the edge function returns a signed token on successful login, stored in sessionStorage.
2. The admin panel reads/writes data using the service role key via edge functions — never exposed to the client.
3. Visitor chat uses the anon key directly with RLS policies allowing public read/write to chat tables.
*/
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS chat_conversations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  visitor_id text NOT NULL,
  visitor_name text,
  status text NOT NULL DEFAULT 'open',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id uuid NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
  sender text NOT NULL CHECK (sender IN ('visitor', 'agent')),
  content text NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS admin_users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username text UNIQUE NOT NULL,
  password_hash text NOT NULL,
  created_at timestamptz DEFAULT now()
);

-- Insert default admin user if not exists (username: admin, password: admin123)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM admin_users WHERE username = 'admin') THEN
    INSERT INTO admin_users (username, password_hash)
    VALUES ('admin', crypt('admin123', gen_salt('bf')));
  END IF;
END $$;

-- Enable RLS
ALTER TABLE chat_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;

-- chat_conversations policies (anon + authenticated — public chat)
DROP POLICY IF EXISTS "chat_conversations_select" ON chat_conversations;
CREATE POLICY "chat_conversations_select" ON chat_conversations FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "chat_conversations_insert" ON chat_conversations;
CREATE POLICY "chat_conversations_insert" ON chat_conversations FOR INSERT
  TO anon, authenticated WITH CHECK (true);

DROP POLICY IF EXISTS "chat_conversations_update" ON chat_conversations;
CREATE POLICY "chat_conversations_update" ON chat_conversations FOR UPDATE
  TO anon, authenticated USING (true) WITH CHECK (true);

-- chat_messages policies (anon + authenticated — public chat)
DROP POLICY IF EXISTS "chat_messages_select" ON chat_messages;
CREATE POLICY "chat_messages_select" ON chat_messages FOR SELECT
  TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "chat_messages_insert" ON chat_messages;
CREATE POLICY "chat_messages_insert" ON chat_messages FOR INSERT
  TO anon, authenticated WITH CHECK (true);

-- Add tables to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE chat_conversations;
ALTER PUBLICATION supabase_realtime ADD TABLE chat_messages;

-- Index for sorting conversations by most recent activity
CREATE INDEX IF NOT EXISTS idx_chat_conversations_updated_at ON chat_conversations (updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation_id ON chat_messages (conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_visitor_id ON chat_conversations (visitor_id);
