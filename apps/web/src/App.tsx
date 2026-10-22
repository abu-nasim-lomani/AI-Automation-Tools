import { useEffect, useState } from "react";
import { Navigate, Route, Routes } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";

import { configured, supabase } from "./lib/supabase.ts";
import { Login } from "./routes/Login.tsx";
import { Home } from "./routes/Home.tsx";

export function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);

  useEffect(() => {
    if (!supabase) {
      setReady(true);
      return;
    }
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_event, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  // A misconfigured build should say so plainly, not show a broken login.
  if (!configured) {
    return (
      <div className="centered">
        <div className="card" style={{ maxWidth: 420 }}>
          <h1 style={{ fontSize: "var(--text-xl)", margin: "0 0 var(--space-2)" }}>Not configured</h1>
          <p className="muted">
            Set <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> in{" "}
            <code>apps/web/.env</code>, then restart the dev server. Both are public values.
          </p>
        </div>
      </div>
    );
  }

  if (!ready) {
    return (
      <div className="centered">
        <p className="subtle">Loading…</p>
      </div>
    );
  }

  return (
    <Routes>
      <Route path="/login" element={session ? <Navigate to="/" replace /> : <Login />} />
      <Route path="/" element={session ? <Home session={session} /> : <Navigate to="/login" replace />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
