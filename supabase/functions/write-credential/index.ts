/**
 * write-credential — stores an AI provider key, encrypted (DATABASE.md §6.2,
 * SECURITY.md §5). The first server-side use of MASTER_KEY_V1 besides generate.
 *
 * The §6.2 sequence, in order, so a caller can never name themselves an owner:
 *   1. require the user's own token (Authorization header);
 *   2. verify it with auth.getUser() (never decode it locally);
 *   3. reject any client-supplied identity in the body;
 *   4. the DB function re-checks ownership as part of the write;
 *   5. only then, as the service role, encrypt and store.
 *
 * The envelope AAD binds the ciphertext to org : credential id : key version,
 * so the id is generated HERE, sealed against, and inserted as that exact id.
 * No plaintext key and no master key ever reach the database.
 */

import { Client } from "https://deno.land/x/postgres@v0.19.3/mod.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.45.4";
import { keyringFromEnv, sealCredential } from "../../../packages/core/crypto/envelope.ts";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

const PROVIDERS = new Set(["gemini", "groq"]);
const TIERS = new Set(["unpaid", "paid"]);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ ok: false, error: "missing authorization" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const dbUrl = Deno.env.get("SUPABASE_DB_URL");
  if (!url || !anon || !dbUrl) return json({ ok: false, error: "server not configured" }, 500);

  // Verify the caller's token against the auth service — never decode locally.
  const userClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) return json({ ok: false, error: "invalid session" }, 401);
  const actor = userData.user.id;

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ ok: false, error: "invalid body" }, 400);
  }

  // Fail closed on any client-supplied identity (§6.2 step 3).
  for (const k of ["actor_id", "user_id", "sub", "org_role"]) {
    if (k in body) return json({ ok: false, error: `unexpected field: ${k}` }, 400);
  }

  const orgId = String(body.org_id ?? "");
  const provider = String(body.provider ?? "");
  const model = String(body.model ?? "");
  const tier = String(body.tier ?? "unpaid");
  const apiKey = String(body.api_key ?? "");
  if (!orgId || !PROVIDERS.has(provider) || !model || !TIERS.has(tier) || !apiKey) {
    return json({ ok: false, error: "missing or invalid fields" }, 400);
  }

  let keyring;
  try {
    keyring = keyringFromEnv(Deno.env.toObject(), [1, 2]);
  } catch {
    return json({ ok: false, error: "master key not configured" }, 500);
  }

  // Generate the id first, seal against it, then store it as that id.
  const credentialId = crypto.randomUUID();
  const keyVersion = 1;
  let sealed;
  try {
    sealed = await sealCredential(keyring, keyVersion, { orgId, credentialId }, apiKey);
  } catch {
    return json({ ok: false, error: "could not secure the key" }, 500);
  }

  const client = new Client(dbUrl);
  await client.connect();
  try {
    const res = await client.queryObject<{ id: string }>(
      "select app.write_provider_credential($1,$2,$3,$4::provider_kind,$5,$6::credential_tier,$7,$8,$9,$10) as id",
      [
        credentialId, actor, orgId, provider, model, tier,
        sealed.ciphertext, sealed.iv, keyVersion, sealed.maskedHint,
      ],
    );
    return json({ ok: true, credential_id: res.rows[0]?.id, masked_hint: sealed.maskedHint });
  } catch (e) {
    // 42501 is the ownership refusal from the DB function.
    const msg = (e as { fields?: { code?: string } }).fields?.code === "42501"
      ? "you are not an owner of this workspace"
      : "could not store the key";
    return json({ ok: false, error: msg }, 400);
  } finally {
    await client.end();
  }
});
