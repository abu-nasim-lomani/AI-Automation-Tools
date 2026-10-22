import { useCallback, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";

import { configured, supabase } from "./lib/supabase.ts";
import { listOrgs, type Org } from "./lib/orgs.ts";
import { Login } from "./routes/Login.tsx";
import { CreateWorkspace } from "./routes/Workspace.tsx";
import { Shell } from "./components/Shell.tsx";
import { Dashboard } from "./routes/Dashboard.tsx";

type OrgState = { loading: boolean; orgs: Org[] };

export function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [orgState, setOrgState] = useState<OrgState>({ loading: true, orgs: [] });

  useEffect(() => {
    if (!supabase) {
      setAuthReady(true);
      return;
    }
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setAuthReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const loadOrgs = useCallback(async () => {
    if (!supabase || !session) return;
    setOrgState({ loading: true, orgs: [] });
    try {
      setOrgState({ loading: false, orgs: await listOrgs() });
    } catch {
      setOrgState({ loading: false, orgs: [] });
    }
  }, [session]);

  useEffect(() => {
    if (session) loadOrgs();
  }, [session, loadOrgs]);

  if (!configured) {
    return (
      <div className="centered">
        <div className="card" style={{ maxWidth: 420 }}>
          <h1 style={{ fontSize: "var(--text-xl)", margin: "0 0 var(--space-2)" }}>Not configured</h1>
          <p className="muted">
            Set <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> in{" "}
            <code>apps/web/.env</code>, then restart. Both are public values.
          </p>
        </div>
      </div>
    );
  }

  if (!authReady) return <Centered>Loading…</Centered>;
  if (!session) return <Login />;
  if (orgState.loading) return <Centered>Loading your workspace…</Centered>;

  const email = session.user.email ?? "";
  if (orgState.orgs.length === 0) return <CreateWorkspace onCreated={loadOrgs} />;

  const org = orgState.orgs[0];
  return (
    <Shell org={org}>
      <Dashboard org={org} email={email} />
    </Shell>
  );
}

function Centered({ children }: { children: React.ReactNode }) {
  return (
    <div className="centered">
      <p className="subtle">{children}</p>
    </div>
  );
}
