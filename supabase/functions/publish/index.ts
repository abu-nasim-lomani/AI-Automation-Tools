/**
 * publish — the publishing job (docs/JOBS_AND_SCHEDULING.md §9, ADR-018).
 *
 * Thin glue over tested parts: claim one due job, decrypt the org's Page token
 * OUTSIDE the database (ADR-006), POST it once to the Graph API through the
 * tested Meta adapter, and move the job by the outcome. All classification lives
 * in packages/core/meta and is unit-tested.
 *
 * R4 / ADR-018 are the whole point of this file, so the order is load-bearing:
 *   1. claim_due_job already excludes kill_switch/paused orgs (A4);
 *   2. re-check the kill switch immediately before sending (R9) — if it flipped
 *      after the claim, abort WITHOUT writing the marker, so the job is a
 *      never-sent job and requeues cleanly;
 *   3. mark_request_sent writes request_sent_at (write-once) BEFORE the POST, so
 *      a crash after sending is detectable;
 *   4. ONE POST, on a non-pooling client with no retry anywhere (ADR-018);
 *   5. every ambiguous or error outcome → needs_verification, never failed.
 *
 * Invoked by the clock with a shared trigger secret, not a user — verify_jwt is
 * false (config.toml). No secret is logged; the Meta adapter's outcomes carry a
 * numeric code only, never a token or a response body.
 */

import { Client } from "https://deno.land/x/postgres@v0.19.3/mod.ts";
import { keyringFromEnv, openCredential } from "../../../packages/core/crypto/envelope.ts";
import { publishToPage } from "../../../packages/core/meta/publish.ts";
import { type FetchLike } from "../../../packages/core/meta/types.ts";

function b64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

interface Job {
  id: string;
  org_id: string;
  post_id: string | null;
}
interface Bundle {
  post_body: string | null;
  external_id: string | null;
  ct: string | null; // base64 token ciphertext
  iv: string | null; // base64 token iv
  key_version: number | null;
  kill_switch: boolean;
}

Deno.serve(async (req) => {
  // ── Authorise the caller (the clock holds the shared secret) ──────────────
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
  // A non-pooling HTTP client: with no idle connection kept, no request is sent
  // on a reused connection, which is where Deno/hyper resend a POST (ADR-018).
  // `client` on a fetch init is Deno's own option. No retry is configured.
  const httpClient = Deno.createHttpClient({ poolMaxIdlePerHost: 0 });
  const noReuseFetch = ((input: string | URL | Request, init?: RequestInit) =>
    fetch(input, { ...init, client: httpClient } as RequestInit)) as FetchLike;

  try {
    await client.connect();

    // ── Claim one due job (already excludes kill_switch/paused orgs, A4) ────
    const claimed = await client.queryObject<Job>("select * from app.claim_due_job()");
    const job = claimed.rows[0];
    if (!job) return json({ ok: true, published: false, reason: "no due job" });

    // Everything the attempt needs, in one read: the post body, the active
    // Page's encrypted token, and the live kill-switch value (R9 re-check).
    const bundle = await client.queryObject<Bundle>(
      `select p.body as post_body,
              sa.external_id,
              encode(sa.token_ciphertext, 'base64') as ct,
              encode(sa.token_iv, 'base64')         as iv,
              sa.key_version,
              os.kill_switch
         from public.org_settings os
         left join public.posts p
           on p.org_id = os.org_id and p.id = $2::uuid
         left join lateral (
           select external_id, token_ciphertext, token_iv, key_version
             from public.social_accounts
            where org_id = os.org_id and platform = 'facebook_page' and status = 'active'
            order by created_at desc
            limit 1
         ) sa on true
        where os.org_id = $1::uuid`,
      [job.org_id, job.post_id],
    );
    const b = bundle.rows[0];

    // ── Pre-send guards — none of these has issued a request ────────────────
    // R9: the switch may have flipped between the claim and now. Abort without
    // the marker, so the job is never-sent and requeues (R4, J-crash table).
    if (!b || b.kill_switch) {
      return json({ ok: true, published: false, reason: "kill switch on" });
    }
    // No connected Page is a configuration fault: pause the org and stop, rather
    // than attempt every slot (API_INTEGRATIONS §5.1). The job is left to the
    // reclaim/skip sweep — nothing was sent.
    if (!b.external_id || !b.ct || !b.iv || b.key_version === null) {
      await client.queryArray("select app.pause_org_publishing($1::uuid,$2)", [job.org_id, "no active Facebook Page"]);
      return json({ ok: true, published: false, reason: "no active Page — org paused" });
    }
    if (!b.post_body) {
      return json({ ok: true, published: false, reason: "job has no post body" });
    }

    // Decrypt the Page token outside the database (AAD = the Page id).
    let pageToken: string;
    try {
      pageToken = await openCredential(
        keyring,
        { orgId: job.org_id, credentialId: b.external_id },
        { ciphertext: b64ToBytes(b.ct), iv: b64ToBytes(b.iv), keyVersion: b.key_version },
      );
    } catch {
      await client.queryArray("select app.pause_org_publishing($1::uuid,$2)", [job.org_id, "Page token could not be read"]);
      return json({ ok: true, published: false, reason: "token undecryptable — org paused" });
    }

    // ── Marker, then the ONE request ────────────────────────────────────────
    await client.queryArray("select app.mark_request_sent($1::uuid)", [job.id]);
    const outcome = await publishToPage(
      { pageId: b.external_id, message: b.post_body, pageToken },
      noReuseFetch,
    );

    // ── Move the job by the outcome ─────────────────────────────────────────
    switch (outcome.kind) {
      case "published":
        await client.queryArray("select app.finalize_publish($1::uuid,$2)", [job.id, outcome.fbPostId]);
        return json({ ok: true, published: true, job_id: job.id, fb_post_id: outcome.fbPostId });
      case "config_fault":
        await client.queryArray("select app.pause_org_publishing($1::uuid,$2)", [job.org_id, outcome.reason]);
        await client.queryArray("select app.mark_job_needs_verification($1::uuid,$2)", [job.id, outcome.reason]);
        return json({ ok: true, published: false, job_id: job.id, outcome: "config_fault", reason: outcome.reason });
      case "throttled":
      case "needs_verification":
        await client.queryArray("select app.mark_job_needs_verification($1::uuid,$2)", [job.id, outcome.reason]);
        return json({ ok: true, published: false, job_id: job.id, outcome: "needs_verification", reason: outcome.reason });
    }
  } catch (e) {
    return json({ ok: false, error: "publish failed: " + ((e as Error).message ?? "unknown") }, 500);
  } finally {
    try { httpClient.close(); } catch { /* already closed */ }
    await client.end();
  }
});
