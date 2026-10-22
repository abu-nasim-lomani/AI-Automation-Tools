import { useEffect, useState, type FormEvent } from "react";
import { listCredentials, writeKey, type Credential } from "../lib/credentials.ts";

// Add an AI provider key. The input is masked with a reveal toggle WHILE typing
// (before save); after save there is nothing to reveal — no endpoint returns a
// stored key — so only the mask is shown (DESIGN_SYSTEM §4.1, rule 7).
export function AiKeyCard({ orgId }: { orgId: string }) {
  const [creds, setCreds] = useState<Credential[]>([]);
  const [apiKey, setApiKey] = useState("");
  const [reveal, setReveal] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ kind: "ok" | "err"; text: string } | null>(null);

  async function refresh() {
    try {
      setCreds(await listCredentials(orgId));
    } catch {
      /* listing failure is non-fatal here */
    }
  }
  useEffect(() => {
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId]);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setMsg(null);
    try {
      const { masked_hint } = await writeKey({
        orgId,
        provider: "gemini",
        model: "gemini-2.0-flash",
        tier: "unpaid",
        apiKey: apiKey.trim(),
      });
      setApiKey("");
      setReveal(false);
      setMsg({ kind: "ok", text: `Saved. Stored as ${masked_hint}.` });
      refresh();
    } catch (err) {
      setMsg({ kind: "err", text: (err as Error).message || "Could not store the key." });
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="card" style={{ marginTop: "var(--space-6)" }}>
      <h2 style={{ fontSize: "var(--text-lg)", margin: "0 0 var(--space-2)" }}>AI provider key</h2>

      {creds.length > 0 ? (
        <ul className="muted" style={{ margin: "0 0 var(--space-4)", paddingLeft: "var(--space-6)", lineHeight: 1.9 }}>
          {creds.map((c) => (
            <li key={c.id}>
              {c.provider} · <code>{c.masked_hint}</code> · {c.status}
              {c.is_default && " · default"}
            </li>
          ))}
        </ul>
      ) : (
        <p className="muted" style={{ marginBottom: "var(--space-4)" }}>
          No key yet. Paste your Gemini key — it is encrypted before it is stored, and no screen ever
          shows it again.
        </p>
      )}

      <form onSubmit={onSubmit} className="field" noValidate>
        <label htmlFor="key">Gemini API key</label>
        <div style={{ display: "flex", gap: "var(--space-2)" }}>
          <input
            id="key"
            type={reveal ? "text" : "password"}
            value={apiKey}
            onChange={(e) => setApiKey(e.target.value)}
            autoComplete="off"
            spellCheck={false}
            disabled={busy}
            aria-describedby={msg ? "keymsg" : undefined}
          />
          <button type="button" className="btn btn-ghost" onClick={() => setReveal((r) => !r)} aria-pressed={reveal}>
            {reveal ? "Hide" : "Show"}
          </button>
        </div>
        {msg && (
          <p id="keymsg" className="subtle" style={{ marginTop: 6, color: msg.kind === "err" ? "var(--danger)" : "var(--success)" }}>
            {msg.text}
          </p>
        )}
        <button type="submit" className="btn btn-primary" style={{ marginTop: "var(--space-3)" }} disabled={busy || apiKey.trim() === ""}>
          {busy ? "Saving…" : creds.length > 0 ? "Replace key" : "Save key"}
        </button>
      </form>
    </div>
  );
}
