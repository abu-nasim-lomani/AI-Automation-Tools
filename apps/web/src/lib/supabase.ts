import { createClient } from "@supabase/supabase-js";

// Both values are public by design: the anon key is meant to run in the
// browser, and RLS — not secrecy — is the control (docs/SECURITY.md). This app
// never holds a service-role key.
const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const configured = Boolean(url && anonKey);

// A real client when configured; otherwise a stub so the app renders a clear
// "not configured" message instead of crashing on a missing env var.
export const supabase = configured
  ? createClient(url as string, anonKey as string)
  : null;
