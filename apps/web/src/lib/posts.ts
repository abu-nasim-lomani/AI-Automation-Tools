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
