import { useEffect, useState, type FormEvent } from "react";
import { addTopic, generateSample, listTopics, type SampleResult, type Topic } from "../lib/topics.ts";

// Add topics to write about, and generate one sample draft on demand. This is
// the last onboarding piece before a post exists.
export function TopicsCard({ orgId }: { orgId: string }) {
  const [topics, setTopics] = useState<Topic[]>([]);
  const [title, setTitle] = useState("");
  const [instructions, setInstructions] = useState("");
  const [adding, setAdding] = useState(false);
  const [sampling, setSampling] = useState(false);
  const [sample, setSample] = useState<SampleResult | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function refresh() {
    try { setTopics(await listTopics(orgId)); } catch { /* non-fatal */ }
  }
  useEffect(() => { refresh(); /* eslint-disable-next-line */ }, [orgId]);

  async function onAdd(e: FormEvent) {
    e.preventDefault();
    setAdding(true); setErr(null);
    try {
      await addTopic(orgId, title, instructions);
      setTitle(""); setInstructions("");
      refresh();
    } catch {
      setErr("Could not add the topic.");
    } finally {
      setAdding(false);
    }
  }

  async function onSample() {
    setSampling(true); setErr(null); setSample(null);
    try {
      setSample(await generateSample(orgId));
    } catch (e) {
      setErr((e as Error).message || "Could not generate a sample.");
    } finally {
      setSampling(false);
    }
  }

  return (
    <div className="card" style={{ marginTop: "var(--space-6)" }}>
      <h2 style={{ fontSize: "var(--text-lg)", margin: "0 0 var(--space-2)" }}>Topics</h2>

      {topics.length > 0 ? (
        <ul className="muted" style={{ margin: "0 0 var(--space-4)", paddingLeft: "var(--space-6)", lineHeight: 1.9 }}>
          {topics.map((t) => <li key={t.id} lang="bn">{t.title}</li>)}
        </ul>
      ) : (
        <p className="muted" style={{ marginBottom: "var(--space-4)" }}>
          Add at least one thing to write about — a theme, not a single post.
        </p>
      )}

      <form onSubmit={onAdd} className="field" style={{ marginBottom: "var(--space-4)" }} noValidate>
        <label htmlFor="topic">New topic</label>
        <input id="topic" value={title} lang="bn" onChange={(e) => setTitle(e.target.value)}
               placeholder="যেমন: ধৈর্য ও অধ্যবসায়" disabled={adding} />
        <button type="submit" className="btn btn-ghost" style={{ marginTop: "var(--space-2)" }}
                disabled={adding || title.trim() === ""}>
          {adding ? "Adding…" : "Add topic"}
        </button>
      </form>

      <div style={{ borderTop: "1px solid var(--border)", paddingTop: "var(--space-4)" }}>
        <button className="btn btn-primary" onClick={onSample}
                disabled={sampling || topics.length === 0}
                title={topics.length === 0 ? "Add a topic first" : undefined}>
          {sampling ? "Writing…" : "Generate a sample"}
        </button>
        {topics.length === 0 && <p className="subtle" style={{ marginTop: 6 }}>Add a topic first.</p>}

        {err && <p className="subtle" style={{ color: "var(--danger)", marginTop: "var(--space-3)" }}>{err}</p>}

        {sample && (
          <div style={{ marginTop: "var(--space-4)" }}>
            <div className="subtle" style={{ marginBottom: 6 }}>
              {sample.accepted ? "✓ passed the critic" : "⚠ saved as a draft, flagged"} · {sample.provider}
            </div>
            <div className="card" lang="bn" style={{ background: "var(--surface-raised)", whiteSpace: "pre-wrap" }}>
              {sample.body}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
