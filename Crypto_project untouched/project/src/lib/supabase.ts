import { createClient } from '@supabase/supabase-js';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from '@/lib/supabaseEnv';

// VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY are read and normalised in one
// place (@/lib/supabaseEnv) so the realtime client and the admin-chat edge
// function can never disagree about the project URL.
const supabaseUrl = SUPABASE_URL;
const supabaseAnonKey = SUPABASE_ANON_KEY;

export const supabase = createClient(supabaseUrl, supabaseAnonKey, {
  realtime: {
    params: { eventsPerSecond: 10 },
  },
});
