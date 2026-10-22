import { supabase } from "./supabase.ts";
import { invokeEdge } from "./invoke.ts";

export interface Topic {
  id: string;
  title: string;
  instructions: string | null;
  enabled: boolean;
}

export async function listTopics(orgId: string): Promise<Topic[]> {
  const { data, error } = await supabase!
    .from("topics")
    .select("id,title,instructions,enabled")
    .eq("org_id", orgId)
    .order("created_at", { ascending: true });
  if (error) throw error;
  return (data ?? []) as Topic[];
}

export async function addTopic(orgId: string, title: string, instructions: string): Promise<void> {
  const { error } = await supabase!.from("topics").insert({
    org_id: orgId,
    title: title.trim(),
    instructions: instructions.trim() || null,
  });
  if (error) throw error;
}

export interface SampleResult {
  post_id: string;
  accepted: boolean;
  provider: string;
  body: string;
}

/** Ask the generate-now function for one draft, on demand. */
export async function generateSample(orgId: string): Promise<SampleResult> {
  return await invokeEdge<SampleResult>("generate-now", { org_id: orgId });
}
