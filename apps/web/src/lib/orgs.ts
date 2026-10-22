import { supabase } from "./supabase.ts";

export interface Org {
  id: string;
  name: string;
  region: "bd" | "global" | "eu_uk";
}

export interface OrgSettings {
  paused: boolean;
  kill_switch: boolean;
}

/** The orgs the signed-in user can see — RLS returns only their own. */
export async function listOrgs(): Promise<Org[]> {
  const { data, error } = await supabase!
    .from("orgs")
    .select("id,name,region")
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data ?? []) as Org[];
}

/** Create a workspace via the app-schema RPC (exposed to the API). */
export async function createOrg(name: string): Promise<string> {
  const { data, error } = await supabase!.schema("app").rpc("create_org", { p_name: name });
  if (error) throw error;
  return data as string;
}

export async function getSettings(orgId: string): Promise<OrgSettings> {
  const { data, error } = await supabase!
    .from("org_settings")
    .select("paused,kill_switch")
    .eq("org_id", orgId)
    .single();
  if (error) throw error;
  return data as OrgSettings;
}

/** The emergency stop — any member may do it (SECURITY.md §7.1). */
export async function killSwitch(orgId: string): Promise<void> {
  const { error } = await supabase!
    .from("org_settings")
    .update({ kill_switch: true })
    .eq("org_id", orgId);
  if (error) throw error;
}

/** Resume after a pause (e.g. a configuration fault stopped publishing). The
 *  same member-only surface as the emergency stop (org_settings_stop policy). */
export async function resumePublishing(orgId: string): Promise<void> {
  const { error } = await supabase!
    .from("org_settings")
    .update({ paused: false })
    .eq("org_id", orgId);
  if (error) throw error;
}
