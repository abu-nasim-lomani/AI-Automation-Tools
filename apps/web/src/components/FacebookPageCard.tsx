import { useEffect, useState, type FormEvent } from "react";
import { connectPage, listPages, type SocialAccount } from "../lib/social.ts";

// Connect a Facebook Page. The token input is masked with a reveal toggle WHILE
// typing (before save); after save there is nothing to reveal — no endpoint
// returns a stored token — so only the connected Page is shown
// (DESIGN_SYSTEM §4.1, rule 7). Owner-only is enforced in the database (R11);
// a non-owner's attempt returns a clear error rather than being hidden here.
export function FacebookPageCard({ orgId }: { orgId: string }) {
  const [pages, setPages] = useState<SocialAccount[]>([]);
  const [externalId, setExternalId] = useState("");
  const [displayName, setDisplayName] = useState("");
  const [token, setToken] = useState("");
  const [reveal, setReveal] = useState(false);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ kind: "ok" | "err"; text: string } | null>(null);

  async function refresh() {
    try {
      setPages(await listPages(orgId));
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
      const { masked_hint } = await connectPage({
        orgId,
        externalId: externalId.trim(),
        displayName: displayName.trim(),
        pageToken: token.trim(),
      });
      setToken("");
      setReveal(false);
      setMsg({ kind: "ok", text: `Connected. Token stored as ${masked_hint}.` });
      refresh();
    } catch (err) {
      setMsg({ kind: "err", text: (err as Error).message || "Could not connect the Page." });
    } finally {
      setBusy(false);
    }
  }

  const active = pages.filter((p) => p.status !== "revoked");

  return (
    <div className="card" style={{ marginTop: "var(--space-6)" }}>
      <h2 style={{ fontSize: "var(--text-lg)", margin: "0 0 var(--space-2)" }}>Facebook Page</h2>

      {active.length > 0 ? (
        <ul className="muted" style={{ margin: "0 0 var(--space-4)", paddingLeft: "var(--space-6)", lineHeight: 1.9 }}>
          {active.map((p) => (
            <li key={p.id}>
              <strong>{p.display_name}</strong> · <code>{p.external_id}</code> · {p.status}
            </li>
          ))}
        </ul>
      ) : (
        <p className="muted" style={{ marginBottom: "var(--space-4)" }}>
          No Page yet. Connect the Page you want to publish to. The access token is encrypted before
          it is stored, and no screen ever shows it again. Publishing stays off until you arm it.
        </p>
      )}

      <form onSubmit={onSubmit} className="field" noValidate>
        <label htmlFor="pageid">Page ID</label>
        <input
          id="pageid"
          type="text"
          inputMode="numeric"
          value={externalId}
          onChange={(e) => setExternalId(e.target.value)}
          placeholder="e.g. 1234567890"
          autoComplete="off"
          spellCheck={false}
          disabled={busy}
        />

        <label htmlFor="pagename" style={{ marginTop: "var(--space-3)" }}>Page name</label>
        <input
          id="pagename"
          type="text"
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
          placeholder="e.g. You Know MD Abu Nasim"
          autoComplete="off"
          disabled={busy}
        />

        <label htmlFor="pagetoken" style={{ marginTop: "var(--space-3)" }}>Page access token</label>
        <div style={{ display: "flex", gap: "var(--space-2)" }}>
          <input
            id="pagetoken"
            type={reveal ? "text" : "password"}
            value={token}
            onChange={(e) => setToken(e.target.value)}
            autoComplete="off"
            spellCheck={false}
            disabled={busy}
            aria-describedby={msg ? "pagemsg" : undefined}
          />
          <button type="button" className="btn btn-ghost" onClick={() => setReveal((r) => !r)} aria-pressed={reveal}>
            {reveal ? "Hide" : "Show"}
          </button>
        </div>

        {msg && (
          <p id="pagemsg" className="subtle" style={{ marginTop: 6, color: msg.kind === "err" ? "var(--danger)" : "var(--success)" }}>
            {msg.text}
          </p>
        )}

        <button
          type="submit"
          className="btn btn-primary"
          style={{ marginTop: "var(--space-3)" }}
          disabled={busy || externalId.trim() === "" || displayName.trim() === "" || token.trim() === ""}
        >
          {busy ? "Connecting…" : active.length > 0 ? "Reconnect Page" : "Connect Page"}
        </button>
      </form>
    </div>
  );
}
