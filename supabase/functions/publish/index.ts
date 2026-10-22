/**
 * publish — the scheduled publishing job (docs/JOBS_AND_SCHEDULING.md §9,
 * ADR-018). Thin: authorise the clock, claim the next due job, and hand it to
 * the shared publish routine (core.ts), which both this and publish-now use so
 * the R4 / ADR-018 sequence lives in one place.
 *
 * Invoked by the clock with a shared trigger secret, not a user — verify_jwt is
 * false (config.toml). No secret is logged.
 */

import { Client } from "https://deno.land/x/postgres@v0.19.3/mod.ts";
import { keyringFromEnv } from "../../../packages/core/crypto/envelope.ts";
import { type FetchLike } from "../../../packages/core/meta/types.ts";
import { type ClaimedJob, processClaimedJob } from "./core.ts";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("PUBLISH_TRIGGER_SECRET");
  if (!expected || req.headers.get("x-publish-token") !== expected) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const dbUrl = Deno.env.get("SUPABASE_DB_URL");
  if (!dbUrl) return json({ ok: false, error: "SUPABASE_DB_URL missing" }, 500);

  let keyring;
  try {
    keyring = keyringFromEnv(Deno.env.toObject(), [1, 2]);
  } catch {
    return json({ ok: false, error: "master key not configured" }, 500);
  }

  const client = new Client(dbUrl);
  // A non-pooling client so no POST is sent on a reused connection (ADR-018).
  const httpClient = Deno.createHttpClient({ poolMaxIdlePerHost: 0 });
  const noReuseFetch = ((input: string | URL | Request, init?: RequestInit) =>
    fetch(input, { ...init, client: httpClient } as RequestInit)) as FetchLike;

  try {
    await client.connect();
    // claim_due_job already excludes kill_switch/paused orgs (A4).
    const claimed = await client.queryObject<ClaimedJob>("select * from app.claim_due_job()");
    const job = claimed.rows[0];
    if (!job) return json({ ok: true, published: false, reason: "no due job" });

    const summary = await processClaimedJob(client, keyring, noReuseFetch, job);
    return json({ ok: true, ...summary });
  } catch (e) {
    return json({ ok: false, error: "publish failed: " + ((e as Error).message ?? "unknown") }, 500);
  } finally {
    try { httpClient.close(); } catch { /* already closed */ }
    await client.end();
  }
});
