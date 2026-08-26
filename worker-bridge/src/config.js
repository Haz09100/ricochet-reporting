export const config = Object.freeze({
  supabaseUrl: String(import.meta.env.VITE_SUPABASE_URL || "").trim().replace(/\/$/, ""),
  supabaseKey: String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || "").trim(),
  workerUrl: String(import.meta.env.VITE_WORKER_BASE_URL || "").trim().replace(/\/$/, ""),
  demoMode: String(import.meta.env.VITE_DEMO_MODE || "").toLowerCase() === "true",
  autoRefreshSeconds: Math.max(30, Math.min(600, Number(import.meta.env.VITE_AUTO_REFRESH_SECONDS || 60))),
});

export const supabaseConfigured = Boolean(config.supabaseUrl && config.supabaseKey);
