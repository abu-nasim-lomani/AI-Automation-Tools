import { useEffect, useState } from "react";
import {
  discardAttempt,
  listJobStatusByPost,
  listRecentPosts,
  publishNow,
  type Post,
  type PublishResult,
} from "../lib/posts.ts";

// Generated drafts, each shown as a labelled PREVIEW (never presentable as a
// real post — DESIGN_SYSTEM rule 8). A draft/approved post gets "Publish now"
// (which posts to the real Page, so it confirms first). A post whose last
// attempt is stuck in needs_verification gets "Discard & retry" instead, guarded
// by an explicit attestation that it did not appear on the Page.
export function DraftsCard({ orgId }: { orgId: string }) {
  const [posts, setPosts] = useState<Post[]>([]);
  const [jobs, setJobs] = useState<Record<string, string>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ id: string; kind: "ok" | "warn" | "err"; text: string } | null>(null);

  async function refresh() {
    try {
      const [p, j] = await Promise.all([listRecentPosts(orgId), listJobStatusByPost(orgId)]);
      setPosts(p);
      setJobs(j);
    } catch {
      /* non-fatal */
    }
  }
  useEffect(() => {
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId]);

  async function onPublish(p: Post) {
    if (!confirm("This posts to your Facebook Page now. It cannot be unsent from here. Continue?")) return;
    setBusyId(p.id);
    setMsg(null);
    try {
      const r: PublishResult = await publishNow(orgId, p.id);
      if (r.published) {
        setMsg({ id: p.id, kind: "ok", text: "Published to your Page." });
      } else if (r.outcome === "needs_verification") {
        setMsg({ id: p.id, kind: "warn", text: "Sent, but the result is unconfirmed — check your Page. Do not publish it again." });
      } else {
        setMsg({ id: p.id, kind: "warn", text: r.reason || "Not published." });
      }
      refresh();
    } catch (err) {
      setMsg({ id: p.id, kind: "err", text: (err as Error).message || "Could not publish." });
    } finally {
      setBusyId(null);
    }
  }

  async function onDiscard(p: Post) {
    if (!confirm("Only do this if you have checked your Page and this post did NOT appear there. Discard the failed attempt so you can publish again?")) return;
    setBusyId(p.id);
    setMsg(null);
    try {
      await discardAttempt(orgId, p.id);
      setMsg({ id: p.id, kind: "ok", text: "Discarded. You can publish this again." });
      refresh();
    } catch (err) {
      setMsg({ id: p.id, kind: "err", text: (err as Error).message || "Could not discard." });
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="card" style={{ marginTop: "var(--space-6)" }}>
      <h2 style={{ fontSize: "var(--text-lg)", margin: "0 0 var(--space-2)" }}>Drafts</h2>

      {posts.length === 0 ? (
        <p className="muted" style={{ margin: 0 }}>
          No drafts yet. Generate a sample above, then publish it here.
        </p>
      ) : (
        <ul style={{ listStyle: "none", margin: 0, padding: 0, display: "grid", gap: "var(--space-4)" }}>
          {posts.map((p) => {
            const jobStatus = jobs[p.id];
            const stuck = jobStatus === "needs_verification";
            const canPublish = !stuck && (p.status === "draft" || p.status === "approved") && !jobStatus;
            return (
              <li key={p.id} style={{ border: "1px solid var(--border)", borderRadius: "var(--radius-md)", padding: "var(--space-4)" }}>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: "var(--space-2)" }}>
                  <span className="subtle" style={{ textTransform: "uppercase", letterSpacing: "0.04em", fontSize: "var(--text-xs)" }}>
                    Preview · {p.status}
                  </span>
                  <span className="subtle" style={{ fontSize: "var(--text-xs)" }}>
                    {p.grapheme_count} chars · {Math.round(p.bangla_ratio * 100)}% Bangla
                  </span>
                </div>

                <p lang="bn" style={{ margin: "0 0 var(--space-3)", lineHeight: 1.75, whiteSpace: "pre-wrap" }}>
                  {p.body}
                </p>

                {p.status === "published" ? (
                  <p className="subtle" style={{ margin: 0, color: "var(--success)" }}>
                    ✓ Published{p.fb_post_id ? ` · ${p.fb_post_id}` : ""}
                  </p>
                ) : stuck ? (
                  <>
                    <p className="subtle" style={{ margin: "0 0 var(--space-2)" }}>
                      A previous attempt could not be confirmed. Check your Page; if it is not there, discard it to try again.
                    </p>
                    <button className="btn btn-ghost" onClick={() => onDiscard(p)} disabled={busyId !== null}>
                      {busyId === p.id ? "Discarding…" : "Discard & retry"}
                    </button>
                  </>
                ) : canPublish ? (
                  <button className="btn btn-primary" onClick={() => onPublish(p)} disabled={busyId !== null}>
                    {busyId === p.id ? "Publishing…" : "Publish now"}
                  </button>
                ) : (
                  <p className="subtle" style={{ margin: 0 }}>{jobStatus ?? p.status}</p>
                )}

                {msg && msg.id === p.id && (
                  <p
                    className="subtle"
                    style={{
                      marginTop: "var(--space-2)",
                      color: msg.kind === "err" ? "var(--danger)" : msg.kind === "warn" ? "var(--warning, var(--danger))" : "var(--success)",
                    }}
                  >
                    {msg.text}
                  </p>
                )}
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}
