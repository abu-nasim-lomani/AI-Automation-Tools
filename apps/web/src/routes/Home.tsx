import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabase.ts";
import { StatusPill } from "../components/StatusPill.tsx";

// A minimal authenticated landing. The real shell (sidebar, screens) is built
// on top of this; for now it proves sign-in works end to end and shows the two
// components that must appear on every screen: the status pill and the stop.
export function Home({ session }: { session: Session }) {
  async function signOut() {
    await supabase?.auth.signOut();
  }

  return (
    <div style={{ minHeight: "100dvh", display: "flex", flexDirection: "column" }}>
      <header
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: "var(--space-4)",
          padding: "var(--space-3) var(--space-4)",
          borderBottom: "1px solid var(--border)",
          background: "var(--surface)",
        }}
      >
        <strong>Postplan</strong>
        <div style={{ display: "flex", alignItems: "center", gap: "var(--space-3)" }}>
          <StatusPill state="paused" />
          <button className="btn btn-ghost" onClick={signOut}>Sign out</button>
        </div>
      </header>

      <main style={{ padding: "var(--space-8) var(--space-4)", maxWidth: 720, margin: "0 auto", width: "100%" }}>
        <h1 style={{ fontSize: "var(--text-2xl)", margin: "0 0 var(--space-2)" }}>You're signed in</h1>
        <p className="muted">
          Signed in as <strong>{session.user.email}</strong>. The dashboard, onboarding and content
          screens are built from here next.
        </p>

        <div className="card" style={{ marginTop: "var(--space-6)" }}>
          <h2 style={{ fontSize: "var(--text-lg)", margin: "0 0 var(--space-2)" }}>What's next</h2>
          <ul className="muted" style={{ margin: 0, paddingLeft: "var(--space-6)", lineHeight: 1.9 }}>
            <li>Onboarding: connect a Page, add your AI key, set topics and voice</li>
            <li>Daily queue: review, edit, approve or reject drafts</li>
            <li>The automation status pill and emergency stop, on every screen</li>
          </ul>
        </div>
      </main>
    </div>
  );
}
