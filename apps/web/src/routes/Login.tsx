import { useState, type FormEvent } from "react";
import { supabase } from "../lib/supabase.ts";

type Status = { kind: "idle" | "sending" | "sent" | "error"; message?: string };

// Passwordless sign-in: the owner enters their email and receives a magic link.
// No password to store or leak, which suits a single-owner S1.
export function Login() {
  const [email, setEmail] = useState("");
  const [status, setStatus] = useState<Status>({ kind: "idle" });

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (!supabase) return;
    setStatus({ kind: "sending" });
    const { error } = await supabase.auth.signInWithOtp({
      email: email.trim(),
      options: { emailRedirectTo: window.location.origin },
    });
    if (error) {
      // Say what to do next; never surface a raw upstream message (CLAUDE.md §8).
      setStatus({ kind: "error", message: "Could not send the link. Check the address and try again." });
    } else {
      setStatus({ kind: "sent" });
    }
  }

  const sending = status.kind === "sending";

  return (
    <div className="centered">
      <div className="card" style={{ maxWidth: 400, width: "100%" }}>
        <h1 style={{ fontSize: "var(--text-2xl)", margin: "0 0 var(--space-1)" }}>Postplan</h1>
        <p className="muted" style={{ marginBottom: "var(--space-6)" }}>
          Sign in with your email. We send a one-time link — no password.
        </p>

        {status.kind === "sent" ? (
          <p role="status">
            Check <strong>{email}</strong> for a sign-in link. You can close this tab.
          </p>
        ) : (
          <form onSubmit={onSubmit} className="field" noValidate>
            <label htmlFor="email">Email</label>
            <input
              id="email"
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              aria-describedby={status.kind === "error" ? "err" : undefined}
              disabled={sending}
            />
            {status.kind === "error" && (
              <p id="err" className="subtle" style={{ color: "var(--danger)", marginTop: 6 }}>
                {status.message}
              </p>
            )}
            <button
              type="submit"
              className="btn btn-primary"
              style={{ width: "100%", marginTop: "var(--space-4)" }}
              disabled={sending || email.trim() === ""}
            >
              {sending ? "Sending…" : "Send sign-in link"}
            </button>
          </form>
        )}

        <div className="live" aria-live="polite" style={{ marginTop: "var(--space-3)" }}>
          {sending ? "Sending your sign-in link…" : ""}
        </div>
      </div>
    </div>
  );
}
