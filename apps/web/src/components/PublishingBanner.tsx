import { useEffect, useState } from "react";
import { getSettings, resumePublishing } from "../lib/orgs.ts";

// Shown only when publishing is paused (e.g. a configuration fault stopped it),
// with a one-click Resume — so recovering never needs a database edit.
export function PublishingBanner({ orgId }: { orgId: string }) {
  const [paused, setPaused] = useState(false);
  const [busy, setBusy] = useState(false);

  async function refresh() {
    try {
      const s = await getSettings(orgId);
      setPaused(s.paused);
    } catch {
      /* non-fatal */
    }
  }
  useEffect(() => {
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [orgId]);

  if (!paused) return null;

  async function onResume() {
    setBusy(true);
    try {
      await resumePublishing(orgId);
      await refresh();
    } finally {
      setBusy(false);
    }
  }

  return (
    <div
      role="status"
      className="card"
      style={{ borderColor: "var(--warning, var(--danger))", marginTop: "var(--space-4)" }}
    >
      <strong>Publishing is paused.</strong>{" "}
      <span className="muted">
        A publish attempt hit a configuration problem, so publishing was stopped. If it was a Page
        token problem, reconnect your Page above, then resume.
      </span>
      <div style={{ marginTop: "var(--space-3)" }}>
        <button className="btn btn-primary" onClick={onResume} disabled={busy}>
          {busy ? "Resuming…" : "Resume publishing"}
        </button>
      </div>
    </div>
  );
}
