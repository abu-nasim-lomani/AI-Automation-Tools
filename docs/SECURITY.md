# SECURITY.md

Threat model, credential handling, and the tests that must pass before anyone else's data or Page
touches this system. Markers follow `CLAUDE.md` §0. Last updated 2026-10-20.

---

## 1. Scope and what this document does not claim

This document describes **intended** controls and the tests that would demonstrate them. As of
2026-10-20 **no code exists**, so **no control here has been implemented or verified.** Nothing in
this repository may be described as secure, hardened, or production-ready until the §11 checklist
passes with evidence.

Specifically, this document does **not** claim:

- that the system is secure because it uses RLS and AES-GCM;
- that encryption at rest protects against a compromised Edge Function runtime (it does not — that
  runtime holds the master key by necessity);
- that any control has been penetration-tested;
- that a third party has reviewed the design.

A control is "done" only when its named test exists, runs in CI, and fails when the control is
removed. That last clause matters: a test that passes with the control deleted proves nothing.

---

## 2. Assets, ranked by what their loss would cost

| # | Asset | Why it matters |
|---|---|---|
| A1 | **Facebook Page access tokens** | Lets the holder publish as someone's brand. `[V] 2026-10-20` Long-lived Page tokens *"do not have an expiration date and only expire or are invalidated under certain conditions"* — so a leaked one stays useful indefinitely |
| A2 | **Tenant AI API keys (BYOK)** | Direct financial loss to the tenant; quota theft |
| A3 | **Supabase service-role key** | Bypasses all RLS. Compromise equals full multi-tenant breach |
| A4 | **Encryption master key** | Decrypts A1 and A2 for every tenant |
| A5 | Tenant content and configuration | Confidentiality and competitive value |
| A6 | Account identity (auth) | Path to everything above |
| A7 | Audit log integrity | Without it, an incident cannot be reconstructed |

---

## 3. Actors and trust

| Actor | Trust | Can reach |
|---|---|---|
| Anonymous internet | none | Public UI assets, auth endpoints, nothing else. **No `anon` RLS policy exists on any tenant table** |
| Authenticated tenant user | low | Only rows where they hold a membership, enforced by RLS |
| UI host runtime | low | Postgres via the user's JWT. Never the service-role key, never a decryption key |
| Edge Function runtime | high | Service-role key, master key, outbound calls. The genuine crown-jewel boundary |
| Watchdog Worker | low | One shared-token health endpoint returning no tenant content |
| Repository / CI | medium | Code and migrations. Must never hold a production credential beyond a deploy token |
| Platform operator (us) | high | Everything. Accepted risk R-A3 in §12 |

---

## 4. Threat model

Each row names a test ID. Tests marked **blocking** must gate CI.

| ID | Threat | Control | Test | Gate |
|---|---|---|---|---|
| T1 | Tenant A reads or writes tenant B's rows | `org_id` on every tenant table; RLS enabled with a membership-checking policy; no `anon` policy; service-role confined to Edge Functions | **SEC-01** Cross-tenant CRUD matrix: authenticated as B, attempt select/insert/update/delete against A's rows in every tenant table; expect 0 rows or error. A tenant table with no matrix entry fails the build | **blocking** |
| T2 | Credentials recovered from a database dump, backup, or dashboard view | App-layer AES-256-GCM; master key outside the database (ADR-006) | **SEC-02** `pg_dump` the test database and grep for known plaintext fixtures and the patterns `AIza`, `gsk_`, `EAA`; expect no match | **blocking** |
| T3 | Secret leaks into logs | Single logging helper; deny-list on `authorization`, `access_token`, `api_key`, `refresh_token`, `cookie`, `set-cookie`, `password`, `ciphertext`; objects redacted by key name, not by value matching | **SEC-03** Unit test on the redactor with nested objects and arrays; plus a CI grep forbidding `console.log(err)` / raw error serialisation on provider and token paths | **blocking** |
| T4 | Secret shipped to the browser | No secret in `NEXT_PUBLIC_*`; APIs return masks only; no "reveal key" endpoint | **SEC-04** Build, then grep build output for secret patterns and for the names of server-only env vars | **blocking** |
| T5 | **Duplicate publication after an ambiguous Graph API outcome** | `unique(org_id, run_date, slot_id)`; `unique(post_id)` on jobs; atomic claim with lease; write-once `request_sent_at` committed before the request; `needs_verification` with a 4-step backoff; paginated read-back with a **coverage-completeness test** so incomplete coverage is a read failure and never an absence `[K9]`; **no automatic transition from `needs_verification` to `pending` at all** — exhaustion routes to `unresolved` for human resolution; **`failed` means "no request was ever issued"** and no API error response ever yields it `[K6]`; attempt cap of 3 on the never-sent path only; at most **two** requests per job — the original plus one after a guarded attestation, which is an **application-level limit, not a guarantee against duplicate publication** `[K22]`, see R-A10 | **SEC-05** Fault injection against a **mock** Graph API (real upstream state cannot be asserted in a test): network timeout, HTTP 500, malformed JSON, slow-but-successful POST, worker killed before the request, worker killed after the request, and a read-back that returns the post only on the third attempt. In every case assert the mock received **at most one** POST, and that **no job ever leaves `needs_verification` for `pending` by any automatic path** — exhaustion must land in `unresolved`. See also SEC-24 | **blocking** |
| T6 | Stolen or mis-scoped Page token used beyond intent | Request only `pages_manage_posts`, `pages_read_engagement`, `pages_show_list` `[V]`; store granted scopes and tasks; verify `CREATE_CONTENT` before enabling automation | **SEC-06** Reject a connection whose returned tasks lack `CREATE_CONTENT` | required |
| T7 | Invalidated token silently drains the queue | Daily `debug_token` check; on failure set `reauth_required` and pause that org's automation | **SEC-07** With a deliberately invalid token, assert automation pauses, a banner state is set, and no repeated failed publishes occur | required |
| T8 | SSRF / internal-network pivot | No user-supplied outbound URL anywhere in the MVP; provider and Meta base URLs are a compile-time allowlist; no redirect following to a new host | **SEC-08** Attempt `http://169.254.169.254/`, `http://localhost:5432`, `file:///etc/passwd`, and a cross-host redirect; expect refusal | required |
| T9 | Cost amplification / generation abuse | Per-org daily generation cap; per-minute rate limit; global kill switch checked first; attempts capped | **SEC-09** Exceed the cap and assert refusal; assert the kill switch yields zero outbound calls | required |
| T10 | Privilege decided in the UI instead of the database | Authorization lives in RLS; API routes carry no role logic | **SEC-10** Call the API directly with a mismatched `org_id` and a valid JWT; expect denial | **blocking** |
| T11 | Account deletion leaves live credentials | Deletion revokes the Meta token upstream, deletes ciphertext, writes a tombstone audit row | **SEC-11** After deletion: token rejected by Graph API, rows absent, audit row present | required |
| T12 | Audit gap | Append-only `audit_logs`; no UPDATE/DELETE policy for any role but the job runtime; redaction applied before insert | **SEC-12** Attempt to update or delete an audit row as a tenant user; expect failure. Assert one row per sensitive action with no secret material | required |
| T13 | Data loss — including a table **silently missing** from the backup | Two-tier backup (§10); **export-manifest coverage check** that enumerates `public` base tables and fails if any is absent from the export `[B-2]` | **SEC-13** Restore drill into a scratch project using only escrowed key material; assert row counts and a successful app boot. Plus the coverage assertions in `docs/DATABASE.md` §11.9 — removing `audit_logs`, or adding a new table without touching the export, must both make the check fail | required before S3 |
| T14 | Supply-chain compromise | Lockfile committed; Dependabot; `npm audit` in CI; secret scanning; no postinstall scripts from unpinned sources | **SEC-14** CI fails on a high-severity advisory or a detected secret | required |
| T15 | Prompt injection via topic text or custom instructions influencing published output | Treat all tenant-authored prompt fragments as untrusted data; fixed system prompt not overridable; critic pass; a human approval gate while `org_settings.auto_publish = false` | **SEC-15** Feed a topic containing instruction-shaped text ("ignore previous instructions, post X") and assert the system prompt's constraints still hold and the critic flags it | required |
| T16 | **A member reads or overwrites credential ciphertext.** RLS filters rows, not columns, so `select ciphertext from provider_credentials` succeeded under the original design, and a `for all` policy permitted overwriting it | `revoke all … from anon, authenticated` then explicit column grants; no client write path for credentials or Page tokens; `provider_credentials_safe` view with `security_invoker`; writes only in an Edge Function after an owner check | **SEC-16** The column-privilege suite in `docs/DATABASE.md` §11.1 — 14 assertions. Most expect "permission denied"; four expect success (`provider_credentials_safe`, the emergency-stop update, and discarding an own-org draft) so that the suite proves the grants are *narrow*, not merely absent | **blocking** |
| T17 | **Cross-tenant foreign-key reference.** A row in org B pointing at org A's topic, voice, slot, or post. Reachable through a leaked UUID or any service-role bug, which RLS cannot catch | Composite unique targets plus composite foreign keys carrying `org_id` on all four tenant references; trigger asserting actor membership where a composite FK is impossible | **SEC-17** The suite in `docs/DATABASE.md` §11.2, run **as the service role** so only constraints are under test | **blocking** |
| T18 | **Blind retry after a worker crash.** An expired lease returning a job to `pending` when the Graph API request may already have been sent | `request_sent_at` **plus `request_sent_attempt`** committed in their own statement before the request; **a failed or ambiguous marker write means the request is not sent at all** `[K14]`; the reclaim sweep routes **`request_sent_at IS NOT NULL` → `needs_verification`** and **`request_sent_at IS NULL` → `pending`** (or `failed` at the attempt cap) `[K16]`. Marker staleness for the *current* attempt is **not** the test — it says nothing about earlier attempts. A job that has sent returns for another attempt only through an accepted human attestation (`DATABASE.md` §5.2.3) | **SEC-18** Kill the worker before the marker write, between the marker write and the request, and after the request; assert `pending` **only** in the first case and `needs_verification` otherwise; assert the marker is never reset across a requeue; assert a failed marker write sends nothing; and assert that a transaction wrapping both the marker write and the request fails review | **blocking** |
| T19 | **Audit log rewritten or truncated by the service role.** RLS with no write policy stops `authenticated` but not a `BYPASSRLS` role, and `revoke update, delete` alone leaves `TRUNCATE` and sequence `setval` open | `revoke all on audit_logs from anon, authenticated, service_role`, then grant back only: `select` to `authenticated`, and `insert` **plus `select`** to `service_role`. The `select` is deliberate `[B-2]` — the protected property is **integrity**, not confidentiality against our own job runtime, and without it the backup omits the log. Sequence privileges revoked, `usage` only to `service_role` | **SEC-19** `docs/DATABASE.md` §11.4 — for both roles assert `update`, `delete`, `truncate`, sequence `setval` and `disable row level security` all fail, **and** that `service_role` `select` succeeds. `[A]` The table owner and any superuser can still rewrite history — see R-A7 and §13 | required |
| T20 | **Cross-tenant denial of service through a shared key space.** A globally unique `fb_post_id` let one tenant insert a guessed value and permanently break another tenant's finalize step with a unique violation | Unique index scoped to `(org_id, fb_post_id)`; `fb_post_id` removed from client-writable columns | **SEC-20** As org B, insert a post carrying a `fb_post_id` that org A is about to record; assert B's insert is refused by the column grant and that A's finalize still succeeds | required |
| T22 | **An ordinary member performs an owner-only action.** `member_role` existed in the schema but no policy read it, so every member could disconnect a Page, replace a credential, or change the schedule | Role matrix §7.1; `app.has_role()` inside every owner-gated RPC; no client write path for credentials, Pages, or schedule; last-owner guard in both the RPC and a trigger | **SEC-22** `docs/DATABASE.md` §11.3 — for every matrix row assert the owner succeeds **and** the member is refused; a test that checks only the owner path proves nothing | **blocking** before S3 |
| T23 | **A privileged RPC callable by anyone.** PostgreSQL grants `EXECUTE` on every new function to `PUBLIC`, so a `SECURITY DEFINER` function left at the default is callable by `anon` and runs with the owner's privileges — including `finalize_publish`, which would let an unauthenticated caller forge a published job | `revoke all on schema app from public, anon`; `revoke execute … from public, anon` on every function, then an explicit grant; `finalize_publish`, `write_provider_credential` and `connect_social_account` granted to `service_role` only | **SEC-23** `docs/DATABASE.md` §11.5 — as `anon`, every function in `app` must be refused; as `authenticated`, the three service-only functions must be refused; CI rejects a new function with no explicit revoke | **blocking** |
| T24 | **Actor impersonation on the privileged write path.** `app.has_role()` resolves the caller with `auth.uid()`, which is **null** under a service-role connection, so the previously specified check could not work — and "fixing" it by reading a user id from the request body would let any caller claim ownership | Five-step sequence in `docs/DATABASE.md` §6.2: require the user's own bearer token, verify it with `auth.getUser()` (never a local decode), **reject** any request carrying `actor_id`/`user_id`/`sub`, check ownership via `app.assert_owner()` through a *user-scoped* client, then pass the verified id to a `service_role`-only RPC that re-checks membership **in the same transaction as the write** | **SEC-25** Call the credential write with: no token, an expired token, a valid token plus a forged `actor_id` in the body, a valid token for a `member`, and a valid owner token whose membership is revoked between check and write. All five must be refused; only an uninterrupted owner succeeds | **blocking** |
| T21 | **EU/UK tier rule bypassed by changing region after the fact** | `enforce_region_tier` on credential writes **plus** `enforce_region_change` on `orgs.region`, **plus** an independent re-check in the generation job | **SEC-21** Store an unpaid credential on a `global` org, then change the region to `eu_uk`; assert the update is refused. Then force the region in the database and assert the generation job still refuses to call the provider | required before any EU/UK org |
| T25 | **Duplicate prevention defeated by a desynchronised or forged content hash.** The old `grant update (body)` would have let a client change a post's body while `content_hash` kept the old value, so `posts_content_hash_key` stopped describing reality and the same text could be published twice; granting the hash columns instead would let a client forge a hash outright | No client `insert` or `update` on `posts` at all — creation and edits go through two Edge Functions using the service role (`docs/DATABASE.md` §6.3) — **plus** the `posts_hash_guard` trigger, which recomputes both hashes from `body` on every write and discards whatever the writer supplied, so the control survives a service-role bug as well `[B-1]` | **SEC-26** `docs/DATABASE.md` §11.8 — **as the service role**, assert supplied hashes are overwritten, that a body edit colliding with an existing post raises a unique violation, that whitespace- and NFC-equivalent bodies hash identically, and that dropping the trigger makes those assertions fail | **blocking** |

`[A]` T15's control is partial by nature: no prompt-level defence is complete. The real mitigation
is the approval gate plus the fact that only the Page owner's own configuration reaches their own
Page.

---

## 5. Credential encryption design

**Scheme.** Envelope encryption, performed in the Edge Function runtime, never in Postgres.

```
master key        MASTER_KEY_V1 — 32 random bytes, base64, in function env only
                  never in the repo, never in the database, never in a log
per-tenant DEK    HKDF-SHA256(master_key, salt = org_id_bytes, info = "cred:v1")
cipher            AES-256-GCM, 96-bit random IV per encryption, 128-bit tag
AAD               org_id || credential_id || key_version   (binds ciphertext to its row)
stored            ciphertext (tag appended) : bytea
                  iv                        : bytea
                  key_version               : int
                  masked_hint               : text   e.g. "AIza…7f2c" (last 4 only)
```

The AAD binding matters: moving a ciphertext blob to a different row or org makes decryption fail
rather than succeed under the wrong tenant.

**Rotation.** Introduce `MASTER_KEY_V2`, bump `key_version` on write, re-encrypt in a background
job, then retire V1 once no row references it. Both keys are present in the environment during the
window. Rotation is also the incident response for a suspected master-key compromise.

**`[A]` Accepted limitation.** A compromised Edge Function runtime, or an attacker with the
function environment, can decrypt everything. There is no $0 way to avoid this: something must
hold the key to use the credential. We reduce exposure (one runtime, no key in the DB, no key in
the UI host, no key in CI) rather than eliminate it.

**Catastrophic-loss note.** If the master key is lost and no copy exists, **every stored
credential is permanently unrecoverable** and every tenant must re-enter their keys and
re-authorise their Page. Treat the master key as a backup-critical secret stored outside this
system; `[?]` where the owner keeps that copy is an unresolved operational decision.

**Validation, not storage, at entry.** When a key is saved: decrypt nothing back to the client,
run one minimal live provider call to confirm the key works, store `validation_status` and
`last_validated_at`, and return only the mask. There is no endpoint that returns a stored
credential in plaintext — not for the UI, not for support, not for the owner.

---

## 6. Secret inventory

| Secret | Lives in | Never in |
|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | Edge Function env | Browser, UI host runtime, repo, CI logs |
| `SUPABASE_DB_PASSWORD` | Owner's local credential store, used only by the manual export | Repo, CI, any runtime. **Not interchangeable with the service-role key** — `[V] 2026-10-20` Supabase connection strings authenticate with the database password; API keys apply only to the Data APIs. An earlier version of this table wrongly assigned the backup job to the service-role key |
| `BACKUP_PUBLIC_KEY` | Edge Function env. **Not confidential** — it can only encrypt. It *is* integrity-sensitive: swapping it makes future backups readable by whoever holds the matching private key, so its fingerprint is logged on every export | — |
| `BACKUP_PRIVATE_KEY` | **Offline only**, two copies in separate locations, **never in any runtime**, and stored apart from `MASTER_KEY_*` so one compromise cannot yield both | Any runtime, repo, CI, the backup archive itself |
| `MASTER_KEY_V*` | Edge Function env + one offline copy held by the owner | Database, repo, UI host, logs, and the backup archive |
| `WATCHDOG_TOKEN` | Cloudflare Worker secret + Edge Function env | Repo |
| Tenant AI keys (A2) | Database as ciphertext only | Anywhere in plaintext at rest |
| Page tokens (A1) | Database as ciphertext only | Anywhere in plaintext at rest |
| `SUPABASE_ANON_KEY` | Public by design (browser) | — (not a secret; RLS is the control) |
| Meta app secret | Edge Function env, used only for token exchange | Browser, repo |

`.env.example` lists names with empty values. `.env*` is git-ignored. No real value is ever
committed, pasted into chat, or written into a doc.

---

## 7. Authentication and authorization

- **Identity:** Supabase Auth. `[D]` Email magic-link or OAuth; password auth adds reset flows and
  credential-stuffing exposure for no benefit at this scale.
- **Authorization:** in the database — RLS for rows, `GRANT` for columns, and
  `app.has_role()` inside `SECURITY DEFINER` RPCs for role-gated actions. API routes carry no
  role logic (T10).
- **Session:** short-lived JWT with refresh; logout revokes. `[?]` Whether to enforce MFA for
  owners before S4 is unresolved.
- **The service role never serves a user request.** It is used by jobs only.

### 7.1 Role-to-action matrix `[F-07]`

An earlier version of this document said "no permission matrix until a tenant asks for one." That
was wrong on its own terms: `member_role` already existed in the schema and **no policy referenced
it**, so every member silently held owner powers — including disconnecting a Page and replacing
credentials. Retrofitting authorization after multi-user onboarding is exactly the change that
produces cross-tenant incidents, so the matrix is defined now even though S2 has one user.

| Action | owner | member | Enforced by |
|---|---|---|---|
| View dashboard, queue, calendar, published history | ✅ | ✅ | RLS select policy |
| View logs and job status | ✅ | ✅ | RLS select policy |
| Create / edit / delete topics | ✅ | ✅ | RLS + column grants |
| Create / edit brand voices | ✅ | ✅ | RLS + column grants |
| Write or edit a post body (draft) | ✅ | ✅ | `update-post-body` Edge Function, member check per §7.2. **No client grant** — `docs/DATABASE.md` §6.3 `[B-1]` |
| Discard a draft | ✅ | ✅ | `grant delete on posts`; `prevent_published_mutation` blocks published rows |
| Approve or reject a post | ✅ | ✅ | `app.approve_post` |
| **Set `paused` / `kill_switch` (emergency stop)** | ✅ | ✅ | `grant update (kill_switch, paused)` — deliberately available to any member `[D]` |
| Change other org settings (`auto_publish`, buffer, caps, timezone) | ✅ | ❌ | `app.update_org_settings` + owner check |
| Edit the publishing schedule | ✅ | ❌ | `app.set_schedule` + owner check |
| Connect or disconnect a Facebook Page | ✅ | ❌ | Edge Function + owner check; no client write path |
| Add, replace, or delete an AI credential | ✅ | ❌ | Edge Function + owner check; no client write path |
| Read credential ciphertext | ❌ | ❌ | **Nobody.** No client role holds the column grant |
| Invite, remove, or re-role a member | ✅ | ❌ | `app.invite_member` / `app.change_role` / `app.remove_member` |
| Resolve an `unresolved` publish job | ✅ | ❌ | `app.resolve_job` + owner check |
| Delete the organization | ✅ | ❌ | Owner check + the §10 deletion sequence |

Rationale for the one deliberate exception: an emergency stop that requires the right role is an
emergency stop that fails when it is needed. The cost of a member pausing the queue is one missed
slot; the cost of being unable to stop a misbehaving automation is unbounded.

**Last-owner protection:** no action may leave an org with zero owners. Enforced twice — in the
RPC and by the `guard_last_owner` trigger — because the RPC is the thing most likely to be
bypassed by a future code path.

### 7.2 Authorization on the service-role write path `[F-18]`

`auth.uid()` is populated from the **current request's** JWT claims. An Edge Function connected
with the service-role key has no user JWT in that context, so `auth.uid()` is **null** and
`app.has_role()` returns false for everyone. A previous revision of this document specified
credential writes as happening "using the service role, after it has itself checked
`app.has_role(org_id,'owner')`" — which cannot work. The naive repair, reading a user id from the
request body, is worse: it turns the endpoint into an impersonation primitive.

The required sequence is specified in full in `docs/DATABASE.md` §6.2. In summary: the client
sends its **own** bearer token; the function **verifies** it with `auth.getUser()` rather than
decoding it; any request carrying `actor_id`, `user_id`, `sub` or `org_role` is **rejected**
outright rather than having the field ignored; ownership is checked by calling
`app.assert_owner(org_id)` through a **user-scoped** client so `auth.uid()` resolves correctly;
and only then does the function switch to the service role, passing the verified id to an RPC whose
**first statement re-checks membership in the same transaction as the write**, which closes the
window on concurrent revocation. The actor parameter is trustworthy only because `EXECUTE` on that
RPC is granted to `service_role` alone (T23) and the value never comes from the request body — if
either property is relaxed, the control is gone. Tested by **SEC-25**.

`[A]` A Supabase access token remains valid until expiry, so a signed-out user's token can still
pass verification for the rest of its lifetime. Membership — re-read on every privileged call — is
therefore the authority, not the token. `[?]` A `token_valid_after` check is unresolved for S4.

---

## 8. RLS strategy

Full policies in `docs/DATABASE.md` §6. The invariants:

1. `alter table … enable row level security` on **every** table in `public`.
2. No policy grants `anon` anything on a tenant table.
3. One `SECURITY DEFINER` helper, `app.is_member(uuid)`, with `set search_path = ''` to prevent
   search-path hijacking, is the single membership check.
4. Policies declare both `using` and `with check` — omitting `with check` permits writing rows
   into another tenant.
5. `audit_logs` has no write policy for `authenticated`, **and** at the privilege level everything
   is revoked from `anon`, `authenticated` and `service_role` before granting back only `select`
   (both non-anon roles) and `insert` (`service_role`) — because a `BYPASSRLS` role ignores
   policies but not grants, and because `revoke update, delete` alone leaves `TRUNCATE` open. The
   `service_role` `select` is deliberate `[B-2]`: the protected property is integrity, and the
   backup must be able to export the log.
6. A new tenant table is not merged without a row in the SEC-01 matrix.
7. **RLS is not the whole control.** Row policies are paired with column privileges: `revoke all
   … from anon, authenticated`, then grant back an explicit column list. A new column is therefore
   deny-by-default, so a future migration cannot expose a sensitive column by omission.
8. Credentials, Page tokens **and posts** have **no client write path at all** — not a restricted
   one. A column-restricted write path was tried for `posts` and failed on both counts: it could
   not satisfy the table's `NOT NULL` columns, and the one column it did grant (`body`) was enough
   to desynchronise a hash that a control depends on `[B-1]`.
9. Every tenant foreign key is composite and carries `org_id`, because RLS's `with check` validates
   only the inserted row's own `org_id` and the service role bypasses policies entirely.

---

## 9. Input handling, rate limits, abuse

- **Validation at the edge** with a schema validator; reject unknown fields rather than ignoring
  them. Lengths bounded on every text field (a 10 MB "topic" is an availability attack).
- **Output:** post bodies are rendered as text, never as HTML. No `dangerouslySetInnerHTML`
  anywhere, including the Facebook-style preview.
- **Unicode:** normalise to NFC on save; reject unpaired surrogates and bidi-control characters in
  content that will be published, since they can misrepresent what the user approved.
- **Rate limits:** per-org generation cap per day; per-user API rate limit; exponential backoff on
  provider 429. `[V]` Meta Page-token limit is `4800 × engaged users / 24h` with throttle error
  `80001` — at five posts/day we are far below it, but the error must still be handled, and `[A]`
  a brand-new Page with almost no engaged users may have a very low effective ceiling.
- **Abuse:** no public sign-up before S4, which removes most abuse surface during S2/S3.

---

## 10. Retention, deletion, backup, incident response

**Retention `[D]`:** posts and audit logs kept while the account is active; logs trimmed to 180
days; `needs_verification` and `failed` jobs kept 1 year for forensics.

**Deletion:** a user-initiated delete must, in this order — (1) pause automation, (2) revoke the
Meta token upstream, (3) delete credential ciphertext, (4) delete tenant rows, (5) write a
tombstone audit row containing no personal data. Partial completion must be resumable; a delete
that fails at step 2 must not proceed to step 3, or the token becomes un-revokable.

**Backup — partially unresolved, and the honest state of it. `[F-10]`**

`[V]` The Supabase free plan includes **no automatic backups**, so self-managed export is
mandatory from the first real data. Three facts make the original one-line plan ("nightly
`pg_dump` to private storage") unworkable as written:

1. `[V] 2026-10-20` `pg_dump` needs the **direct connection** and the **database password**. The
   service-role key is not a Postgres credential. §6 has been corrected.
2. `[V] 2026-10-20` On the free plan the direct connection is **IPv6-only**; IPv4 is a paid
   add-on. From an IPv4-only network the direct endpoint is simply unreachable. Supabase
   recommends the shared pooler in session mode for IPv4-only networks, but documents `pg_dump`
   as a direct-connection use case — `[?]` whether `pg_dump` works reliably through session-mode
   Supavisor is **unverified** and must be tested before it is relied on.
3. **Nothing compliant can run it on a schedule for $0.** `[V]` GitHub Actions is excluded by the
   same terms that excluded it as a scheduler (ADR-005) — storing a database backup is "activity
   unrelated to the production, testing, deployment, or publication of the software project". A
   Cloudflare Worker cannot stream a dump within `[V]` 10 ms CPU and has no Postgres client.

**Decided for S2 `[D]`:** a two-tier approach.

- **Tier 1, automated, logical, in-platform — with public-key encryption.** An Edge Function
  exports each table to JSON via the service role and writes it to Supabase Storage. It needs no
  database password and works from anywhere.

  **The encryption key problem, and its resolution `[F-19]`.** An earlier revision of this
  document required the function to encrypt with `BACKUP_ENCRYPTION_KEY` while the secret
  inventory required that key to stay in the owner's offline store. Both could not be true, and
  resolving it the easy way — putting a symmetric key in the function environment — would mean a
  single runtime compromise decrypts **every historical backup**. Resolved with hybrid
  encryption instead (ADR-013): per export, a random AES-256-GCM data key encrypts the payload,
  and that data key is encrypted to **`BACKUP_PUBLIC_KEY`** (RSA-OAEP). The runtime therefore
  holds a key that can only encrypt. `BACKUP_PRIVATE_KEY` never goes online.

  **Residual risk, stated rather than hidden.** A compromised runtime cannot read past backups,
  but it *can* substitute its own public key so future exports are readable by the attacker and
  not by the owner. Mitigation: the public-key fingerprint is written to `audit_logs` on every
  export, and the restore drill verifies the fingerprint as well as the decryption.

  **Coverage is enforced, not assumed `[B-2]`.** The export enumerates `public` base tables from
  `information_schema` and **fails** if any is missing from its own manifest, rather than exporting
  a hard-coded list. This is the actual fix for the audit-log omission: the grant was only half of
  it, and the half that mattered was that nothing would ever have reported the gap. A table added
  by a future migration cannot be silently excluded, and omitting one requires a reviewed
  deny-list entry that the manifest then names. Per-table row counts and the public-key
  fingerprint are recorded in the manifest. Assertions in `docs/DATABASE.md` §11.9.

  **Other limitations.** It is not a byte-exact `pg_dump`: it does not capture roles, policies,
  functions, grants, or extensions — those are reproducible from `supabase/migrations/` in git,
  which is the real schema backup. And it lives **with the same vendor as the primary database**,
  so it protects against accidental deletion and bad migrations but **not** against account loss.
  `[A]` RSA-OAEP via WebCrypto in Deno is assumed available and must be confirmed before this
  tier can be called implemented.
- **Tier 2, manual, full fidelity.** A documented `pg_dump` the owner runs from a machine with
  IPv6, weekly, encrypted, stored off-platform. Schema, policies, and functions are additionally
  reproducible from `supabase/migrations/` in git, which is the real schema backup.

**Still unresolved `[?]`:** a genuinely $0, off-vendor, automated destination. Candidates and their
problems — Cloudflare R2 (`[?]` free tier may require a payment method on file), a private GitHub
repository (excluded by the same Actions-adjacent terms question, and unsuitable for growing
binaries), Supabase Storage (same vendor, 1 GB). Until one is settled, **the backup is partly
manual and depends on the owner remembering**, which is an accepted risk, not a solved problem.

**Encryption-key recovery `[F-10]`.** Two distinct offline secrets are now required, and they must
not be stored together — `BACKUP_PRIVATE_KEY` decrypts the archive, `MASTER_KEY_V*` decrypts the
credentials inside it, and a single location holding both means one compromise yields everything.
The required procedure, which `[?]` the owner must confirm they have actually performed: two
offline copies of **each** key, in separate physical locations, neither on the machine that runs
the export; a recorded `key_version` and public-key fingerprint; and a documented drill that
decrypts a known fixture using only the escrowed copies. If no copy of `MASTER_KEY_V*` exists, its
loss is unrecoverable — every tenant must re-enter every credential and re-authorise every Page. If
no copy of `BACKUP_PRIVATE_KEY` exists, every automated backup is permanently unreadable, which is
the failure mode where you believe you have backups and do not.

A backup that has never been restored is not a backup. **SEC-13** is the proof, and it must
include restoring with only the escrowed key material.

**Incident response runbook (to write before S3):** (1) hit the kill switch; (2) rotate
`MASTER_KEY`, service-role key, watchdog token; (3) revoke all Page tokens and force
re-authorisation; (4) preserve `audit_logs` before any cleanup; (5) assess scope from audit rows;
(6) notify affected tenants — `[?]` notification timelines may be legally prescribed in some
jurisdictions and must be checked before S4.

---

## 11. Pre-S3 security checklist

No one else's Page or data is connected until every line is true, with evidence.

- [ ] SEC-01 cross-tenant matrix covers every tenant table and is blocking in CI
- [ ] SEC-02 dump grep finds no plaintext credential
- [ ] SEC-03 redactor tested; CI grep for raw error logging active
- [ ] SEC-04 build-output grep blocking
- [ ] SEC-05 fault-injection suite passes all four injected failures, blocking
- [ ] SEC-06 / SEC-07 token scope and invalidation handling pass
- [ ] SEC-08 SSRF refusals pass
- [ ] SEC-09 rate-limit and kill-switch tests pass
- [ ] SEC-10 direct-API authorization test blocking
- [ ] SEC-11 deletion test passes, including upstream revocation
- [ ] SEC-12 audit immutability test passes
- [ ] SEC-13 **restore drill completed** and documented, using only escrowed key material
- [ ] SEC-13 **coverage check** fails when any `public` base table is absent from the export
      manifest, verified by removing `audit_logs` from the export on purpose `[B-2]`
- [ ] SEC-14 Dependabot, `npm audit`, secret scanning active
- [ ] SEC-15 prompt-injection test passes
- [ ] SEC-16 column-privilege suite (14 assertions) passes, blocking
- [ ] SEC-17 cross-tenant foreign-key suite passes **as the service role**, blocking
- [ ] SEC-18 crash-recovery classification passes for both crash points, blocking
- [ ] SEC-19 audit immutability holds against `authenticated` **and** `service_role` for
      `insert`/`update`/`delete`/**`truncate`**/sequence `setval`/`disable row level security`
- [ ] SEC-20 `fb_post_id` key-space test passes
- [ ] SEC-21 region-change enforcement passes (before any EU/UK org, not before S2)
- [ ] SEC-22 role matrix passes in both directions (owner succeeds, member refused)
- [ ] SEC-23 every function in schema `app` refuses `anon`; the three service-only RPCs refuse
      `authenticated`; CI rejects a function added without an explicit `revoke execute … from
      public`, blocking
- [ ] SEC-24 human-resolution suite passes, **including** the assertion that no automatic path
      takes a job from `needs_verification` to `pending`, blocking
- [ ] SEC-25 all five impersonation attempts on the credential write path are refused, including
      membership revoked between check and write, blocking
- [ ] SEC-26 post hash-integrity suite passes **as the service role**, and its assertions fail when
      `posts_hash_guard` is dropped, blocking `[B-1]`
- [ ] `authenticated` holds no `insert` and no `update` grant on `posts`; creation and body edits
      go only through the two Edge Functions in `docs/DATABASE.md` §6.3 `[B-1]`
- [ ] `service_role` `select` on `audit_logs` **succeeds**, while `update`/`delete`/`truncate`
      fail `[B-2]`
- [ ] SEC-09 asserts zero outbound calls per job type under `kill_switch`, **including the verify
      job**, and that `paused` still permits verification
- [ ] Every RLS policy declares `using` **and** `with check`
- [ ] No `anon` policy on any tenant table; `anon` holds no table or column grant
- [ ] `revoke all on all tables in schema public from anon, authenticated` present in a migration,
      with every grant that follows it reviewed column by column
- [ ] Server is PostgreSQL 15+, or both documented fallbacks are applied instead
- [ ] An `unresolved` job raises a visible alert and has a UI resolution path
- [ ] `.env*` git-ignored; no secret in git history (verified with a history scan)
- [ ] Master key copy held offline by the owner
- [ ] Incident runbook written
- [ ] Each control's test verified to **fail** when the control is removed

---

## 12. Accepted risks

| ID | Risk | Why accepted |
|---|---|---|
| R-A1 | A compromised Edge Function runtime decrypts all credentials | Unavoidable without paid KMS/HSM; mitigated by minimising where the key lives |
| R-A2 | No managed backups on the free plan | Partly mitigated: the automated tier is logical-only and lives with the same vendor; the full-fidelity tier is **manual and depends on the owner remembering**. Residual exposure is up to 24 h of content plus total loss on account-level failure. Not a solved problem — §10 |
| R-A7 | The **table owner** (`postgres`), any superuser, anyone holding the database password, and anyone using the dashboard SQL editor can rewrite or `TRUNCATE` `audit_logs` — which includes the project owner | No $0 external append-only sink exists. Grants stop `anon`, `authenticated` and `service_role`, including `TRUNCATE`; they cannot stop the owner. So the log is append-only **against the application**, not against its administrator. Documented rather than claimed away — `docs/DATABASE.md` §6 names every role that remains capable |
| R-A9 | A compromised Edge Function can swap `BACKUP_PUBLIC_KEY`, making future backups readable by the attacker and unreadable by the owner | It cannot read past backups (ADR-013). Detection, not prevention: the key fingerprint is written to `audit_logs` on every export and verified in the restore drill |
| **R-A10** | **Duplicate publication remains possible.** `[K20]` The two-request ceiling bounds what the *application* issues; it cannot bound what Facebook receives or creates. It fails as a duplicate guarantee if transport-level HTTP retries are ever enabled (forbidden — `JOBS_AND_SCHEDULING.md` §6), if any proxy or gateway between us and Meta retransmits (outside our control, undocumented), if Meta's internal processing duplicates (no documentation either way), or if both requests are accepted because error 506's "consecutive duplicates" window and comparison scope are undefined (`API_INTEGRATIONS.md` §6) | Not mitigable to zero. `[V]` Meta documents no idempotency key for `/{page-id}/feed` and no statement that any response implies the absence of a side effect, so **at-most-once is an application-level property, never a guarantee.** 506 plus read-back recovery reduces the probability and makes a wrong human attestation self-correcting; no document may describe either as a guarantee |
| R-A8 | `provider_credentials.tier` is a user attestation, not a verified fact | `[?]` No known API distinguishes a paid Gemini key from an unpaid one. The EU/UK control therefore depends on the user telling the truth, recorded in the audit log |
| R-A3 | The operator can read tenant content | Inherent to a single-operator SaaS; must be disclosed in the privacy policy |
| R-A4 | `[V]` Unpaid Gemini tier means content is used for product improvement and may be read by human reviewers | Disclosed to the user; BYOK means the tenant chooses their own tier; EU/UK requires a paid tier |
| R-A5 | No third-party security review | No budget. State plainly; do not imply otherwise |
| R-A6 | Free-tier platforms offer no SLA | Documented in `docs/ARCHITECTURE.md` §5 |

---

## 13. Open questions

1. `[?]` Where does the owner store the two offline copies of `MASTER_KEY_V1` and of
   `BACKUP_PRIVATE_KEY` — in **separate** locations, neither on the machine that runs the export —
   and has the decrypt-from-escrow drill actually been performed?
2. `[?]` MFA for owner accounts before S4 — required or not?
3. `[?]` Breach-notification obligations for a Bangladesh operator with EU users (legal, not
   engineering).
4. `[?]` **An encrypted-backup destination that is genuinely $0, automated, and not the same
   vendor as the primary database.** Unresolved; §10 explains why each candidate fails. Blocks the
   S3 gate.
5. `[?]` Does `pg_dump` work through Supavisor session mode, so an IPv4-only network can take a
   full-fidelity backup without the paid IPv4 add-on?
6. `[?]` Can a paid AI credential be distinguished from an unpaid one by any API response? If not,
   R-A8 stands permanently.
7. `[?]` Is `org_region` the right granularity for the EU/UK rule, given the clause concerns where
   *users* are and an org can have members in several jurisdictions?
8. `[?]` Should the audit log be mirrored to an append-only external sink before S4, accepting a
   cost, or is R-A7 acceptable indefinitely?
9. `[?]` Is RSA-OAEP available through WebCrypto in a Supabase Edge Function (Deno)? ADR-013
   assumes it. **The automated backup tier must not be described as implemented until this is
   confirmed and the function exists** — today it is a specification only.
10. `[?]` Should privileged RPCs additionally check a per-user `token_valid_after` timestamp, so a
    signed-out user's unexpired access token stops working immediately? Unresolved for S4.
11. `[?]` Where do `unresolved` jobs raise an alert the owner will actually see? Without an answer,
    the R4 correction converts a duplicate-post risk into a silent missed-post risk.
