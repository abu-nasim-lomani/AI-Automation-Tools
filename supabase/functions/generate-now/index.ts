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

// Ask the key itself which models it can call, then pick one — so the model is
// always one THIS key actually has, and a wrong guess can never 404. Returns the
// generateContent-capable model names (no "models/" prefix). Empty on failure.
async function geminiModels(apiKey: string): Promise<string[]> {
  try {
    const res = await fetch(
      "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1000",
      { headers: { "x-goog-api-key": apiKey }, signal: AbortSignal.timeout(10000) },
    );
    if (!res.ok) return [];
    const data = await res.json();
    const models = (data.models ?? []) as Array<{ name?: string; supportedGenerationMethods?: string[] }>;
    return models
      .filter((m) => (m.supportedGenerationMethods ?? []).includes("generateContent"))
      .map((m) => (m.name ?? "").replace(/^models\//, ""))
      .filter(Boolean);
  } catch {
    return [];
  }
}

// Rank the key's usable text models best-first: preferred stable flash names,
// then any other flash, then any text model. Skips image/tts/embedding/
// experimental variants. Returning several lets a 503 on one busy model fall
// through to the next instead of failing the whole request.
function rankGeminiModels(names: string[]): string[] {
  const bad = /(image|vision|tts|audio|embedding|aqa|learnlm|robot|gemma|deep-research|antigravity|argon|preview|exp)/i;
  // Concrete names first: the "-latest" aliases are listed by this key but can
  // 404 on generateContent, so they are only a last resort.
  const prefer = [
    "gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash",
    "gemini-flash-latest", "gemini-flash-lite-latest",
  ];
  const ranked: string[] = [];
  const add = (n: string) => { if (n && !ranked.includes(n)) ranked.push(n); };
  for (const p of prefer) if (names.includes(p)) add(p);
  for (const n of names) if (/flash/i.test(n) && !bad.test(n)) add(n);
  for (const n of names) if (!bad.test(n)) add(n);
  return ranked;
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
    // Remember what the Gemini key offered, so a 404 can report it instead of
    // leaving us guessing which key is actually in use.
    let geminiAvailable: string[] = [];
    for (const c of creds) {
      try {
        const key = await openCredential(
          keyring, { orgId: ctx.org_id, credentialId: c.id },
          { ciphertext: b64(c.ciphertext), iv: b64(c.iv), keyVersion: c.key_version },
        );
        if (c.provider === "gemini") {
          // Pick from THIS key's own model list, so every name is one it has.
          // Queue the top few so a 503 on one busy model falls to the next.
          const names = await geminiModels(key);
          if (names.length > 0) geminiAvailable = names;
          const ranked = rankGeminiModels(names);
          const models = ranked.length > 0 ? ranked.slice(0, 3) : ["gemini-flash-latest"];
          for (const m of models) attempts.push({ provider: "gemini", model: m, apiKey: key });
        } else {
          attempts.push({ provider: c.provider, model: c.model, apiKey: key });
        }
      } catch { /* skip an undecryptable credential */ }
    }
    if (attempts.length === 0) return json({ ok: false, error: "no usable AI key for this workspace" }, 400);

    // Try the candidate models one at a time. A 404 (that model is not callable
    // on this key, even though it is listed) or a 503 (that model is momentarily
    // busy) falls through to the next model rather than failing the whole
    // sample. A key or quota problem stops at once — another model will not fix
    // it. Each call is short, no critic, no regeneration: the lightest use of
    // the free quota for an on-demand sample the owner reviews anyway.
    let draft: Awaited<ReturnType<typeof generateDraft>> | undefined;
    let lastErr: unknown;
    for (const a of attempts) {
      try {
        draft = await generateDraft({
          voice: ctx.voice, topic: ctx.topic, attempts: [a],
          skipCritic: true, maxOutputTokens: 2048, maxRegenerations: 0,
        });
        break;
      } catch (e) {
        lastErr = e;
        // Free-tier quota is per-model, so a 429 on one model does not mean the
        // next is spent. Fall through on not-callable (404), busy (503) and
        // quota/rate limits alike; only a key or a blocked prompt stops the run.
        if (
          e instanceof ProviderError &&
          (e.status === 404 || e.errorClass === "transient" ||
            e.errorClass === "rate_limited" || e.errorClass === "quota")
        ) {
          continue; // try the next model
        }
        break; // auth / invalid / blocked — another model will not help
      }
    }
    if (!draft) {
      const e = lastErr;
      if (e instanceof ProviderError) {
        if (e.errorClass === "auth" || e.errorClass === "invalid") {
          return json({ ok: false, error: "the AI key was rejected — check it is a valid Gemini key" }, 400);
        }
        if (e.errorClass === "rate_limited" || e.errorClass === "quota") {
          return json({ ok: false, error: "Gemini's free quota is busy right now — wait a minute (or until the daily limit resets) and try again" }, 429);
        }
        if (e.status === 404) {
          const offer = geminiAvailable.length
            ? geminiAvailable.slice(0, 10).join(", ")
            : "(the key returned no model list)";
          return json({ ok: false, error: `none of the tried models were callable on this key — it offers: ${offer}` }, 400);
        }
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
