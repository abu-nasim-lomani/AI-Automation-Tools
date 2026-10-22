/**
 * publish-now — the owner publishes one chosen draft on demand (the "publish
 * now" button). The on-demand twin of the scheduled publish: it enqueues a job
 * for the post (approving the draft — clicking publish IS the approval) and runs
 * it through the SAME shared publish routine, so R4 / ADR-018 hold unchanged.
 *
 * User-authenticated and owner-only (enforced in the database). It is the
 * explicit per-run instruction CLAUDE.md §9 requires before anything is posted
 * to Facebook.
 */

import { Client } from "https://deno.land/x/postgres@v0.19.3/mod.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.45.4";
import { keyringFromEnv } from "../../../packages/core/crypto/envelope.ts";
import { type FetchLike } from "../../../packages/core/meta/types.ts";
import { type ClaimedJob, processClaimedJob } from "../publish/core.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ ok: false, error: "missing authorization" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const dbUrl = Deno.env.get("SUPABASE_DB_URL");
  if (!url || !anon || !dbUrl) return json({ ok: false, error: "server not configured" }, 500);

  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: u, error: uErr } = await userClient.auth.getUser();
  if (uErr || !u.user) return json({ ok: false, error: "invalid session" }, 401);
  const actor = u.user.id;

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "invalid body" }, 400); }
  for (const k of ["actor_id", "user_id", "sub", "org_role"]) {
    if (k in body) return json({ ok: false, error: `unexpected field: ${k}` }, 400);
  }
  const orgId = String(body.org_id ?? "");
  const postId = String(body.post_id ?? "");
  if (!orgId || !postId) return json({ ok: false, error: "org_id and post_id are required" }, 400);

  let keyring;
  try { keyring = keyringFromEnv(Deno.env.toObject(), [1, 2]); }
  catch { return json({ ok: false, error: "master key not configured" }, 500); }

  const client = new Client(dbUrl);
  const httpClient = Deno.createHttpClient({ poolMaxIdlePerHost: 0 }); // ADR-018
  const noReuseFetch = ((input: string | URL | Request, init?: RequestInit) =>
    fetch(input, { ...init, client: httpClient } as RequestInit)) as FetchLike;

  try {
    await client.connect();

    // Enqueue a due job for this post (owner-checked in the DB; approves a draft).
    let jobId: string;
    try {
      const enq = await client.queryObject<{ id: string }>(
        "select app.enqueue_manual_publish($1::uuid,$2::uuid,$3::uuid) as id",
        [actor, orgId, postId],
      );
      jobId = enq.rows[0]!.id;
    } catch (e) {
      const code = (e as { fields?: { code?: string } }).fields?.code;
      let msg = "could not queue this post";
      if (code === "42501") msg = "you are not an owner of this workspace";
      else if (code === "P0002") msg = "that draft was not found";
      else if (code === "22023") msg = "this post cannot be published (already published or rejected)";
      else if (code === "23505") msg = "this post is already queued or published";
      return json({ ok: false, error: msg }, 400);
    }

    // Claim exactly that job. If it will not claim, the org is stopped.
    const claimed = await client.queryObject<ClaimedJob>("select * from app.claim_job($1::uuid)", [jobId]);
    const job = claimed.rows[0];
    if (!job) return json({ ok: false, error: "publishing is paused or stopped for this workspace" }, 409);

    const summary = await processClaimedJob(client, keyring, noReuseFetch, job);
    return json({ ok: true, ...summary });
  } catch (e) {
    return json({ ok: false, error: "publish failed: " + ((e as Error).message ?? "unknown") }, 500);
  } finally {
    try { httpClient.close(); } catch { /* already closed */ }
    await client.end();
  }
});
