import { supabase } from "./supabase.ts";
import { invokeEdge } from "./invoke.ts";

// Column-restricted by grant: the ciphertext is never selectable (SEC-16).
export interface Credential {
  id: string;
  provider: "gemini" | "groq";
  model: string;
  tier: "unpaid" | "paid";
  masked_hint: string;
  status: "unvalidated" | "valid" | "invalid";
  is_default: boolean;
}

export async function listCredentials(orgId: string): Promise<Credential[]> {
  const { data, error } = await supabase!
    .from("provider_credentials")
    .select("id,provider,model,tier,masked_hint,status,is_default")
    .eq("org_id", orgId)
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data ?? []) as Credential[];
}

export interface WriteKeyInput {
  orgId: string;
  provider: "gemini" | "groq";
  model: string;
  tier: "unpaid" | "paid";
  apiKey: string;
}

/**
 * Sends the key to the write-credential Edge Function, which encrypts it
 * server-side. The plaintext key leaves the browser only over TLS to our own
 * function and is never stored or logged here.
 */
export async function writeKey(input: WriteKeyInput): Promise<{ masked_hint: string }> {
  const data = await invokeEdge<{ masked_hint: string }>("write-credential", {
    org_id: input.orgId,
    provider: input.provider,
    model: input.model,
    tier: input.tier,
    api_key: input.apiKey,
  });
  return { masked_hint: data.masked_hint };
}
