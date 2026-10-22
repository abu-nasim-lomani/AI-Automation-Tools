import { useState, type FormEvent } from "react";
import { createOrg } from "../lib/orgs.ts";

// First run: a signed-in user with no workspace creates one. This is the first
// step of the onboarding journey (DESIGN_SYSTEM §8).
export function CreateWorkspace({ onCreated }: { onCreated: () => void }) {
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await createOrg(name.trim());
      onCreated();
    } catch {
      setError("Could not create the workspace. Please try again.");
      setBusy(false);
    }
  }

  return (
    <div className="centered">
      <div className="card" style={{ maxWidth: 440, width: "100%" }}>
        <h1 style={{ fontSize: "var(--text-2xl)", margin: "0 0 var(--space-1)" }}>Create your workspace</h1>
        <p className="muted" style={{ marginBottom: "var(--space-6)" }}>
          A workspace holds your Page, your schedule and your drafts. You can rename it later.
        </p>
        <form onSubmit={onSubmit} className="field" noValidate>
          <label htmlFor="ws">Workspace name</label>
          <input
            id="ws"
            type="text"
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. You Know MD Abu Nasim"
            aria-describedby={error ? "wserr" : undefined}
            disabled={busy}
            autoFocus
          />
          {error && (
            <p id="wserr" className="subtle" style={{ color: "var(--danger)", marginTop: 6 }}>
              {error}
            </p>
          )}
          <button
            type="submit"
            className="btn btn-primary"
            style={{ width: "100%", marginTop: "var(--space-4)" }}
            disabled={busy || name.trim() === ""}
          >
            {busy ? "Creating…" : "Create workspace"}
          </button>
        </form>
      </div>
    </div>
  );
}
