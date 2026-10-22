import { supabase } from "./supabase.ts";
import { invokeEdge } from "./invoke.ts";

export interface Post {
  id: string;
  body: string;
  status: "draft" | "approved" | "rejected" | "published" | "failed";
  bangla_ratio: number;
  grapheme_count: number;
  created_at: string;
  fb_post_id: string | null;
}

export async function listRecentPosts(orgId: string): Promise<Post[]> {
  const { data, error } = await supabase!
    .from("posts")
    .select("id,body,status,bangla_ratio,grapheme_count,created_at,fb_post_id")
    .eq("org_id", orgId)
    .order("created_at", { ascending: false })
    .limit(20);
  if (error) throw error;
  return (data ?? []) as Post[];
}

/** post_id → the status of its attached publish job, for posts that have one. */
export async function listJobStatusByPost(orgId: string): Promise<Record<string, string>> {
  const { data, error } = await supabase!
    .from("publish_jobs")
    .select("post_id,status")
    .eq("org_id", orgId)
    .not("post_id", "is", null);
  if (error) throw error;
  const map: Record<string, string> = {};
  for (const r of (data ?? []) as Array<{ post_id: string; status: string }>) map[r.post_id] = r.status;
  return map;
}

/**
 * Discard a stuck attempt so the post can be published again. Only for a job in
 * needs_verification, and only after the owner has confirmed the post did NOT
 * appear on the Page (the attestation of absence R4 permits).
 */
export async function discardAttempt(orgId: string, postId: string): Promise<void> {
  const { error } = await supabase!.schema("app").rpc("discard_failed_attempt", { p_org: orgId, p_post: postId });
  if (error) throw error;
}

export interface PublishResult {
  published: boolean;
  outcome: "published" | "needs_verification" | "config_fault" | "skipped";
  fb_post_id?: string;
  reason?: string;
}

/**
 * Publishes one draft to the connected Facebook Page NOW. The owner clicking
 * this is the explicit per-run instruction publishing requires (CLAUDE.md §9).
 * The server approves the draft, issues exactly one POST, and never retries.
 */
export async function publishNow(orgId: string, postId: string): Promise<PublishResult> {
  return await invokeEdge<PublishResult>("publish-now", { org_id: orgId, post_id: postId });
}
