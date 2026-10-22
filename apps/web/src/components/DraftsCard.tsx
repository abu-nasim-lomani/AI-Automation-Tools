import { useEffect, useState } from "react";
import { listRecentPosts, publishNow, type Post, type PublishResult } from "../lib/posts.ts";

// Generated drafts, each shown as a labelled PREVIEW (never presentable as a
// real post — DESIGN_SYSTEM rule 8), with a one-click "Publish now". Publishing
// posts to the real Page, so it names the consequence and confirms first.
export function DraftsCard({ orgId }: { orgId: string }) {
  const [posts, setPosts] = useState<Post[]>([]);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ id: string; kind: "ok" | "warn" | "err"; text: string } | null>(null);

  async function refresh() {
    try {
      setPosts(await listRecentPosts(orgId));
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
        setMsg({ id: p.id, kind: "warn", text: "Sent, but the result is unconfirmed — it will be verified. Do not publish it again." });
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

  return (
    <div className="card" style={{ marginTop: "var(--space-6)" }}>
      <h2 style={{ fontSize: "var(--text-lg)", margin: "0 0 var(--space-2)" }}>Drafts</h2>

      {posts.length === 0 ? (
        <p className="muted" style={{ margin: 0 }}>
          No drafts yet. Generate a sample above, then publish it here.
        </p>
      ) : (
        <ul style={{ listStyle: "none", margin: 0, padding: 0, display: "grid", gap: "var(--space-4)" }}>
          {posts.map((p) => (
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
              ) : p.status === "draft" || p.status === "approved" ? (
                <button
                  className="btn btn-primary"
                  onClick={() => onPublish(p)}
                  disabled={busyId !== null}
                >
                  {busyId === p.id ? "Publishing…" : "Publish now"}
                </button>
              ) : (
                <p className="subtle" style={{ margin: 0 }}>{p.status}</p>
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
          ))}
        </ul>
      )}
    </div>
  );
}
