import { supabase } from "./supabase.ts";
import { invokeEdge } from "./invoke.ts";

// Column-restricted by grant: the token ciphertext is never selectable (SEC-16).
export interface SocialAccount {
  id: string;
  platform: "facebook_page";
  external_id: string;
  display_name: string;
  granted_tasks: string[];
  status: "active" | "reauth_required" | "revoked";
  token_checked_at: string | null;
}

export async function listPages(orgId: string): Promise<SocialAccount[]> {
  const { data, error } = await supabase!
    .from("social_accounts")
    .select("id,platform,external_id,display_name,granted_tasks,status,token_checked_at")
    .eq("org_id", orgId)
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data ?? []) as SocialAccount[];
}

export interface ConnectPageInput {
  orgId: string;
  externalId: string;   // the Page ID (numbers only)
  displayName: string;  // the Page name
  pageToken: string;    // a Page access token
}

/**
 * Sends the Page token to the write-social-account Edge Function, which
 * encrypts it server-side. The plaintext token leaves the browser only over
 * TLS to our own function and is never stored or logged here.
 */
export async function connectPage(input: ConnectPageInput): Promise<{ masked_hint: string }> {
  const data = await invokeEdge<{ masked_hint: string }>("write-social-account", {
    org_id: input.orgId,
    external_id: input.externalId,
    display_name: input.displayName,
    page_token: input.pageToken,
  });
  return { masked_hint: data.masked_hint };
}
