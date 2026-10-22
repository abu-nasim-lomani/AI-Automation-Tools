/**
 * generate-now — a member asks for one draft on demand (the "generate a sample"
 * button). Unlike the clock's generate, it is user-authenticated and targets
 * the caller's own org, with no buffer/cap gate. It still honours R9: no AI
 * call while the emergency stop is on.
 *
 * Reuses the same tested core (generateDraft) and the same envelope decryption.
 * Returns the draft body so the UI can show it.
 */

import { Client } from "https://deno.land/x/postgres@v0.19.3/mod.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.45.4";
import { keyringFromEnv, openCredential } from "../../../packages/core/crypto/envelope.ts";
import { generateDraft } from "../../../packages/core/content/generate.ts";
import { type Attempt, ProviderError } from "../../../packages/core/providers/index.ts";
import { type BrandVoice } from "../../../packages/core/content/prompt.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });
}
function b64(s: string): Uint8Array {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}

interface Credential {
  id: string; provider: "gemini" | "groq"; model: string; tier: "unpaid" | "paid";
  key_version: number; ciphertext: string; iv: string;
}
interface Context {
  org_id: string; region: "bd" | "global" | "eu_uk"; kill_switch: boolean;
  voice: BrandVoice & { id: string }; topic: { id: string; title: string; instructions?: string | null };
  credentials: Credential[];
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
  const orgId = String(body.org_id ?? "");
  if (!orgId) return json({ ok: false, error: "org_id is required" }, 400);

  let keyring;
  try { keyring = keyringFromEnv(Deno.env.toObject(), [1, 2]); }
  catch { return json({ ok: false, error: "master key not configured" }, 500); }

  // Everything below is wrapped so ANY unhandled error returns a readable JSON
  // (with CORS) instead of crashing the worker — a crash reaches the browser as
  // the opaque "Failed to send a request to the Edge Function".
  const client = new Client(dbUrl);
  try {
    await client.connect();
    // The caller must be a member of the org they are generating for.
    const member = await client.queryObject<{ n: number }>(
      "select count(*)::int as n from public.memberships where org_id = $1 and user_id = $2",
      [orgId, actor],
    );
    if ((member.rows[0]?.n ?? 0) === 0) return json({ ok: false, error: "not a member of this workspace" }, 403);

    const picked = await client.queryObject<{ j: Context | null }>(
      "select app.generation_context_for($1::uuid) as j", [orgId],
    );
    const ctx = picked.rows[0]?.j;
    if (!ctx) return json({ ok: false, error: "add a topic and an AI key first" }, 400);
    if (ctx.kill_switch) return json({ ok: false, error: "the emergency stop is on" }, 409);

    let creds = ctx.credentials;
    if (ctx.region === "eu_uk") creds = creds.filter((c) => c.tier === "paid");
    const attempts: Attempt[] = [];
    for (const c of creds) {
      try {
        const key = await openCredential(
          keyring, { orgId: ctx.org_id, credentialId: c.id },
          { ciphertext: b64(c.ciphertext), iv: b64(c.iv), keyVersion: c.key_version },
        );
        attempts.push({ provider: c.provider, model: c.model, apiKey: key });
      } catch { /* skip an undecryptable credential */ }
    }
    if (attempts.length === 0) return json({ ok: false, error: "no usable AI key for this workspace" }, 400);

    let draft;
    try {
      draft = await generateDraft({ voice: ctx.voice, topic: ctx.topic, attempts });
    } catch (e) {
      if (e instanceof ProviderError) {
        if (e.errorClass === "auth" || e.errorClass === "invalid") {
          return json({ ok: false, error: "the AI key was rejected — check it is a valid Gemini key" }, 400);
        }
        // Surface the provider's own message/status so the cause is visible.
        const bits = [
          `provider ${e.errorClass}`,
          e.status ? `http ${e.status}` : null,
          e.providerCode ?? null,
          e.message,
        ].filter(Boolean).join(" · ");
        return json({ ok: false, error: bits }, 400);
      }
      return json({ ok: false, error: "provider error: " + ((e as Error).message ?? "unknown") }, 400);
    }

    const c = draft.counts;
    const rec = await client.queryObject<{ id: string }>(
      "select app.record_generation($1::uuid,$2::uuid,$3::uuid,$4,$5,$6,$7,$8::numeric,$9::provider_kind,$10,$11,$12::jsonb) as id",
      [
        ctx.org_id, ctx.topic.id, ctx.voice.id, draft.body,
        c.grapheme_count, c.codepoint_count, c.word_count, c.bangla_ratio,
        draft.provider, draft.model, "gen-v1",
        JSON.stringify({ accepted: draft.accepted, layer: draft.critique.layer, reason: draft.critique.reason ?? null }),
      ],
    );

    return json({
      ok: true,
      post_id: rec.rows[0]?.id,
      accepted: draft.accepted,
      provider: draft.provider,
      body: draft.body,
    });
  } catch (e) {
    // Surface the cause instead of letting the worker crash.
    return json({ ok: false, error: "generate failed: " + ((e as Error).message ?? "unknown") }, 500);
  } finally {
    await client.end();
  }
});
