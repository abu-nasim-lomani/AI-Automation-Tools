/**
 * The shared publish routine — everything that happens to a job once it is
 * CLAIMED. Both the scheduled `publish` function (which claims the next due job)
 * and the on-demand `publish-now` function (which enqueues one job and claims
 * it) call this, so the R4 / ADR-018 sequence lives in exactly one place:
 *
 *   re-check the kill switch (R9) → decrypt the Page token outside the DB →
 *   write the write-once marker → ONE POST on the non-pooling client, no retry
 *   → move the job by the outcome (published, else needs_verification; a config
 *   fault also pauses the org).
 *
 * No secret is logged; the Meta adapter's outcomes carry a numeric code only.
 */

import { type Client } from "https://deno.land/x/postgres@v0.19.3/mod.ts";
import { openCredential } from "../../../packages/core/crypto/envelope.ts";
import { publishToPage } from "../../../packages/core/meta/publish.ts";
import { type FetchLike } from "../../../packages/core/meta/types.ts";

export interface ClaimedJob {
  id: string;
  org_id: string;
  post_id: string | null;
}

export interface PublishSummary {
  published: boolean;
  job_id: string;
  outcome: "published" | "needs_verification" | "config_fault" | "skipped";
  fb_post_id?: string;
  reason?: string;
}

interface Bundle {
  post_body: string | null;
  external_id: string | null;
  ct: string | null;
  iv: string | null;
  key_version: number | null;
  kill_switch: boolean;
}

function b64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

// deno-lint-ignore no-explicit-any
type Keyring = any;

/** Publish one already-claimed job. The caller owns the DB client, the keyring
 *  and the non-pooling fetch, and closes them. */
export async function processClaimedJob(
  client: Client,
  keyring: Keyring,
  noReuseFetch: FetchLike,
  job: ClaimedJob,
): Promise<PublishSummary> {
  // The post body, the active Page's encrypted token, and the live kill-switch
  // value, in one read.
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

  // Pre-send guards — none of these has issued a request.
  // R9: the switch may have flipped between the claim and now. Abort without the
  // marker, so the job is never-sent and requeues cleanly.
  if (!b || b.kill_switch) {
    return { published: false, job_id: job.id, outcome: "skipped", reason: "kill switch on" };
  }
  // No connected Page is a configuration fault: pause the org and stop.
  if (!b.external_id || !b.ct || !b.iv || b.key_version === null) {
    await client.queryArray("select app.pause_org_publishing($1::uuid,$2)", [job.org_id, "no active Facebook Page"]);
    return { published: false, job_id: job.id, outcome: "config_fault", reason: "no active Facebook Page" };
  }
  if (!b.post_body) {
    return { published: false, job_id: job.id, outcome: "skipped", reason: "job has no post body" };
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
    return { published: false, job_id: job.id, outcome: "config_fault", reason: "token undecryptable" };
  }

  // Marker, then the ONE request.
  await client.queryArray("select app.mark_request_sent($1::uuid)", [job.id]);
  const outcome = await publishToPage(
    { pageId: b.external_id, message: b.post_body, pageToken },
    noReuseFetch,
  );

  switch (outcome.kind) {
    case "published":
      await client.queryArray("select app.finalize_publish($1::uuid,$2)", [job.id, outcome.fbPostId]);
      return { published: true, job_id: job.id, outcome: "published", fb_post_id: outcome.fbPostId };
    case "config_fault":
      await client.queryArray("select app.pause_org_publishing($1::uuid,$2)", [job.org_id, outcome.reason]);
      await client.queryArray("select app.mark_job_needs_verification($1::uuid,$2)", [job.id, outcome.reason]);
      return { published: false, job_id: job.id, outcome: "config_fault", reason: outcome.reason };
    case "throttled":
    case "needs_verification":
      await client.queryArray("select app.mark_job_needs_verification($1::uuid,$2)", [job.id, outcome.reason]);
      return { published: false, job_id: job.id, outcome: "needs_verification", reason: outcome.reason };
  }
}
