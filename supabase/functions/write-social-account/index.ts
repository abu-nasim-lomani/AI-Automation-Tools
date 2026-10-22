/**
 * write-social-account — connects a Facebook Page by storing its Page access
 * token, encrypted (DATABASE.md §6, SECURITY.md §5). The twin of
 * write-credential, for the social_accounts table.
 *
 * Same §6.2 sequence, so a caller can never name themselves an owner:
 *   1. require the user's own token (Authorization header);
 *   2. verify it with auth.getUser() (never decode it locally);
 *   3. reject any client-supplied identity in the body;
 *   4. the DB function re-checks ownership as part of the write;
 *   5. only then, as the service role, encrypt and store.
 *
 * The envelope AAD binds the ciphertext to org : external_id (the Page id) :
 * key version — the Page id, not a row id, so a reconnect re-seals against the
 * same context. No plaintext token and no master key ever reach the database.
 */

import { Client } from "https://deno.land/x/postgres@v0.19.3/mod.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.45.4";
import { keyringFromEnv, sealCredential } from "../../../packages/core/crypto/envelope.ts";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

// What a Page token must be able to do to post. Stored so a later token-health
// job (and the UI) can show it; CREATE_CONTENT is required by the DB write.
const DEFAULT_TASKS = ["CREATE_CONTENT"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
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
  for (const k of ["actor_id", "user_id", "sub", "org_role", "connected_by"]) {
    if (k in body) return json({ ok: false, error: `unexpected field: ${k}` }, 400);
  }

  const orgId = String(body.org_id ?? "");
  const externalId = String(body.external_id ?? "").trim();
  const displayName = String(body.display_name ?? "").trim();
  const pageToken = String(body.page_token ?? "");
  if (!orgId || !externalId || !displayName || !pageToken) {
    return json({ ok: false, error: "missing or invalid fields" }, 400);
  }
  // A Page id is a numeric string; reject anything that is obviously not one so
  // a mistyped value fails here rather than at publish time.
  if (!/^\d{1,32}$/.test(externalId)) {
    return json({ ok: false, error: "the Page ID should be numbers only" }, 400);
  }

  const grantedScopes = Array.isArray(body.granted_scopes) ? body.granted_scopes.map(String) : [];
  const grantedTasks = Array.isArray(body.granted_tasks) && body.granted_tasks.length > 0
    ? body.granted_tasks.map(String)
    : DEFAULT_TASKS;

  let keyring;
  try {
    keyring = keyringFromEnv(Deno.env.toObject(), [1, 2]);
  } catch {
    return json({ ok: false, error: "master key not configured" }, 500);
  }

  // Seal against the Page id so a reconnect re-seals against the same context.
  const keyVersion = 1;
  let sealed;
  try {
    sealed = await sealCredential(keyring, keyVersion, { orgId, credentialId: externalId }, pageToken);
  } catch {
    return json({ ok: false, error: "could not secure the token" }, 500);
  }

  const client = new Client(dbUrl);
  await client.connect();
  try {
    const res = await client.queryObject<{ id: string }>(
      "select app.write_social_account($1::uuid,$2::uuid,$3,$4,$5,$6,$7::int,$8::text[],$9::text[]) as id",
      [
        actor, orgId, externalId, displayName,
        sealed.ciphertext, sealed.iv, keyVersion, grantedScopes, grantedTasks,
      ],
    );
    return json({ ok: true, social_account_id: res.rows[0]?.id, masked_hint: sealed.maskedHint });
  } catch (e) {
    const code = (e as { fields?: { code?: string } }).fields?.code;
    let msg = "could not connect the Page";
    if (code === "42501") msg = "you are not an owner of this workspace";
    else if (code === "22023") msg = "this Page token cannot post (missing CREATE_CONTENT)";
    else if (code === "23505") msg = "that Page is already connected to another workspace";
    return json({ ok: false, error: msg }, 400);
  } finally {
    await client.end();
  }
});
