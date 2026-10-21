# ARCHITECTURE.md

Architecture, system boundaries, and the decision log.
Markers follow the legend in `CLAUDE.md` §0. Last updated 2026-10-20.

---

## 1. What this system is

A scheduled content pipeline with three independent concerns:

1. **Generate** text posts ahead of time from configured topics and a brand voice.
2. **Publish** them to a Facebook Page at configured times, **at most once each**, escalating to a
   human whenever "did it publish?" cannot be answered. (An earlier draft of this document said
   "exactly once". That was wrong: exactly-once delivery against an API with no idempotency key
   and no documented read-after-write consistency guarantee is not achievable. See §3.3.)
3. **Observe** itself well enough that a silent failure becomes a visible one.

It is not a social-media client, an analytics product, or a chat interface. Everything below is in
service of those three jobs, with multi-tenancy built in from the first migration and switched on
only when Meta Advanced Access permits it.

**Design priorities, in order:** (1) never publish the same post twice, (2) never leak a
credential, (3) never stop silently, (4) cost nothing, (5) write good Bangla, (6) look premium.
When two priorities conflict, the lower number wins.

---

## 2. Component boundaries

```
┌─────────────────────────────────────────────────────────────────────┐
│ BROWSER                        trust: none                          │
│   React UI. Supabase Auth JWT in memory/cookie. Anon key only.      │
│   Can read and write only rows RLS lets this user's org touch.      │
│   Holds no provider key, no Page token, no service-role key.        │
└───────────────┬─────────────────────────────────────────────────────┘
                │ HTTPS, JWT
┌───────────────▼─────────────────────────────────────────────────────┐
│ UI HOST (disposable)           trust: low                           │
│   Static assets + thin server routes. Routes may: validate input,   │
│   enqueue work, read via the user's JWT. Routes may NOT: hold the   │
│   service-role key, decrypt credentials, or call Meta / AI.         │
└───────────────┬─────────────────────────────────────────────────────┘
                │
┌───────────────▼─────────────────────────────────────────────────────┐
│ SUPABASE (core, permanent)     trust: high                          │
│   Postgres  — source of truth. RLS on every tenant table.           │
│   Auth      — identity.                                             │
│   pg_cron   — the work clock. Two schedules (publish, generate).    │
│   Edge Fns  — the only place credentials are decrypted and the only │
│               place that calls Meta or an AI provider.              │
│   Secrets   — MASTER_KEY_V1, SERVICE_ROLE_KEY (function env only).  │
└──────┬──────────────────────────────────┬───────────────────────────┘
       │ outbound only                    │ outbound only
┌──────▼───────────────┐          ┌───────▼───────────────────────────┐
│ AI PROVIDER (BYOK)   │          │ META GRAPH API v26.0              │
│ Gemini / Groq        │          │ POST /v26.0/{page-id}/feed        │
└──────────────────────┘          └───────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│ CLOUDFLARE WORKER (watchdog)   trust: low, no secrets but one token │
│   cron */15. Calls /health with a shared bearer token. Asserts:     │
│   DB reachable, no job overdue > 45 min, no credential expired.     │
│   Side effect by design: this is external traffic that keeps the    │
│   Supabase project out of inactivity pause.                         │
└─────────────────────────────────────────────────────────────────────┘
```

**Trust boundaries crossed:** browser→UI host (untrusted input), UI host→Postgres (RLS is the
gate), Edge Function→external API (outbound, allowlisted hosts), watchdog→health endpoint (shared
token, read-only, returns no tenant data).

---

## 3. Data flows

### 3.1 Generation (daily, ahead of time)

```
pg_cron 02:30 UTC
  └─> Edge Function `generate`
        1. read settings; abort if kill_switch or paused            [R9]
        2. for each org: count posts with status='approved'
        3. if count < target_buffer:
             pick topic by weight and last_used_at
             decrypt that org's provider credential                 [R7]
             refuse if credential.tier='unpaid' and org is EU/UK     [V]
             call provider -> draft
             critic pass -> reject fabrication, off-ratio, off-length [R8]
             reject on content_hash collision or opening_hash repeat
             insert post via the service role (clients hold no insert grant)
               counts + bangla_ratio computed here (Intl.Segmenter)
               content_hash + opening_hash derived by a DB trigger, not here
             status='draft' or 'approved' per org setting
        4. write usage counters and an audit row
```

**Why ahead of time:** publication must never depend on an AI provider being up or in quota at
that moment. The buffer target is 2–3 days of posts. `[D]` ADR-008.

### 3.2 Publishing (every minute)

```
pg_cron * * * * *
  └─> Edge Function `publish`
        0. reclaim sweep for expired leases (crashed workers).
           Keyed on whether the job has EVER sent a request, not on whether
           the marker is stale for the current attempt:        [K16]
             status='claimed' AND lease_until < now()
               request_sent_at IS NULL, attempts < 3  -> 'pending'  (never sent)
               request_sent_at IS NULL, attempts >= 3 -> 'failed'
               request_sent_at IS NOT NULL            -> 'needs_verification'
                                                                    [R4]
        1. read settings; abort if kill_switch or paused            [R9]
        2. atomic claim one due job (FOR UPDATE SKIP LOCKED, 5-min lease)
        3. decrypt Page token for that social_account
        4. COMMIT request_sent_at, request_sent_attempt = attempts
               <-- separate statement, before the fetch. Stamping the attempt
                   number means the marker never needs clearing: the next claim
                   increments `attempts` and the old marker becomes stale by
                   itself. This is what makes step 0 decidable, not a guess.
        5. POST /v26.0/{page-id}/feed   body: message=<post.body>
        6. 200 + id       -> app.finalize_publish(job, fb_post_id)
                             (one transaction: job + post + counters, idempotent)
           structured
           error body     -> classify per docs/API_INTEGRATIONS.md §5.
                             NO error response ever yields 'failed'.  [K6]
                             auth / permission -> pause the org, stop
                             throttle, transient, 506, unrecognised
                                               -> 'needs_verification'
           timeout / 5xx /
           unparseable    -> status='needs_verification'            [R4]
                             NEVER 'pending'
```

A job later than its 45-minute window is **skipped**, not published late. Posting a 07:30 slot at
14:00 is worse than not posting it.

### 3.3 Ambiguous-outcome recovery (the critical path)

**What this system provides is an at-most-once *application-level property* with escalation — not
a guarantee.** `[K22]` It is not exactly-once, and no amount of retry logic would make it so. It is
also not a guarantee against duplicate publication: the application bounds what *it* issues, never
what Facebook receives or creates. See `docs/SECURITY.md` **R-A10** for the four ways the bound can
still be exceeded. `[V] 2026-10-20` The
`/{page-id}/feed` reference documents no idempotency-key parameter, so a read-back is the only
available evidence — and a read-back is evidence, not proof.

```
Edge Function `verify`  (runs before `publish` claims new work)
  0. abort if kill_switch — a read is still an outbound call      [R9]
     (`paused` does NOT stop verification; see docs/DATABASE.md §5.5)

  for each job in status='needs_verification', on a backoff
  (verify_attempts 1..4, roughly +1, +5, +15, +60 min):

    GET /v26.0/{page-id}/published_posts
        ?fields=id,message,created_time
        &since={request_sent_at - 120s}        <-- the job's FIRST send  [K5]
        &limit=50
      follow paging.next, at most 5 pages

    COVERAGE TEST — complete if EITHER holds:                        [K9]
      (a) the oldest post returned has created_time earlier than the
          window start  (we have read past the window), OR
      (b) no further page cursor was returned (end of Page history).
    Otherwise coverage is INCOMPLETE and the read is classified a
    READ FAILURE, never an absence.

    compare each returned `message` to the post body:
      exact match on the normalised text            -> MATCH
      first 100 graphemes identical AND created_time
        inside the attempt window                   -> MATCH, flag for review
      first 100 graphemes identical, created_time
        outside the window or absent                -> NOT a match    [K10]
      otherwise                                     -> no match

      exactly one MATCH    -> record fb_post_id, status='published' (recovered)
      MORE THAN ONE MATCH  -> status='unresolved'  ⇒ HUMAN             [K11]
                              (any selection would be a guess)
      read OK, complete coverage, no match,
        verify_attempts < 4 -> wait for the next backoff step
        verify_attempts >= 4-> status='unresolved', escalated_at=now()  ⇒ HUMAN
      read FAILED, or coverage incomplete
                           -> stay 'needs_verification', alert, change nothing
      window closes while
        still indeterminate -> status='unresolved', escalated_at=now()  ⇒ HUMAN
```

**A complete-coverage read that finds nothing establishes "not found at time T", never
"was not created".** `[K9]` Absence is used for exactly three things: continuing the backoff,
escalating to `unresolved`, or — with a guarded human attestation — authorising one further
request. It is never grounds for `failed`.

### 3.3.1 The confirmation read behind a human `not_published` `[K15]`

`app.resolve_job('not_published')` does not act on the operator's word alone. It runs a fresh read
with the procedure above and decides:

| Confirmation read result | Outcome |
|---|---|
| Exactly one match | **Attestation rejected and overridden** → `published`, real id recorded, operator shown the post |
| Complete coverage, no match, `attestation_count = 0` | Accepted → `pending`, `attestation_count := 1` |
| Complete coverage, no match, `attestation_count = 1` | **Refused** — one attestation per job. Only `published` or `indeterminate` remain |
| More than one match | Refused → stays `unresolved` |
| Read failed, or coverage incomplete | Refused → stays `unresolved`; the operator retries later |

The settling delay this relies on is already guaranteed: `unresolved` is reachable only after the
four-step backoff closes, so roughly an hour has passed since the first send. `[A]` That lower
bound should be asserted by a test rather than assumed.

**There is no automatic route from `needs_verification` back to `pending`.** An earlier revision
of this document ended the backoff with a "bounded requeue" to `pending` after four clean reads.
That was a contradiction of R4 hiding inside a safety mechanism: four reads that found nothing mean
we stopped looking, and with no documented consistency guarantee that is not the same as the post
being absent. Only a human may assert absence, through `app.resolve_job('not_published')`.

Note also that `attempts >= 3 ⇒ failed` applies **only** on the never-sent path. A job in
`needs_verification` or `unresolved` must never be marked `failed`, because `failed` asserts the
post was not created and here we do not know that. `docs/DATABASE.md` §5.2.1 tabulates what each
terminal state claims.

**Why the backoff and the `unresolved` state exist — the five ways a read-back can mislead:**

1. **Delayed visibility.** `[A]` Meta publishes no read-after-write consistency guarantee for
   `published_posts`. A post created a second ago may not be returned yet. A single check followed
   by a requeue — which an earlier draft of this document specified at a flat 3 minutes — would
   therefore republish a post that exists but is not yet visible. That arbitrary 3-minute figure
   was the most dangerous line in the original design.
2. **Pagination.** The edge is cursor-paginated; reading only the first page can miss the post.
   Hence `paging.next` traversal with a bounded page count.
3. **Permissions.** Reading requires `pages_read_engagement` `[V]`. If the token was invalidated
   between publish and verify, the read fails — which must keep the job in
   `needs_verification`, never advance it.
4. **Text normalisation.** `[A]` Facebook may normalise whitespace or otherwise alter the stored
   message, so an exact hash comparison can produce a false negative. Hence the
   normalised-text comparison plus a prefix fallback that flags rather than silently accepts.
5. **Content collision.** Two identical bodies in one org are already impossible
   (`unique (org_id, content_hash)`), but a post the owner wrote by hand with the same opening
   could match the prefix rule. That is why a prefix match is flagged for review.

**What *is* structurally guaranteed**, as distinct from what is merely likely:
`unique (org_id, run_date, slot_id)` means a slot can never hold two jobs; `unique (post_id)` means
a post can never be attached to two jobs; the atomic claim means two workers cannot hold one job;
and `request_sent_attempt` means a crash is classifiable rather than ambiguous. Those four are
constraints. Everything else in this section is best-effort recovery, and when best-effort runs
out the system stops and asks a person. See `docs/DATABASE.md` §5.2–5.5.

### 3.4 Health and watchdog

`/health` (Edge Function, shared-token auth) returns a small JSON summary: DB reachable, counts by
job status, oldest overdue job age, count of credentials needing reauth. It returns **no tenant
content**. The Worker alarms on: non-200, overdue > 45 min, any `needs_verification` older than
15 min, any `reauth_required` credential.

---

## 4. Deployment stages

See `CLAUDE.md` §4 for the full table. Architectural consequences:

| Stage | What changes architecturally |
|---|---|
| S1 local | Supabase local or a free dev project; Edge Functions run via the local runtime; no watchdog |
| S2 personal | One org row, one social account, real Page. Watchdog live. Vercel Hobby acceptable **only while non-commercial** `[V]` |
| S3 pilot | Multiple orgs exercised for real. UI moved to a host with no commercial-use clause `[D]`. Per-org quotas enforced |
| S4 commercial | Advanced Access; public sign-up; billing; paid plan on whichever platform hits its ceiling first |

---

## 5. Free-tier limits and upgrade triggers

All figures `[V] 2026-10-20` from vendor documentation.

| Service | Free allowance | What breaks first | Upgrade trigger / cost |
|---|---|---|---|
| Supabase | 500 MB DB · 5 GB egress + 5 GB cached · 500k Edge invocations/mo · 2 active projects · **paused after 1 week inactivity** · **no automatic backups** | Project count (prod + staging = 2) and absence of backups | Pro ≈ $25/mo. Needed for a 3rd project, managed backups, or no-pause |
| Cloudflare Workers | 100k req/day · **10 ms CPU per invocation** · **5 cron triggers per account** · 50 subrequests per invocation | 10 ms CPU if the watchdog does real work | Workers Paid, **$5/mo minimum** |
| Vercel Hobby | 1M function invocations · 100 GB fast data transfer · 4 CPU-hrs · **non-commercial personal use only** | The commercial-use clause, not a quota | Pro $20/mo at first commercial use |
| Gemini (BYOK) | Free tier exists for the Flash line; **no published RPM/TPM/RPD** | Unknowable in advance — treat as unreliable by design | Customer's own paid tier |
| Groq (BYOK) | `[A]` Free-plan limits are not published; official docs show Developer-plan figures only (e.g. `openai/gpt-oss-120b`: 30 RPM / 1K RPD / 8K TPM / 200K TPD) | Unknown | Customer's own paid tier |
| GitHub Actions | 2,000 min/mo on private repos; standard runners free on public repos | Not a constraint at CI-only usage | — |

**Sizing sanity check:** 5 posts/day × 2 KB ≈ 3.7 MB/year of post text. The 500 MB limit is not a
real constraint for years. Edge invocations: 1/min publish + 1/min verify ≈ 88k/mo, within 500k.
`[A]` These estimates assume a single-digit number of orgs; re-run them before S4.

---

## 6. Decision log (ADRs)

### ADR-001 — One central Supabase project, not customer-provided databases
**Context.** A BYO-database option was considered so tenants could hold their own data.
**Options.** (A) one central project with RLS; (B) each tenant supplies Supabase credentials.
**Decision.** (A). `[D]`
**Consequences.** We hold all tenant data and carry that responsibility. We do **not** hold
god-mode credentials to databases we don't control; RLS is meaningful because nobody holds a
bypass key except our own job runtime; one migration path; no arbitrary outbound database
connections, which removes an SSRF and internal-pivot surface.
**Why (B) was rejected.** A service-role key for someone else's project is unbounded liability;
RLS gives nothing when the holder can bypass it; migrations across N projects have no
transactional guarantee; every tenant's pause, quota, or rotation becomes our incident.
**Revisit when.** An enterprise prospect requires data residency we cannot otherwise meet. Then
build it as a least-privilege integration (dedicated non-superuser role, single schema, host
allowlist, pinned egress IP), never as "paste your service-role key."

### ADR-002 — The job engine lives in Supabase, not in the UI host
**Context.** Scheduling could live in the UI platform (Vercel Cron), in CI (GitHub Actions), or in
the database.
**Decision.** `pg_cron` → Edge Functions. `[D]`
**Consequences.** The UI host becomes disposable: replacing it costs a day, not a rewrite. Work
runs outside request handlers `[R6]`. Cost: Edge Functions are a second runtime (Deno) to learn,
and the engine dies if the Supabase project pauses — which ADR-003 addresses.
**Revisit when.** Edge Function invocations approach 500k/mo, or a job needs more than the
function execution limit. `[?]` The current per-invocation wall-clock limit for Supabase Edge
Functions is unverified and must be confirmed before a job is designed to run long.

### ADR-003 — An external watchdog on Cloudflare Workers
**Context.** A scheduler cannot detect its own death. `[V]` Supabase pauses Free projects after
one week of low activity, and `[A]` it is unverified whether internal pg_cron activity counts as
the "user activity" that prevents a pause.
**Decision.** A Cloudflare Worker on a `*/15` cron calls `/health` from outside. `[D]`
**Consequences.** Two independent failure domains. The heartbeat is real external traffic, which
`[A]` should prevent inactivity pause — this assumption must be validated by observation during
S2, not trusted. Cost: one more platform, and `[V]` the free Worker CPU ceiling is 10 ms per
invocation, so the Worker must stay trivial.
**Revisit when.** Observation shows pausing still occurs, or the watchdog needs real logic.

### ADR-004 — Next.js now, Vite SPA as the escape hatch `[?]` OPEN
**Context.** Next.js is preferred, but the target host may be Cloudflare, where Next.js runs via
`@opennextjs/cloudflare`.
**Decision.** Deferred pending a one-day spike. `[?]`
**Consequences.** Until the spike, no code may depend on a Next.js-only server feature beyond
basic App Router routing. Nothing in the core packages may import from `next/*`.
**Revisit.** Immediately — this blocks the first UI commit.

### ADR-005 — GitHub Actions is CI/CD only, never the scheduler
**Context.** Actions is free and reliable enough, and was the natural first choice.
**Decision.** Excluded from the runtime path. `[D]`
**Why.** `[V] 2026-10-20` GitHub's additional-product terms prohibit using Actions for *"the
provision of a stand-alone or integrated application or service offering the Actions product or
service"* commercially, for *"any activity that places a burden on our servers, where that burden
is disproportionate to the benefits provided to users"* — with the explicit example *"don't use
Actions as a content delivery network or as part of a serverless application"* — and, on
GitHub-hosted runners, for *"any other activity unrelated to the production, testing, deployment,
or publication of the software project."* A product's production scheduler is exactly that.
**Consequences.** We give up the simplest free scheduler and accept ADR-002/003 instead.
**Revisit.** Only if GitHub's terms change.

### ADR-006 — App-layer envelope encryption, not Supabase Vault, for tenant credentials
**Context.** Vault is the obvious built-in choice for secrets in Postgres.
**Decision.** AES-256-GCM in the application layer; master key in function environment only. `[D]`
**Why.** `[V] 2026-10-20` Vault's documentation warns that *"anyone that has access to the view
has access to decrypted secrets"*, and the project root key is retrievable through the Management
API. That puts the decryption boundary inside the database, where RLS mistakes and dashboard
access become credential disclosure. We want the boundary outside the database, so that a full
database compromise yields ciphertext only.
**Consequences.** We own key management, including rotation and the risk of losing the master key
(which would make every stored credential unrecoverable — see `docs/SECURITY.md` §6).
**Revisit when.** A managed KMS becomes available at $0, or Vault's key handling changes.

### ADR-007 — Multi-tenant schema from day one, operated single-tenant
**Context.** A single-tenant MVP would be simpler to write.
**Decision.** Every tenant table carries `org_id` and RLS from the first migration, even while
exactly one org row exists. `[D]`
**Consequences.** Slightly more ceremony now; no retrofit later. Retrofitting tenancy onto a live
schema with real tokens is the kind of migration that causes cross-tenant leaks.
**Revisit.** Never. This is cheap now and expensive later.

### ADR-008 — Generation is decoupled from publication by a buffer
**Decision.** A daily job maintains 2–3 days of `approved` posts; the publisher only reads. `[D]`
**Consequences.** An AI outage or quota change is invisible for days. Cost: posts are written
further ahead of their publication date, so topical content needs a manual path.
**Revisit when.** Users ask for same-day topical posting; then add an explicit "generate now" path
that is still not on the publish clock.

### ADR-009 — At-most-once delivery with human escalation, not exactly-once
**Context.** The original wording of this document promised that each post is published "exactly
once" and that duplicates were "impossible". Both claims were false. `[V]` The feed endpoint
documents no idempotency key, and `[A]` Meta publishes no read-after-write consistency guarantee
for `published_posts`, so after a timeout the system cannot always determine ground truth.
**Options.** (A) retry after a fixed delay and accept a small duplicate risk; (B) never retry and
accept silent misses; (C) bounded verification, then escalate to a human.
**Decision.** (C). `[D]`
**Consequences.** A genuine ambiguity costs the owner a 30-second look at their Page instead of
risking a duplicate post under their name. The cost is a state no automation can clear
(`unresolved`) and a UI surface to resolve it. For a brand account, a duplicate is a worse failure
than a delay, which is what makes the trade obvious.
**Why (A) was rejected.** It is what the first draft specified, via "no match after 3 minutes ⇒
requeue". The 3 minutes had no vendor basis. A second revision replaced it with "four clean reads
⇒ requeue", which was the same mistake with more steps: a bounded number of reads finding nothing
is still not proof of absence. Both are now explicitly forbidden transitions.
**Revisit when.** Meta documents an idempotency parameter or a consistency guarantee.

### ADR-011 — Clients get column privileges, not just row policies
**Context.** RLS filters rows. It does not filter columns, so a member with `select` on
`provider_credentials` could read `ciphertext`, and a `for all` policy let them overwrite it.
**Decision.** `revoke all ... from anon, authenticated`, then grant back an explicit column list.
Credentials and Page tokens get **no** client write path at all; those writes happen in an Edge
Function that holds the master key. `[D]`
**Consequences.** `select *` on those tables now fails for clients, which is why
`provider_credentials_safe` exists. Every new column is deny-by-default, so a future migration
that adds a sensitive column cannot leak it by omission — the opposite of the previous design.
**Revisit.** Never. This is the correct default.

### ADR-012 — Every tenant foreign key carries `org_id`
**Context.** `posts.topic_id → topics(id)` constrains existence, not ownership, and RLS's
`with check` validates only the inserted row's own `org_id`.
**Decision.** Composite unique targets plus composite foreign keys on all four tenant references.
`[D]`
**Consequences.** Requires `[V]` PostgreSQL 15+ for the `on delete set null (column)` clause;
documented fallback is `on delete restrict` plus soft-deleting topics. Protects against service-role
bugs, which RLS by definition cannot.
**Revisit.** Never.

### ADR-010 — BYOK is mandatory, with a tier flag
**Decision.** Tenants supply their own AI key; the record carries `tier`. `[D]`
**Why.** Cost, blast radius, and `[V]` Gemini's terms: unpaid-tier content is used for product
improvement and may be read by human reviewers, and only Paid Services may be used when making an
API client available to users in the EEA.
**Consequences.** Onboarding friction (the user must get a key); offset by key validation with a
live test call at save time.
**Revisit when.** A provider offers terms that permit a platform-supplied key for third parties.

### ADR-013 — The automated backup encrypts to a public key; the private key never goes online
**Context.** The two-tier backup plan called for an Edge Function to encrypt each export with a
symmetric `BACKUP_ENCRYPTION_KEY`, while the secret inventory required that key to live only in the
owner's offline store. Both could not be true. And a symmetric key usable by the runtime is by
definition a key an attacker who reaches the runtime can also use — to read **every past backup**.
**Options.** (A) hold a symmetric key in the function environment and accept that exposure;
(B) drop the automated tier and rely on the manual `pg_dump` alone; (C) hybrid public-key
encryption, where the runtime holds only a public key.
**Decision.** (C). `[D]`
**How.** Per export: generate a random AES-256-GCM data key, encrypt the JSON export with it,
encrypt that data key to `BACKUP_PUBLIC_KEY` (RSA-OAEP), store both blobs. Decryption requires
`BACKUP_PRIVATE_KEY`, which exists only offline, in two copies, in a location separate from
`MASTER_KEY_V*` — so one compromised location cannot yield both the archive and the credentials
inside it.
**Consequences.** A fully compromised Edge Function cannot read any existing backup, which is the
property (A) cannot offer. It **can** substitute its own public key so that *future* exports become
readable by the attacker and unreadable by the owner; that is detected, not prevented — the key
fingerprint is written to `audit_logs` on every export and verified during the restore drill
(R-A9). `[A]` RSA-OAEP via WebCrypto in Deno is assumed available and `[?]` must be confirmed
before this tier may be described as implemented.
**Why (B) was rejected.** It would leave the only backup dependent on the owner remembering, which
is how data actually gets lost.
**Revisit when.** A $0 managed KMS, or an off-vendor automated destination, becomes available.

### ADR-014 — Posts have no client write path, and the hash is derived in the database
**Context.** `posts` carries six `NOT NULL` derived columns, two of which (`content_hash`,
`opening_hash`) back the duplicate-prevention control. The original design granted a client
`insert (org_id, topic_id, brand_voice_id, body)` and `update (body)`. That could not execute — the
six derived columns were outside the grant — and the repair that looks obvious is unsafe: an
accepted `update (body)` leaves `content_hash` describing the previous text, so
`posts_content_hash_key` stops preventing duplicates and nothing reports it. Granting the hash
columns instead would let a client forge a hash outright.
**Options.** (A) grant the derived columns and trust the client; (B) client writes the body while a
database trigger recomputes the hashes; (C) no client write path, with the grapheme-aware work in
an Edge Function; (D) make the derived columns nullable and fill them at approval.
**Decision.** **(C) as the write path, with (B)'s trigger underneath it.** `[D]`
**How.** `authenticated` keeps `select` and `delete` on `posts` and nothing more. `generate` and a
new `update-post-body` Edge Function write posts with the service role, computing the counts with
`Intl.Segmenter` — which exists in Deno and not in Postgres, and is why this cannot be a plain SQL
RPC. `posts_hash_guard` then recomputes both hashes from `body` on every insert and update,
discarding whatever the writer supplied.
**Consequences.** Editing a draft becomes a function round trip instead of a direct `update`;
at five posts a day that costs nothing. More importantly the two layers protect different things:
the missing grant stops a client, and the trigger stops a *trusted* writer — including a
service-role bug, which RLS and column privileges by definition cannot catch. This is the same
reasoning as ADR-012: a control that survives a service-role mistake is worth more than one that
assumes there won't be any. The hash definitions move into SQL and become canonical, so
`opening_hash` is defined on whitespace-separated tokens rather than `Intl.Segmenter` word
segments; `docs/DATABASE.md` §6.3 records why that divergence is deliberate.
**Why (D) was rejected.** It would leave rows where the NOT NULL invariants do not hold and push
extra states into every reader.
**Revisit when.** Postgres gains grapheme-aware segmentation, which would allow the counts to be
derived in-database too.

---

### ADR-015 — pg_net's request queue is readable by PUBLIC, and cannot be closed
**Context.** The job engine reaches an Edge Function by having `pg_cron` call `pg_net`, which queues
the request in `net.http_request_queue` for a background worker to send. Measured on the hosted
development project `[V] 2026-10-22`: PUBLIC holds `arwdDxtm` — insert, select, update, delete,
truncate, references, trigger, maintain — on `net.http_request_queue` and `net._http_response`, and
`rwU` on the queue's sequence; `anon` and `authenticated` additionally hold `USAGE` on the schema.
The vendor documents this as object-level access "for example, `SELECT`"; it is the full set.
**Options.** (A) revoke the grants in a migration; (B) accept them and constrain what may travel
through the queue; (C) abandon `pg_net` and drive the clock from the Cloudflare Worker of ADR-003.
**Decision.** **(B).** `[D]` (A) was attempted in migration `20261022203000` and does nothing:
every grant carries `/supabase_admin`, PostgreSQL lets a role revoke only grants it made itself or
reaches as owner or superuser, and migrations run as `postgres`, where
`pg_has_role(current_user,'supabase_admin','member')` is `false` `[V] 2026-10-22`. A revoke matching
no grant the caller made is not an error — it succeeds silently, which is why that migration
reported success. `20261022213000` records the correction forward, because R10 forbids editing a
merged migration.
**Consequences.** Two constraints bind anything built on `pg_net`. First, **no secret may travel in
a request header**: the queue row holds the header and the queue is readable. An Edge Function
invoked this way authenticates its caller some other way. Second, **a direct insert into the queue
reaches the network without passing through job code**, so R9's kill switch cannot cover that path;
the switch remains correct for every path the application controls, which today is every path that
exists.
**How large this is.** Smaller than it first appears, and latent rather than live. A PUBLIC grant
only reaches a role that can log in; `anon`, `authenticated` and `service_role` are `NOLOGIN`, and
whoever holds the `postgres` password already controls the database, so the queue is no escalation
for them. The exposure is that any login-capable role created later — a reporting role, say —
inherits full DML on the outbound queue automatically and cannot be stripped of it.
**Why (C) was not taken now.** It is a larger decision than this finding supports on its own. The
finding feeds it; `docs/JOBS_AND_SCHEDULING.md` §2 settles it.
**Revisit when.** Supabase changes the default grants, a second login-capable role is proposed, or
the clock design is decided. `supabase/tests/verify_hosted.sql` reports the live ACLs and is where a
change would surface.

---

### ADR-016 — Migrations deploy from GitHub Actions, behind four gates, from a public repository
**Context.** The owner's machine cannot reach the database: the direct host is IPv6-only and
unreachable, and the Supavisor pooler times out from that network. GitHub's runners reach it `[V]
2026-10-22`. ADR-005 permits Actions for deployment while forbidding it as the production
scheduler, so a deployment workflow is in scope and a job clock is not.
**Options.** (A) apply migrations by hand in the Supabase SQL editor; (B) Actions with a single
manual trigger; (C) Actions on every push to `main`.
**Decision.** **(B).** `[D]` (A) violates R10. (C) makes a merge a database write, which is the
wrong default for a forward-only schema. Four independent gates: `workflow_dispatch` only; a typed
`apply` confirmation passed through the environment rather than interpolated into a shell, since the
input is attacker-controllable on a public repository; a GitHub Environment with a required
reviewer and `can_admins_bypass: false`; and target verification before `link`. A dry run always
runs first, so the log records what was about to be applied.
**Consequences.** Required reviewers are a paid feature on a **private** repository and free on a
public one, so the gate and the secrecy of the specifications are in direct tension on a $0 budget.
The repository is public `[D]`, which makes the gate real and the design documents world-readable.
Workflow logs are world-readable with it, so the project ref is stored as a **secret** rather than a
variable — GitHub then masks it even inside Supabase CLI error text, which was observed working
`[V] 2026-10-22` — while a four-character fingerprint, too short to mask, still prints so a reviewer
can confirm the target. The test workflow deliberately holds no credential at all, which is why it
needs none of the same-repository guard the dry-run workflow requires.
**Why the fingerprint is not simply omitted.** A reviewer approving a database write needs to know
which database. Printing nothing would make the approval ceremonial.
**Revisit when.** The repository is made private — the reviewer gate dies with it and Gate 2 would
have to carry the weight — or a production project exists, at which point a single account-wide
Supabase access token is no longer an acceptable way to reach both.

---

## 7. Rejected alternatives, briefly

| Rejected | Reason |
|---|---|
| Browser automation / unofficial endpoints | Violates platform policy; brittle; account risk |
| Vercel Cron as the clock | `[V]` Hobby allows one run per day with ±59 min precision |
| A paid VPS or always-on worker | Budget is $0 |
| Queue service (SQS/Upstash/etc.) | Postgres with `FOR UPDATE SKIP LOCKED` is sufficient at this volume and adds no vendor |
| Storing credentials in Supabase Vault | ADR-006 |
| Separate database per tenant | Operationally unaffordable at $0 |
| LLM call at publish time | ADR-008 |

---

## 8. Failure modes and how each becomes visible

| Failure | Blast radius | Detection | Recovery |
|---|---|---|---|
| Supabase project paused | Total stop | Watchdog `/health` non-200 | Manual restore from dashboard. `[A]` Heartbeat is expected to prevent this |
| pg_cron stops firing | No posts | Watchdog: oldest overdue job | Re-create the cron job; investigate |
| Edge Function deploy broken | No posts | Watchdog + `failed` count | Roll back the function |
| AI quota exhausted | Buffer drains over days | Buffer depth on `/health` | Fallback provider; user tops up |
| Page token invalidated | That org stops | Daily token check sets `reauth_required` | User re-authorises; automation stays paused until then |
| Ambiguous publish | One post | `needs_verification` count | Bounded read-back (§3.3); then `unresolved` for a human |
| **Worker crash mid-publish** | One post | `claimed` with an expired lease | Reclaim sweep classifies by `request_sent_at`: null ⇒ requeue, set ⇒ verify. Never a blind retry |
| **Indeterminate after verification** | One post | `unresolved` count, `escalated_at` | Owner checks the Page and resolves. No automatic action |
| Master key lost | **Unrecoverable credentials** | Decrypt failures | None. Users must re-enter keys and re-authorise Pages. See `docs/SECURITY.md` §5 |
| Database lost | **Total data loss** | — | `[V]` The free plan has no automatic backups, so a self-managed export is mandatory — and `[V]` `pg_dump` needs the **direct connection and the database password**, which is IPv6-only on the free plan. See `docs/SECURITY.md` §10, where this is a partially unresolved problem |

---

## 9. Open questions

1. `[?]` **ADR-004** — Next.js on Cloudflare via OpenNext, or Vite SPA? Blocks the first UI commit.
2. `[?]` **UI host for S2** — Vercel Hobby (compliant while non-commercial, better DX, forces a
   migration before S3) or Cloudflare Pages (no migration)? Recommendation: Cloudflare.
3. `[?]` **Supabase Edge Function execution limit** — unverified; confirm before designing any
   long-running job.
4. `[?]` **Does pg_cron activity alone prevent inactivity pause?** Must be observed in S2.
5. `[?]` **Legal business entity** for Business Verification — gates S3/S4 entirely.
6. `[?]` **Bangladesh-specific Business Verification document list** — unverified.
7. `[?]` **EU/UK legal review** before any EU launch — out of engineering scope.
8. `[?]` **Posting frequency** — 5/day was the original target; `[A]` for a small Page this may
   suppress distribution. Consider starting at 2–3/day and measuring.
9. `[?]` **Backup transport and destination** — `[V]` `pg_dump` requires the direct connection
   (IPv6-only on the free plan; IPv4 is a paid add-on) and the database password. No $0
   destination has been settled. See `docs/SECURITY.md` §10. **This is the largest unresolved
   operational risk in the project** and it blocks the S3 gate, not the S2 build.
10. `[?]` **Does `app.finalize_publish` run on the same connection as the publish attempt?** If an
    Edge Function cannot hold a transaction across the HTTP boundary, the finalize must be a single
    RPC call — which is why it is specified as one. Confirm the Supabase Edge Function database
    client supports an explicit transaction.
11. `[?]` **Where does an `unresolved` job surface?** It needs a UI affordance and an alert channel
    before S2 goes unattended, or the escalation state is a silent dead end. Now more urgent: after
    the R4 correction, `unresolved` is the **only** automatic destination for an indeterminate
    publish, so the queue will reach it more often than the earlier design implied.
12. `[?]` **RSA-OAEP via WebCrypto in a Supabase Edge Function (Deno)** — assumed available by
    ADR-013; confirm before the backup export is written.
13. `[?]` **Per-user `token_valid_after` check** on privileged calls, so a signed-out user's
    unexpired access token stops working immediately. Unresolved; see `docs/DATABASE.md` §6.2.

---

## 10. Sources

Checked 2026-10-20. Re-verify quarterly.

- Graph API changelog (current version) — developers.facebook.com/docs/graph-api/changelog/
- Page feed publishing — developers.facebook.com/docs/graph-api/reference/page/feed/
- Access levels (Standard vs Advanced) — developers.facebook.com/docs/graph-api/overview/access-levels/
- Business Verification — developers.facebook.com/docs/development/release/business-verification
- Long-lived tokens — developers.facebook.com/docs/facebook-login/guides/access-tokens/get-long-lived
- Graph API rate limiting — developers.facebook.com/docs/graph-api/overview/rate-limiting/
- Gemini API terms — ai.google.dev/gemini-api/terms
- Gemini pricing and free tier — ai.google.dev/gemini-api/docs/pricing
- Groq rate limits — console.groq.com/docs/rate-limits
- Supabase pricing — supabase.com/pricing
- Supabase production checklist (pausing) — supabase.com/docs/guides/platform/going-into-prod
- Supabase Cron — supabase.com/docs/guides/cron
- Supabase Vault — supabase.com/docs/guides/database/vault
- Cloudflare Workers limits — developers.cloudflare.com/workers/platform/limits/
- Cloudflare Workers pricing — developers.cloudflare.com/workers/platform/pricing/
- Vercel fair-use / commercial usage — vercel.com/docs/limits/fair-use-guidelines
- Vercel cron usage and pricing — vercel.com/docs/cron-jobs/usage-and-pricing
- GitHub additional product terms (Actions) — docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features
