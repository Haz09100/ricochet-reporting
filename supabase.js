import { createClient } from "@supabase/supabase-js";
import { config, supabaseConfigured } from "../config.js";

export const supabase = supabaseConfigured
  ? createClient(config.supabaseUrl, config.supabaseKey, {
      db: { schema: "public" },
      auth: {
        autoRefreshToken: true,
        persistSession: true,
        detectSessionInUrl: true,
      },
    })
  : null;

export async function currentAccessToken() {
  if (!supabase) return "";
  const { data } = await supabase.auth.getSession();
  return data.session?.access_token || "";
}
