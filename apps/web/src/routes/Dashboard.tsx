import type { Org } from "../lib/orgs.ts";
import { AiKeyCard } from "../components/AiKeyCard.tsx";
import { TopicsCard } from "../components/TopicsCard.tsx";
import { FacebookPageCard } from "../components/FacebookPageCard.tsx";

// Placeholder dashboard content, inside the shell. The real tiles (buffer,
// today's queue, quota) arrive with the content screens.
export function Dashboard({ org, email }: { org: Org; email: string }) {
  return (
    <>
      <h1 style={{ fontSize: "var(--text-2xl)", margin: "0 0 var(--space-2)" }}>Dashboard</h1>
      <p className="muted">
        Workspace <strong>{org.name}</strong> · signed in as {email}. Automation is paused until you
        finish setup and arm it.
      </p>

      <AiKeyCard orgId={org.id} />
      <TopicsCard orgId={org.id} />
      <FacebookPageCard orgId={org.id} />

      <div className="card" style={{ marginTop: "var(--space-6)" }}>
        <h2 style={{ fontSize: "var(--text-lg)", margin: "0 0 var(--space-3)" }}>Finish setting up</h2>
        <ol className="muted" style={{ margin: 0, paddingLeft: "var(--space-6)", lineHeight: 2 }}>
          <li>Add your AI provider key (Gemini) — <span className="subtle">next</span></li>
          <li>Add a few topics to write about</li>
          <li>Set your voice and language ratio</li>
          <li>Connect your Facebook Page</li>
          <li>Set the schedule, generate samples, then arm automation</li>
        </ol>
      </div>
    </>
  );
}
