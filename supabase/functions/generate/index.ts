/**
 * generate — the daily content job (docs/CONTENT_ENGINE.md §7, ADR-017).
 *
 * Thin glue over the tested core: pick an eligible org and its context from the
 * database, decrypt its provider keys OUTSIDE the database (ADR-006), run the
 * orchestrator for a draft, and record the result. All the content and crypto
 * logic lives in packages/core and is unit-tested; this file wires it to
 * Supabase and the network. It makes a live provider call, so it is run only on
 * a deliberate trigger.
 *
 * Invoked by the Cloudflare clock with a shared trigger secret, not a user —
 * so verify_jwt is false (config.toml) and the caller is authorised in code.
 * No secret is ever logged; provider errors are already normalised and carry no
 * response body.
 */

import { Client } from "https://deno.land/x/postgres@v0.19.3/mod.ts";
import { keyringFromEnv, openCredential } from "../../../packages/core/crypto/envelope.ts";
import { generateDraft } from "../../../packages/core/content/generate.ts";
import { type Attempt, ProviderError } from "../../../packages/core/providers/index.ts";
import { type BrandVoice, type Topic } from "../../../packages/core/content/prompt.ts";

const PROMPT_VERSION = "gen-v1";

function b64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

interface Credential {
  id: string;
  provider: "gemini" | "groq";
  model: string;
  tier: "unpaid" | "paid";
  key_version: number;
  ciphertext: string; // base64
  iv: string;         // base64
}

interface Context {
  org_id: string;
  region: "bd" | "global" | "eu_uk";
  timezone: string;
  voice: BrandVoice & { id: string };
  topic: Topic & { id: string };
  credentials: Credential[];
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

Deno.serve(async (req) => {
  // ── Authorise the caller (the clock holds the shared secret) ──────────────
  const expected = Deno.env.get("GENERATE_TRIGGER_SECRET");
  if (!expected || req.headers.get("x-generate-token") !== expected) {
    return json({ ok: false, error: "unauthorized" }, 401);
  }

  const dbUrl = Deno.env.get("SUPABASE_DB_URL");
  if (!dbUrl) return json({ ok: false, error: "SUPABASE_DB_URL missing" }, 500);

  let keyring;
  try {
    keyring = keyringFromEnv(Deno.env.toObject(), [1, 2]);
  } catch {
    // Never echo the reason — it concerns the master key.
    return json({ ok: false, error: "master key not configured" }, 500);
  }

  const client = new Client(dbUrl);
  await client.connect();
  try {
    const picked = await client.queryObject<{ j: Context | null }>(
      "select app.pick_generation_context() as j",
    );
    const ctx = picked.rows[0]?.j;
    if (!ctx) return json({ ok: true, generated: false, reason: "no eligible org" });

    // EU/UK may use only a paid credential (CLAUDE.md §4).
    let creds = ctx.credentials;
    if (ctx.region === "eu_uk") creds = creds.filter((c) => c.tier === "paid");
    if (creds.length === 0) {
      return json({ ok: true, generated: false, reason: "no usable credential for region" });
    }

    // Decrypt each key outside the database and build the attempt list.
    const attempts: Attempt[] = [];
    for (const c of creds) {
      let apiKey: string;
      try {
        apiKey = await openCredential(
          keyring,
          { orgId: ctx.org_id, credentialId: c.id },
          { ciphertext: b64ToBytes(c.ciphertext), iv: b64ToBytes(c.iv), keyVersion: c.key_version },
        );
      } catch {
        // A credential that will not decrypt is skipped, never surfaced in detail.
        continue;
      }
      attempts.push({ provider: c.provider, model: c.model, apiKey });
    }
    if (attempts.length === 0) {
      return json({ ok: true, generated: false, reason: "no decryptable credential" });
    }

    // ── Generate ──────────────────────────────────────────────────────────
    let draft;
    try {
      draft = await generateDraft({ voice: ctx.voice, topic: ctx.topic, attempts });
    } catch (e) {
      // A provider/config failure, not a content outcome. Surface the class
      // only — never the key or a response body.
      const cls = e instanceof ProviderError ? e.errorClass : "transient";
      return json({ ok: false, generated: false, error: `provider ${cls}` }, 200);
    }

    // ── Record ────────────────────────────────────────────────────────────
    const c = draft.counts;
    const notes = {
      accepted: draft.accepted,
      layer: draft.critique.layer,
      reason: draft.critique.reason ?? null,
      attempt: draft.attempt,
      provider: draft.provider,
    };
    const rec = await client.queryObject<{ id: string }>(
      "select app.record_generation($1,$2,$3,$4,$5,$6,$7,$8::numeric," +
        "$9::provider_kind,$10,$11,$12::jsonb) as id",
      [
        ctx.org_id, ctx.topic.id, ctx.voice.id, draft.body,
        c.grapheme_count, c.codepoint_count, c.word_count, c.bangla_ratio,
        draft.provider, draft.model, PROMPT_VERSION, JSON.stringify(notes),
      ],
    );

    return json({
      ok: true,
      generated: true,
      org_id: ctx.org_id,
      post_id: rec.rows[0]?.id,
      accepted: draft.accepted,
      attempt: draft.attempt,
      provider: draft.provider,
    });
  } finally {
    await client.end();
  }
});
