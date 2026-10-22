import { useEffect, useState, type ReactNode } from "react";
import { supabase } from "../lib/supabase.ts";
import { getSettings, killSwitch, type Org } from "../lib/orgs.ts";
import { StatusPill, type AutomationState } from "./StatusPill.tsx";

// The information architecture (DESIGN_SYSTEM §8). Dashboard is live; the rest
// are placeholders until their screens exist, shown disabled with a reason.
const NAV = [
  { key: "dashboard", label: "Dashboard", ready: true },
  { key: "content", label: "Content", ready: false },
  { key: "topics", label: "Topics & Voice", ready: false },
  { key: "connections", label: "Connections", ready: false },
  { key: "schedule", label: "Schedule", ready: false },
  { key: "logs", label: "Logs", ready: false },
  { key: "settings", label: "Settings", ready: false },
];

function stateFrom(s: { paused: boolean; kill_switch: boolean } | null): AutomationState {
  if (!s) return "paused";
  if (s.kill_switch) return "attention";
  if (s.paused) return "paused";
  return "active";
}

export function Shell({ org, children }: { org: Org; children: ReactNode }) {
  const [state, setState] = useState<AutomationState>("paused");
  const [announce, setAnnounce] = useState("");

  async function refresh() {
    try {
      setState(stateFrom(await getSettings(org.id)));
    } catch {
      setState("paused");
    }
  }
  useEffect(() => {
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [org.id]);

  async function onStop() {
    // Name the consequence before the verb (DESIGN_SYSTEM §5 copy rule).
    if (!window.confirm("Stop all automation for this workspace now? No posts will publish until you resume.")) return;
    try {
      await killSwitch(org.id);
      setAnnounce("Automation stopped. Nothing will publish until you resume.");
      refresh();
    } catch {
      setAnnounce("Could not stop automation. Try again.");
    }
  }

  return (
    <div style={{ minHeight: "100dvh", display: "flex", flexDirection: "column" }}>
      <header
        style={{
          display: "flex", alignItems: "center", justifyContent: "space-between", gap: "var(--space-3)",
          padding: "var(--space-3) var(--space-4)", borderBottom: "1px solid var(--border)", background: "var(--surface)",
        }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: "var(--space-3)", minWidth: 0 }}>
          <strong>Postplan</strong>
          <span className="subtle" style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {org.name}
          </span>
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: "var(--space-2)" }}>
          <StatusPill state={state} />
          <button className="btn btn-danger" onClick={onStop} style={{ minHeight: 40, padding: "6px 12px" }}>
            ■ Stop
          </button>
          <button className="btn btn-ghost" onClick={() => supabase?.auth.signOut()} style={{ minHeight: 40, padding: "6px 12px" }}>
            Sign out
          </button>
        </div>
      </header>

      <div className="shell-body" style={{ display: "flex", flex: 1, minHeight: 0 }}>
        <nav aria-label="Primary" className="shell-nav">
          {NAV.map((item) => (
            <button
              key={item.key}
              className={"nav-item" + (item.key === "dashboard" ? " nav-active" : "")}
              disabled={!item.ready}
              title={item.ready ? undefined : "Coming soon"}
            >
              {item.label}
              {!item.ready && <span className="subtle" style={{ marginLeft: 6 }}>soon</span>}
            </button>
          ))}
        </nav>

        <main style={{ flex: 1, padding: "var(--space-8) var(--space-4)", minWidth: 0 }}>
          <div style={{ maxWidth: 720, margin: "0 auto" }}>{children}</div>
        </main>
      </div>

      <div className="live" aria-live="assertive" style={{ position: "fixed", bottom: 8, left: 16 }}>
        {announce}
      </div>
    </div>
  );
}
