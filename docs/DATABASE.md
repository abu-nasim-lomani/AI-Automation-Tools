# DATABASE.md

Schema, constraints, RLS, state machines, and the isolation test matrix.
Markers follow `CLAUDE.md` §0. Last updated 2026-10-20.

**Status: proposed. No migration has been written or applied.** The SQL below is a specification
to review, not a deployed schema.

---

## 1. Conventions

- Postgres (Supabase). Extensions assumed: `pgcrypto` (for `gen_random_uuid`), `pg_cron`,
  `pg_net`. `[A]` All three are available on the Supabase free plan; verify at migration time.
- `snake_case`. Primary keys are `uuid` with `gen_random_uuid()`, except high-volume append-only
  tables which use `bigserial`.
- Every tenant table carries `org_id uuid not null` and has RLS enabled.
- Timestamps are `timestamptz`, named `*_at`, stored in UTC. Local times for scheduling are stored
  as `time` plus the org's timezone, and resolved to a UTC instant when a job row is created.
- Status fields are Postgres enum types, never free text.
- Credentials are `bytea` ciphertext only — never `text`, so an accidental log of a row shows
  bytes rather than a key.

---

## 2. Entity overview

```
auth.users (Supabase)
     │ 1:1
  profiles
     │ N:M via memberships
   orgs ──1:1── org_settings
     │
     ├──< social_accounts        (Facebook Pages; encrypted token)
     ├──< provider_credentials   (BYOK AI keys; encrypted; tier flag)
     ├──< brand_voices           (tone, language ratio, length rules)
     ├──< topics                 (what to write about)
     ├──< posts ────────┐        (generated content + counts + hashes)
     ├──< schedule_slots │       (local times, per org)
     ├──< publish_jobs ──┘       (one row per org/date/slot; the work unit)
     ├──< usage_counters         (daily rollup)
     └──< audit_logs             (append-only)
```

---

## 3. Enum types

```sql
create type org_region      as enum ('bd', 'global', 'eu_uk');
create type member_role     as enum ('owner', 'member');
create type provider_kind   as enum ('gemini', 'groq');
create type credential_tier as enum ('unpaid', 'paid');
create type cred_status     as enum ('unvalidated', 'valid', 'invalid');
create type account_status  as enum ('active', 'reauth_required', 'revoked');
create type tone_kind       as enum ('conversational', 'professional', 'educational',
                                     'storytelling', 'inspirational', 'informative');
create type emoji_policy    as enum ('none', 'minimal', 'moderate');
create type post_status     as enum ('draft', 'approved', 'rejected',
                                     'published', 'failed');
create type job_status      as enum ('pending', 'claimed', 'needs_verification',
                                     'unresolved', 'published', 'failed', 'skipped');
```

`org_region` exists to enforce the EU/UK rule from `CLAUDE.md` §4: `[V]` Gemini's terms permit
only Paid Services when making an API client available to users in the EEA, so an `eu_uk` org may
not generate on an `unpaid` credential.

---

## 4. Schema

```sql
-- ─────────────────────────────── identity & tenancy ───────────────────────────────

create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  locale      text not null default 'bn-BD',
  created_at  timestamptz not null default now()
);

create table orgs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 120),
  region      org_region not null default 'bd',
  created_by  uuid not null references profiles(id),
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz                     -- soft delete; hard delete runs after revocation
);

create table memberships (
  org_id      uuid not null references orgs(id) on delete cascade,
  user_id     uuid not null references profiles(id) on delete cascade,
  role        member_role not null default 'member',
  created_at  timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index memberships_user_idx on memberships (user_id);

create table org_settings (
  org_id        uuid primary key references orgs(id) on delete cascade,
  kill_switch   boolean not null default false,   -- hard stop, checked first by every job  [R9]
  paused        boolean not null default false,    -- soft pause
  timezone      text not null default 'Asia/Dhaka',
  auto_publish  boolean not null default false,    -- false => human approval required
  target_buffer int  not null default 10 check (target_buffer between 1 and 60),
  daily_gen_cap int  not null default 20 check (daily_gen_cap between 1 and 200),
  updated_at    timestamptz not null default now()
);

-- ─────────────────────────────── credentials (encrypted) ──────────────────────────
-- Ciphertext only. See docs/SECURITY.md §5 for the envelope scheme.
-- AAD binds each blob to org_id || id || key_version, so a blob moved to another row
-- or another org fails to decrypt instead of succeeding under the wrong tenant.

create table provider_credentials (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references orgs(id) on delete cascade,
  provider          provider_kind not null,
  model             text not null,                  -- model id lives in data, not code
  tier              credential_tier not null default 'unpaid',
  ciphertext        bytea not null,                 -- AES-256-GCM, tag appended
  iv                bytea not null check (octet_length(iv) = 12),
  key_version       int   not null default 1,
  masked_hint       text  not null,                 -- e.g. 'AIza…7f2c'; last 4 chars only
  status            cred_status not null default 'unvalidated',
  last_validated_at timestamptz,
  is_default        boolean not null default false,
  created_by        uuid not null references profiles(id),
  created_at        timestamptz not null default now(),
  -- an eu_uk org may not hold an unpaid credential; enforced by trigger (see §8)
  constraint masked_hint_is_short check (char_length(masked_hint) <= 16)
);
create unique index provider_credentials_default_idx
  on provider_credentials (org_id) where is_default;
create index provider_credentials_org_idx on provider_credentials (org_id, provider);

create table social_accounts (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references orgs(id) on delete cascade,
  platform         text not null default 'facebook_page'
                     check (platform in ('facebook_page')),
  external_id      text not null,                  -- Facebook Page id
  display_name     text not null,
  token_ciphertext bytea not null,
  token_iv         bytea not null check (octet_length(token_iv) = 12),
  key_version      int   not null default 1,
  granted_scopes   text[] not null default '{}',   -- as returned by Meta, for audit
  granted_tasks    text[] not null default '{}',   -- must contain CREATE_CONTENT  [V]
  status           account_status not null default 'active',
  token_checked_at timestamptz,
  connected_by     uuid not null references profiles(id),
  created_at       timestamptz not null default now(),
  unique (org_id, platform, external_id)
);
-- One Page may be connected by only one org at a time: prevents two tenants
-- publishing to the same Page and reduces token-confusion risk.
create unique index social_accounts_external_unique
  on social_accounts (platform, external_id) where status <> 'revoked';

-- ─────────────────────────────── content configuration ────────────────────────────

create table brand_voices (
  org_id              uuid not null references orgs(id) on delete cascade,
  id                  uuid not null default gen_random_uuid(),
  name                text not null,
  tone                tone_kind not null default 'conversational',
  language_primary    text not null default 'bn',
  bangla_ratio_target numeric(4,3) not null default 0.850
                        check (bangla_ratio_target between 0 and 1),
  ratio_tolerance     numeric(4,3) not null default 0.050
                        check (ratio_tolerance between 0 and 0.5),
  min_graphemes       int not null default 400  check (min_graphemes >= 1),
  max_graphemes       int not null default 1400,
  word_target_min     int,
  word_target_max     int,
  hashtag_max         int not null default 3 check (hashtag_max between 0 and 10),
  emoji_pref          emoji_policy not null default 'minimal',
  opening_style       text,
  closing_style       text,
  custom_instructions text,                        -- untrusted data, see SEC-15
  exclusions          text[] not null default '{}',-- banned words/claims
  is_default          boolean not null default false,
  created_at          timestamptz not null default now(),
  primary key (id),
  unique (org_id, id),                        -- composite-FK target, see §4.1
  check (max_graphemes > min_graphemes),
  check (word_target_max is null or word_target_min is null
         or word_target_max >= word_target_min)
);
create unique index brand_voices_default_idx on brand_voices (org_id) where is_default;

create table topics (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references orgs(id) on delete cascade,
  title         text not null check (char_length(title) between 1 and 200),
  instructions  text check (char_length(instructions) <= 4000),
  weight        int not null default 1 check (weight between 0 and 10),
  enabled       boolean not null default true,
  last_used_at  timestamptz,
  created_at    timestamptz not null default now(),
  unique (org_id, title),
  -- Required so other tenant tables can reference this row with a COMPOSITE
  -- foreign key that carries org_id. See §4.1.
  unique (org_id, id)
);
create index topics_pick_idx on topics (org_id, enabled, last_used_at nulls first);

-- ─────────────────────────────── content ──────────────────────────────────────────

create table posts (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  -- Single-column FKs are deliberately NOT used here: they would allow a post in
  -- org B to reference a topic in org A. Composite FKs are declared below. §4.1
  topic_id        uuid,
  brand_voice_id  uuid,
  body            text not null,
  -- three distinct counts; see §7. grapheme_count is the user-facing number.
  grapheme_count  int not null check (grapheme_count > 0),
  codepoint_count int not null,
  word_count      int not null,
  bangla_ratio    numeric(4,3) not null check (bangla_ratio between 0 and 1),
  -- Both hashes are DERIVED IN-DATABASE by the posts_hash_guard trigger (§8) on
  -- every insert and update, from `body`. No writer — client, Edge Function, or
  -- service role — can supply a value that disagrees with the body it describes.
  -- §6.3 gives the canonical definitions. [B-1]
  content_hash    text not null,      -- sha256 of the NFC-normalised, whitespace-collapsed body
  opening_hash    text not null,      -- sha256 of the first 8 tokens; anti-repetition
  status          post_status not null default 'draft',
  provider        provider_kind,
  model           text,
  prompt_version  text,
  critic_notes    jsonb,              -- why a draft was rejected or flagged
  approved_by     uuid references profiles(id),
  approved_at     timestamptz,
  published_at    timestamptz,
  fb_post_id      text,
  created_at      timestamptz not null default now(),
  unique (org_id, id),                        -- composite-FK target, see §4.1
  -- A post may only reference its own org's topic and brand voice.
  -- `on delete set null (col)` nulls ONLY that column, leaving org_id intact.
  -- [V] Column lists for ON DELETE SET NULL require PostgreSQL 15 or later
  -- (added in PG 15 explicitly for multi-tenant keys that include a tenant id).
  constraint posts_topic_same_org foreign key (org_id, topic_id)
    references topics (org_id, id) on delete set null (topic_id),
  constraint posts_voice_same_org foreign key (org_id, brand_voice_id)
    references brand_voices (org_id, id) on delete set null (brand_voice_id)
);
-- Duplicate prevention is a constraint, not a check in code.
create unique index posts_content_hash_key on posts (org_id, content_hash);
-- Scoped to the org on purpose. A GLOBAL unique index on fb_post_id would let one
-- tenant insert a guessed or scraped fb_post_id and permanently block another
-- tenant's finalize step with a unique violation — a cross-tenant denial of
-- service through a shared key space. [F-05]
create unique index posts_fb_post_id_key   on posts (org_id, fb_post_id)
  where fb_post_id is not null;
create index posts_pick_idx    on posts (org_id, status, created_at);
create index posts_opening_idx on posts (org_id, opening_hash, created_at desc);

-- ─────────────────────────────── scheduling & jobs ────────────────────────────────

create table schedule_slots (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  local_time time not null,                  -- interpreted in org_settings.timezone
  enabled    boolean not null default true,
  created_at timestamptz not null default now(),
  unique (org_id, local_time),
  unique (org_id, id)                         -- composite-FK target, see §4.1
);

-- The work unit. One row per (org, date, slot) makes a duplicate job
-- structurally impossible rather than merely unlikely.  [R4]
create table publish_jobs (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  run_date        date not null,             -- local date in the org's timezone
  slot_id         uuid not null,
  scheduled_at    timestamptz not null,      -- resolved UTC instant
  post_id         uuid,
  status          job_status not null default 'pending',
  attempts        int not null default 0 check (attempts >= 0 and attempts <= 10),
  verify_attempts int not null default 0 check (verify_attempts >= 0),
  lease_until     timestamptz,
  claimed_at      timestamptz,               -- read-back window anchor (§5.3)
  -- Written and COMMITTED immediately before the Graph API request is issued.
  -- The two columns are DELIBERATELY ASYMMETRIC and the asymmetry is
  -- load-bearing: [K21]
  --   request_sent_at      WRITE-ONCE. The timestamp of the job's FIRST
  --                        request. Never overwritten, never reset, by any
  --                        path, human or automatic. Enforced by the
  --                        request_sent_at_immutable trigger (§8), not only by
  --                        every writer remembering `coalesce`.
  --                        It is the read-back window anchor (§5.4): if it were
  --                        per-attempt, the window would exclude a post created
  --                        on attempt 1, which is the failure K5 fixes.
  --   request_sent_attempt OVERWRITTEN each attempt. The LATEST attempt that
  --                        sent. Retained for forensics and for bounding the
  --                        post-attestation attempt. It is NOT the basis of any
  --                        requeue decision — see §5.3. [K16]
  -- `request_sent_at IS NULL` is the ONLY evidence that permits an automatic
  -- requeue: it means no request has ever been issued for this job. A marker
  -- that is merely stale for the current attempt proves nothing about earlier
  -- attempts. [F-06] [K16]
  request_sent_at      timestamptz,
  request_sent_attempt int,
  escalated_at    timestamptz,               -- set when a human must decide
  -- Accepted human attestations of absence. Capped at 1, so at most two
  -- requests can ever be issued for one job: the original plus one after a
  -- guarded attestation (§5.2.3). An application-level limit, NOT a guarantee
  -- against duplicate publication — see docs/SECURITY.md R-A10. [K13] [K22]
  attestation_count int not null default 0
    check (attestation_count between 0 and 1),
  constraint request_marker_coherent check (
    (request_sent_at is null) = (request_sent_attempt is null)
  ),
  fb_post_id      text,
  last_error      text,                      -- code + safe message, never a raw body  [R3]
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (org_id, run_date, slot_id),
  constraint publish_jobs_slot_same_org foreign key (org_id, slot_id)
    references schedule_slots (org_id, id) on delete cascade,
  constraint publish_jobs_post_same_org foreign key (org_id, post_id)
    references posts (org_id, id) on delete set null (post_id)
);
-- A post may be attached to at most one job, so two slots can never publish the
-- same body. [F-04]
create unique index publish_jobs_post_unique on publish_jobs (post_id)
  where post_id is not null;
create index jobs_due_idx    on publish_jobs (status, scheduled_at)
  where status in ('pending', 'needs_verification', 'unresolved');
create index jobs_stale_idx  on publish_jobs (lease_until)
  where status = 'claimed';
create index jobs_org_idx    on publish_jobs (org_id, scheduled_at desc);

-- ─────────────────────────────── observability ────────────────────────────────────

create table usage_counters (
  org_id        uuid not null references orgs(id) on delete cascade,
  day           date not null,
  generated     int not null default 0,
  published     int not null default 0,
  failed        int not null default 0,
  provider_calls int not null default 0,
  primary key (org_id, day)
);

create table audit_logs (
  id        bigserial primary key,
  at        timestamptz not null default now(),
  org_id    uuid references orgs(id) on delete set null,
  actor     uuid references profiles(id) on delete set null,
  action    text not null,          -- 'credential.saved', 'page.connected', 'post.published', …
  target    text,                   -- opaque id, never a secret
  ip        inet,
  detail    jsonb not null default '{}'::jsonb   -- redacted before insert  [R3]
);
create index audit_logs_org_at_idx on audit_logs (org_id, at desc);
```

### 4.1 Why every tenant foreign key is composite

A single-column foreign key such as `posts.topic_id → topics(id)` constrains *existence*, not
*ownership*. RLS does not close the gap: the `with check (app.is_member(org_id))` clause on
`posts` validates `posts.org_id` only — it never inspects the org of the row being referenced. So
a member of org B could insert a post carrying `org_id = B` and `topic_id` pointing at org A's
topic, and the database would accept it. Two things make that reachable in practice rather than
theoretical:

1. **UUIDs leak.** They appear in URLs, logs, screenshots, and support threads. "Unguessable" is
   not an authorization control.
2. **The service role bypasses RLS entirely** (by design — it runs the jobs). A single bug in an
   Edge Function could therefore write cross-tenant references that no policy would catch.

The fix is to put `org_id` in the key on both sides, so the constraint itself enforces that the
two rows belong to the same tenant:

```sql
-- referenced side gains a composite unique target
alter table topics add constraint topics_org_id_key unique (org_id, id);
-- referencing side carries org_id into the key
alter table posts  add constraint posts_topic_same_org
  foreign key (org_id, topic_id) references topics (org_id, id)
  on delete set null (topic_id);
```

`[V] 2026-10-20` The `(topic_id)` column list on `ON DELETE SET NULL` requires **PostgreSQL 15 or
later**; it was added in PG 15 for exactly this case — a foreign key that includes a tenant id
which must not be nulled. `[?]` Confirm the project's server version with `select version()`
before writing the migration. **Fallback if the project is on PG 14 or earlier:** use
`on delete restrict` and never hard-delete a topic or brand voice — disable it instead (`topics`
already has an `enabled` flag). That fallback is also arguably the better product behaviour, since
deleting a topic should not silently rewrite historical posts.

Composite keys applied: `posts(org_id, topic_id)`, `posts(org_id, brand_voice_id)`,
`publish_jobs(org_id, slot_id)`, `publish_jobs(org_id, post_id)`.

**Not enforceable by a foreign key:** `posts.approved_by`, `provider_credentials.created_by`,
`social_accounts.connected_by`, and `orgs.created_by` all reference `profiles`, which has no
`org_id`. A user from another org could be recorded as the approver if application code passed the
wrong id. `[D]` Mitigated by a trigger asserting `app.is_member(org_id)` for the referenced actor
on insert, rather than by schema shape. Negative tests in §11.

---

## 5. State machines

### 5.1 `posts`

```
draft ──approve──> approved ──claimed by a job──> published
  │                   │
  └──reject──> rejected    └──publish failed──> failed ──(manual)──> approved
```
`draft → published` directly is permitted only when `org_settings.auto_publish = true`, in which
case generation writes `approved` immediately. `published` is terminal.

### 5.2 `publish_jobs`

```
pending ──claim──> claimed ──200 OK + id──> published      (finalize_publish)
   ▲                  │
   │                  ├── auth / permission error ──> pause org, alert once,
   │                  │     stop attempting; job -> needs_verification with a
   │                  │     CONFIGURATION-FAULT reason code          [K7]
   │                  │
   │                  ├── any other structured error (throttle, transient,
   │                  │     506, unrecognised) ─────────────> needs_verification
   │                  │     NO error response yields `failed`        [K6]
   │                  │
   │                  ├── timeout / 5xx / unparseable ──────> needs_verification
   │                  │
   │                  └── lease expired (worker crashed) — keyed on whether the
   │                      job has EVER sent, not on marker staleness: [K16]
   │                        request_sent_at IS NULL                  ─┐
   │                        AND attempts < 3   (never sent)           │
   └───────────────────────────────────────────────────────────────────┘
   │                        request_sent_at IS NULL
   │                        AND attempts >= 3 ───────────────> failed
   │                        request_sent_at IS NOT NULL ─────> needs_verification
   │
   │  needs_verification ──read-back finds a match ─────────> published (recovered)
   │                     ──read ok, no match,
   │                       verify_attempts < 4 ─────────────> stays (backoff §5.4)
   │                     ──read ok, no match,
   │                       verify_attempts >= 4 ────────────> unresolved  ⇒ HUMAN
   │                     ──read FAILED ─────────────────────> stays, then unresolved
   │
   │  unresolved ──app.resolve_job('published') ────────────> published
   └───────────── app.resolve_job('not_published') ─────────> pending  (or failed
                                                               if attempts >= 3)
                  app.resolve_job('indeterminate') ─────────> stays unresolved

pending and scheduled_at older than 45 min ─────────────────> skipped
```

**Three forbidden transitions**, all covered by **SEC-05**:

1. `claimed → pending` while the marker is current for this attempt. A crashed worker that had
   already issued the request must never be blindly requeued. `[F-06]`
2. **`needs_verification → pending` by any automatic path whatsoever.** Exhausting
   `verify_attempts` means we have *stopped looking*, not that the post is absent — a successful
   read that returns nothing is not proof of absence, because `[A]` Meta publishes no
   read-after-write consistency guarantee. The only automatic exit from `needs_verification` is a
   **match** (to `published`) or **exhaustion** (to `unresolved`). An earlier revision of this
   document permitted a "bounded requeue" after four clean reads; that silently broke R4 and has
   been removed.
3. `needs_verification → failed`. `failed` asserts the post was **not** created; we do not know
   that here. When the outcome is unknown, `unresolved` always wins over `failed`.

### 5.2.1 What each terminal state asserts

The distinction is the whole point of the machine, and the UI must reflect it.

| State | Assertion | May be auto-rescheduled? |
|---|---|---|
| `published` | The post exists on the Page and we hold its id | n/a |
| `failed` | **No request was ever issued.** `[K6]` Reachable only when `request_sent_at IS NULL` and the attempt cap was reached, or from a pre-flight refusal where nothing was sent. **No API error response ever yields `failed`**, because Meta documents error causes and recommended actions but never states that a response implies the absence of a side effect (`docs/API_INTEGRATIONS.md` §8) | Yes — safe |
| `skipped` | No request was issued and the slot's window passed | Yes — safe |
| `unresolved` | **We do not know.** A request may or may not have reached Facebook | **Never.** Human only |

### 5.2.2 How `attempts`, `verify_attempts`, `failed` and `unresolved` reconcile

- **`attempts`** counts publish *claims*, incremented by the claim in §5.3. Cap 3.
- A second attempt is reachable only two ways: the job **never sent** (`request_sent_at IS NULL`),
  or a human attestation of absence was **accepted after a confirmation read** (§5.2.3). `[K16]`
- **`attempts >= 3` ⇒ `failed`** applies *only* when `request_sent_at IS NULL`. `[K6]` It must
  never be applied to a job that has sent, nor to one in `needs_verification` or `unresolved` —
  such a job can only end `published` or `unresolved`.
- **Error 506 is evidence of prior success, not of rejection.** `[K2]` If a retried attempt
  receives 506, an identical post already exists, which may well be our own earlier attempt. It
  routes to `needs_verification` for read-back and id recovery — never to `failed`. See
  `docs/API_INTEGRATIONS.md` §6.
- **`verify_attempts`** counts read-back attempts, capped at 4 (§5.4). Exhaustion routes to
  `unresolved`, never to `pending` and never to `failed`.
- The two counters are independent: a job can hold `attempts = 1, verify_attempts = 4` and end in
  `unresolved` having been published exactly once, or not at all — which is precisely the case a
  human must settle.

### 5.2.3 Human resolution — `app.resolve_job()` `[R4]`

Owner-only (§6.1). The operator is shown the post body, the Page link, `request_sent_at`, and the
read-back history, and chooses one of exactly three outcomes.

| Outcome | Preconditions | Status | `fb_post_id` | Marker | Counters | Audit |
|---|---|---|---|---|---|---|
| **`published`** — operator confirms the post exists | `unresolved`; operator supplies the real `fb_post_id` from the Page | → `published`; `posts.status='published'`, `published_at` set | Set from operator input; must satisfy `unique (org_id, fb_post_id)` | **Unchanged** | `published` +1, idempotently | `job.resolved.published`, actor, supplied id |
| **`not_published`** — operator confirms absence | `unresolved`; `attestation_count = 0`; **and a fresh confirmation read that completed, had complete coverage, and found zero matches** `[K15]` | → `pending`, `attestation_count := 1`. **Never → `failed`**, because this job has sent and `failed` now asserts the opposite `[K6]`. If the read disagrees, see the guard below | Stays null | **Unchanged.** Never cleared; the next claim increments `attempts` | none | `job.resolved.not_published`, actor, prior `request_sent_at`, **and the confirmation read's result and covered window** `[K14]` |
| **`indeterminate`** — operator cannot tell | `unresolved` | **Stays `unresolved`**; `escalated_at` refreshed | Stays null | Unchanged | none | `job.resolved.deferred`, actor, optional note |

**Rules that hold across all three outcomes:**

- `request_sent_at` and `request_sent_attempt` are **never reset by any path**, human or automatic.
  Requeue works because `attempts` moves forward, not because history is erased. A specification
  that cleared the marker to permit a retry would destroy the only evidence of what happened.
- **The `not_published` guard `[K15]`.** The operator's word is never acted on alone. A fresh
  confirmation read runs at the moment of attestation, and its result decides:

  | Confirmation read result | Outcome |
  |---|---|
  | Exactly one match | **Attestation overridden** → `published`, real id recorded, operator shown the post they missed |
  | Complete coverage, no match, `attestation_count = 0` | Accepted → `pending`, `attestation_count := 1` |
  | Complete coverage, no match, `attestation_count = 1` | **Refused.** One attestation per job; only `published` or `indeterminate` remain |
  | More than one match | Refused → stays `unresolved` |
  | Read failed, or coverage incomplete | Refused → stays `unresolved`; retry later |

- **At most two requests per job** `[K13]`: the original, plus one after an accepted attestation.
  This is an **application-level limit, not a guarantee against duplicate publication** `[K22]` —
  `docs/SECURITY.md` R-A10 records why.
- **Accepted cost.** If the worker crashes after the second attempt's marker write but before
  sending, the job routes to `needs_verification` → `unresolved` with its attestation already
  spent, and is stranded for manual handling even though only one request was issued. We cannot
  prove the second send did not happen, so this is the correct direction of error.
- The attached `posts` row stays attached throughout. `unique (post_id)` on `publish_jobs` means a
  post in an unresolved job can never be picked up by another slot, so an unresolved job cannot
  become a duplicate by a side door.
- `resolve_job` is idempotent per outcome: resolving an already-`published` job with the same
  `fb_post_id` is a no-op, not an error.
- Every outcome writes exactly one audit row naming the human actor. An automatic transition never
  writes `job.resolved.*`.
- Resolving as `not_published` does **not** bypass the schedule window: if the slot's 45 minutes
  have passed, the requeued job becomes `skipped` on the next sweep rather than posting late.

### 5.3 The atomic claim

```sql
update publish_jobs set
  status      = 'claimed',
  attempts    = attempts + 1,
  claimed_at  = now(),
  lease_until = now() + interval '5 minutes',
  updated_at  = now()
where id = (
  select id from publish_jobs
   where status = 'pending'
     and scheduled_at <= now()
     and scheduled_at >  now() - interval '45 minutes'
   order by scheduled_at
   for update skip locked
   limit 1
)
returning *;
```

`for update skip locked` makes two concurrent runners safe without a distributed lock.

**The claim is two-phase.** After claiming and before the Graph API call, the worker commits a
marker in its own statement:

```sql
-- phase 2: committed BEFORE the fetch, never in the same transaction as it.
-- request_sent_at is WRITE-ONCE (coalesce keeps the FIRST send); the attempt
-- number is overwritten each time. See the column notes in §4. [K21]
update publish_jobs
   set request_sent_at      = coalesce(request_sent_at, now()),  -- write-once
       request_sent_attempt = attempts,
       updated_at           = now()
 where id = $1;
```

**If the marker write fails, do not send. `[K14]`** The specification previously fixed the
*ordering* but never said what to do when the marker write itself errors. Sending anyway would put
a request on the wire with no marker, making the job indistinguishable from never-sent and
therefore eligible for **automatic** requeue — the exact failure this design exists to prevent,
reachable through an unspecified error path.

| Marker write outcome | Action |
|---|---|
| Committed | Proceed with the request |
| Failed with a definite error | **Do not send.** Release or let the lease expire; the job is untouched and `request_sent_at` stays NULL, so the reclaim sweep correctly requeues it |
| **Ambiguous** (timeout — we do not know whether it committed) | **Do not send.** Let the lease expire and let the **database arbitrate**: if the marker is present the job goes to `needs_verification`; if absent, to `pending` |

`[A]` The ambiguous case over-reports uncertainty: a job that sent nothing can land in
`needs_verification` and ultimately need a human. That is the correct direction of error and an
accepted cost, not an oversight.

Without this marker, an expired lease is indistinguishable from "the request was sent and we
crashed waiting", and the only safe action would be to escalate every crash to a human. With it,
the reclaim sweep can separate the two cases:

```sql
-- reclaim sweep: expired leases only.
-- Keyed on whether the job has EVER sent a request. `request_sent_attempt` is
-- deliberately NOT consulted here: a marker that is stale for the current
-- attempt says nothing about earlier attempts. [K16]
update publish_jobs
   set status = case
         -- a request was issued at some point: the outcome is unknown
         when request_sent_at is not null then 'needs_verification'
         -- never sent, retries exhausted
         when attempts >= 3               then 'failed'
         -- never sent, retries remain: the only safe automatic requeue
         else                                  'pending'
       end,
       lease_until = null,
       updated_at  = now()
 where status = 'claimed'
   and lease_until < now();
```

**Why this is safe, stated as an invariant.** `attempts` rises only on a claim; a claim requires
`pending`; and `[F]` R4 forbids any automatic route from `needs_verification` to `pending`.
Therefore a job that has already sent can only return for another attempt through an **accepted
human attestation** (§5.2.3). The marker alone does not carry that weight — the combination of
marker, R4, and the attestation guard does. Two things break it, and both are now controlled:
transport-level HTTP retries (forbidden — `JOBS_AND_SCHEDULING.md` §6) and any future automatic
`needs_verification → pending` path (forbidden by R4).

`[A]` This assumes the marker write commits before the outbound request leaves the runtime. In an
Edge Function issuing a separate statement, that holds. It does **not** hold if the two are ever
wrapped in one transaction — a reviewer must check that explicitly, because the failure is silent
and the whole crash-classification guarantee rests on it.

### 5.4 Verification schedule

A job in `needs_verification` is re-checked on a backoff rather than once: roughly +1, +5, +15 and
+60 minutes (`verify_attempts` 1–4). Each attempt ends in one of three ways:

The window anchors at the job's **first** `request_sent_at − 120s`, not `claimed_at` `[K5]`, so a
post created on an earlier attempt is inside the window when a later attempt verifies.

| Read outcome | Effect |
|---|---|
| Exactly one match | → `published` (recovered), `fb_post_id` recorded |
| **More than one match** | → **`unresolved`** `[K11]` — any selection would be a guess |
| Read succeeded, **complete coverage**, no match, `verify_attempts < 4` | Stay in `needs_verification`, wait for the next step |
| Read succeeded, **complete coverage**, no match, `verify_attempts >= 4` | → **`unresolved`**, `escalated_at = now()` |
| **Coverage incomplete** (5-page cap exhausted, more pages exist, window not reached) | **Classified a read failure, never an absence** `[K9]`. Stay; alert |
| Read failed (token invalid, network, throttle 80001) | Stay, do not consume the cap; once the window closes → `unresolved` |

**There is no automatic path from `needs_verification` to `pending`.** Four clean reads that found
nothing mean only that we stopped looking. `[A]` Meta documents no read-after-write consistency
guarantee for `published_posts`, so "absent from four reads" is strong evidence but not proof, and
R4 does not permit acting on evidence that falls short of proof. Only a human can assert absence,
through `app.resolve_job('not_published')` in §5.2.3.

`[R9]` The verification job is an outbound caller and therefore checks `kill_switch` before every
read, exactly like the publish and generate jobs. See §5.5.

### 5.5 Kill switch versus pause — scope of each

R9 applies to every job that makes an outbound request, including verification. The two controls
differ deliberately:

| Control | Blocks | Rationale |
|---|---|---|
| `kill_switch` | **All** outbound calls: publish, generate, verify/read-back, token health checks | An emergency stop must mean "stop talking to Meta and the AI provider", with no exceptions to reason about under pressure |
| `paused` | Publish and generate only. **Verification continues** | Pausing is a routine operational action. If it also stopped verification, every pause would strand `needs_verification` jobs and manufacture `unresolved` work |

Consequence to accept, stated plainly: while `kill_switch` is on, jobs already in
`needs_verification` are not reconciled and will drift toward `unresolved` once their window
closes. That is the correct trade — an emergency stop that keeps calling the API is not a stop.

---

## 6. Row Level Security

```sql
-- Helper. SECURITY DEFINER with an empty search_path, so it cannot be hijacked
-- by a tenant-created function or table shadowing a name.
create schema if not exists app;

create or replace function app.is_member(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.memberships m
     where m.org_id = target
       and m.user_id = auth.uid()
  );
$$;

revoke all on function app.is_member(uuid) from public;
grant execute on function app.is_member(uuid) to authenticated;

-- Role check. `owner` and `member` are application roles stored in memberships,
-- not Postgres roles, so they cannot be expressed with GRANT. Every owner-only
-- action therefore goes through a policy or an RPC that calls this. [F-07]
create or replace function app.has_role(target uuid, needed member_role)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.memberships m
     where m.org_id = target
       and m.user_id = auth.uid()
       and (m.role = needed or m.role = 'owner')   -- owner implies member
  );
$$;
revoke all on function app.has_role(uuid, member_role) from public;
grant execute on function app.has_role(uuid, member_role) to authenticated;

-- Enable RLS everywhere. No table in `public` is exempt.
alter table profiles             enable row level security;
alter table orgs                 enable row level security;
alter table memberships          enable row level security;
alter table org_settings         enable row level security;
alter table provider_credentials enable row level security;
alter table social_accounts      enable row level security;
alter table brand_voices         enable row level security;
alter table topics               enable row level security;
alter table posts                enable row level security;
alter table schedule_slots       enable row level security;
alter table publish_jobs         enable row level security;
alter table usage_counters       enable row level security;
alter table audit_logs           enable row level security;

-- ── Table and column privileges ────────────────────────────────────────────────
-- RLS filters ROWS. It does not filter COLUMNS. A member with SELECT on
-- provider_credentials can therefore read `ciphertext`, `iv`, and `key_version`
-- for their own org, and with the default `for all` policy could also overwrite
-- them. Ciphertext is not plaintext, but exposing it leaks length metadata,
-- enables offline attack if the master key is ever disclosed, and lets a member
-- tamper with or swap a credential. Column privileges are the only mechanism
-- that closes this. [F-01]
--
-- Supabase grants broad default privileges to `anon` and `authenticated`, so the
-- migration must REVOKE first and then grant back exactly what is needed.

revoke all on all tables in schema public from anon, authenticated;

-- Credentials: readable metadata only. No write path for clients at all —
-- plaintext must never reach Postgres (R7), so encryption happens in an Edge
-- Function and the write is made with the service role.
grant select (id, org_id, provider, model, tier, masked_hint, status,
              last_validated_at, is_default, created_at)
  on provider_credentials to authenticated;

grant select (id, org_id, platform, external_id, display_name, granted_scopes,
              granted_tasks, status, token_checked_at, connected_by, created_at)
  on social_accounts to authenticated;

-- Content the user genuinely authors.
grant select, insert, update, delete on topics       to authenticated;
grant select, insert, update, delete on brand_voices to authenticated;

-- Posts: NO client insert and NO client update. [B-1]
-- An earlier revision granted `insert (org_id, topic_id, brand_voice_id, body)`
-- and `update (body)`, which could not work and was unsafe:
--   * six NOT NULL columns (the three counts, bangla_ratio, and both hashes)
--     were outside the grant, so every client insert would fail outright; and
--   * an accepted `update (body)` would leave content_hash and opening_hash
--     holding the OLD values, so posts_content_hash_key would stop matching
--     reality and duplicate prevention — a stated control — would silently fail.
-- Posts are therefore written only by trusted server-side code (§6.3), which is
-- the same rule already applied to credentials and Page tokens.
-- `delete` stays with the client so a draft can be discarded; it cannot
-- desynchronise a hash, and prevent_published_mutation blocks published rows.
grant select on posts to authenticated;
grant delete on posts to authenticated;

-- Emergency stop must be reachable by ANY member: the cost of a member pausing
-- the queue is far lower than the cost of being unable to stop it. [D]
-- Every other setting is owner-only and goes through app.update_org_settings().
grant select on org_settings to authenticated;
grant update (kill_switch, paused) on org_settings to authenticated;

grant select on orgs, memberships, profiles, schedule_slots,
                publish_jobs, usage_counters, audit_logs to authenticated;

-- Nothing is granted to `anon` on any table. Not one row, not one column.

-- ── Policies ───────────────────────────────────────────────────────────────────

-- Own profile, plus the names of people in orgs you share. Without the second
-- policy the UI cannot render "approved by …". [F-14]
create policy profiles_self on profiles for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_comember_read on profiles for select to authenticated
  using (exists (
    select 1 from memberships mine
      join memberships theirs on theirs.org_id = mine.org_id
     where mine.user_id = auth.uid() and theirs.user_id = profiles.id
  ));

-- Orgs you belong to.
create policy orgs_read on orgs for select to authenticated
  using (app.is_member(id));
create policy orgs_update on orgs for update to authenticated
  using (app.is_member(id)) with check (app.is_member(id));

create policy memberships_read on memberships for select to authenticated
  using (app.is_member(org_id));

-- The standard tenant pattern. Both `using` and `with check` are mandatory:
-- `using` controls which rows are visible, `with check` prevents writing a row
-- into another tenant. Omitting the latter is the classic multi-tenant hole.
-- `app.live(org_id)` = member of an org that has not been soft-deleted. A
-- soft-deleted org must stop being writable the moment deletion starts, or the
-- revoke-then-delete sequence in docs/SECURITY.md §10 can race with a user still
-- editing. [F-15]
create or replace function app.live(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.memberships m
      join public.orgs o on o.id = m.org_id
     where m.org_id = target
       and m.user_id = auth.uid()
       and o.deleted_at is null
  );
$$;
revoke all on function app.live(uuid) from public;
grant execute on function app.live(uuid) to authenticated;

-- Read for members; writes limited by the column grants above.
create policy org_settings_read on org_settings for select to authenticated
  using (app.is_member(org_id));
create policy org_settings_stop on org_settings for update to authenticated
  using (app.live(org_id)) with check (app.live(org_id));

create policy brand_voices_rw on brand_voices for all to authenticated
  using (app.live(org_id)) with check (app.live(org_id));
create policy topics_rw on topics for all to authenticated
  using (app.live(org_id)) with check (app.live(org_id));
-- Posts: read and discard only. The policy deliberately mirrors the grants in
-- §6 rather than saying `for all`, so that a reader of either one reaches the
-- same conclusion about what a client can do. Creation and body edits go
-- through §6.3. [B-1]
create policy posts_read on posts for select to authenticated
  using (app.is_member(org_id));
create policy posts_delete on posts for delete to authenticated
  using (app.live(org_id));

-- Owner-only surfaces: readable by members, mutable only through an RPC that
-- checks app.has_role(org_id, 'owner'). No write policy exists for clients.
create policy social_accounts_read on social_accounts for select to authenticated
  using (app.is_member(org_id));
create policy schedule_slots_read on schedule_slots for select to authenticated
  using (app.is_member(org_id));

-- Credentials: SELECT only, and only the columns granted above. There is no
-- INSERT/UPDATE/DELETE policy for clients, because there is no client write
-- path — see §6.1. [F-01]
create policy provider_credentials_read on provider_credentials for select to authenticated
  using (app.is_member(org_id));

create view provider_credentials_safe
with (security_invoker = true) as
  select id, org_id, provider, model, tier, masked_hint, status,
         last_validated_at, is_default, created_at
    from provider_credentials;
grant select on provider_credentials_safe to authenticated;
-- `security_invoker = true` makes the view run under the caller's RLS and column
-- privileges, not the view owner's, so the view cannot become a bypass of either.
-- With the column grants in §6 the view is a convenience rather than the control:
-- `select *` on the base table now fails with "permission denied for column
-- ciphertext", which is the desired outcome but an unhelpful client error, so the
-- UI queries this view instead.
-- [?] Confirm `security_invoker` is supported on the project's Postgres version
-- (PG 15+). On an older server, use a SECURITY DEFINER function instead of a
-- view, because a non-invoker view would run as its owner and silently bypass RLS.

-- Jobs and counters: read-only to users; only the job runtime writes them.
create policy publish_jobs_read on publish_jobs for select to authenticated
  using (app.is_member(org_id));
create policy usage_counters_read on usage_counters for select to authenticated
  using (app.is_member(org_id));

-- Audit log: readable by the org, never mutable by anyone.
-- RLS with no write policy blocks `authenticated`. It does NOT block the service
-- role, which has BYPASSRLS — so immutability must additionally be enforced with
-- table privileges, which the service role does not bypass. [F-11]
create policy audit_logs_read on audit_logs for select to authenticated
  using (org_id is not null and app.is_member(org_id));

-- `revoke update, delete` is NOT sufficient: TRUNCATE is a separate table
-- privilege that removes every row without a DELETE, and the identity sequence
-- can be rewound with setval to make id gaps meaningless. Revoke everything,
-- then grant back only the operations that are actually needed. A migration must
-- never contain `grant all` on this table. [F-11]
revoke all on audit_logs from anon, authenticated, service_role;
grant select on audit_logs to authenticated;   -- RLS still filters the rows
grant insert on audit_logs to service_role;
-- SELECT for the service role is DELIBERATE. [B-2]
-- The property this hardening protects is INTEGRITY, not confidentiality against
-- our own job runtime: the service role must not be able to rewrite or erase
-- history, and it still cannot. Without this grant the automated backup — which
-- exports each table via the service role (SECURITY.md §10) — would silently
-- omit the audit log, while the incident runbook simultaneously requires audit
-- rows to be preserved before any cleanup. A read-only disclosure to a role we
-- already trust to run the jobs is a far smaller risk than having no forensic
-- record in any backup. Audit rows are redacted before insert and hold no
-- secret material. Revisit at S4, when the log spans tenants and contains other
-- people's IP addresses.
grant select on audit_logs to service_role;
revoke all on sequence audit_logs_id_seq from anon, authenticated, service_role;
grant usage on sequence audit_logs_id_seq to service_role;  -- nextval only, not setval
```

**Who can still alter history, stated precisely.** The grants above leave `anon` with nothing,
`authenticated` with `select` only, and `service_role` with `insert` and `select` only — so none
of the three can `update`, `delete` or `TRUNCATE`, and none can rewind the sequence. (`TRUNCATE`
is the one the revision before last missed.) They do **not** stop:

- the **table owner** (`postgres` under Supabase migrations), who can `UPDATE`, `DELETE`,
  `TRUNCATE`, `DROP`, re-grant privileges, `ALTER TABLE … DISABLE ROW LEVEL SECURITY`, or
  `ALTER TABLE … OWNER TO`;
- any **superuser**, including `supabase_admin`;
- therefore **anyone holding the database password** or using the Supabase dashboard SQL editor —
  which includes the project owner;
- `[A]` Supabase personnel with infrastructure access, as for any managed database.

So `audit_logs` is append-only **against the application**, not against its administrator. That is
a meaningful control against a compromised Edge Function or a stolen service-role key, and no
control at all against a compromised owner account. Claiming otherwise would be false. The only
real fix is mirroring to an external append-only sink, which remains open as R-A7 /
`docs/SECURITY.md` §13.

### 6.1 Server-side write paths (RPCs)

Everything a client may not write directly is a `SECURITY DEFINER` function whose **first
statement** is an authorization check. These are specifications, not implementations.

**Every function must declare `security definer` and `set search_path = ''`**, or a caller can
shadow a referenced object and execute code as the function's owner.

#### Execution privileges — PostgreSQL's dangerous default `[F-17]`

PostgreSQL grants `EXECUTE` on a newly created function **to `PUBLIC`** automatically. A
`SECURITY DEFINER` function left at that default is callable by `anon` — an unauthenticated
visitor — and runs with the owner's privileges. Every function therefore needs an explicit revoke
before any grant, and the schema itself needs the same treatment:

```sql
revoke all on schema app from public, anon;
grant usage on schema app to authenticated, service_role;

-- pattern, applied to EVERY function in schema app, with no exceptions:
revoke execute on function app.<fn>(<args>) from public, anon;
grant  execute on function app.<fn>(<args>) to <authenticated | service_role>;
```

`revoke … from public` is required even when `anon` is also named: `anon` inherits the `PUBLIC`
grant, so revoking from `anon` alone leaves the hole open.

| Function | Authorization check inside | `EXECUTE` granted to | Atomic | Notes |
|---|---|---|---|---|
| `app.assert_owner(org_id)` | `app.has_role(org_id,'owner')`, raises otherwise | `authenticated` | n/a | Called **through a user-scoped client** so `auth.uid()` is populated. §6.2 |
| `app.create_org(name)` | caller is authenticated (`auth.uid()` not null) | `authenticated` | **yes** | Creates `orgs` + `org_settings` + `memberships(role='owner')` + default `brand_voices` + default `schedule_slots` + audit row in one transaction. Partial success leaves an org nobody can reach `[F-13]` |
| `app.update_org_settings(org_id, …)` | owner | `authenticated` | yes | Everything except `kill_switch` / `paused` |
| `app.set_schedule(org_id, times[])` | owner | `authenticated` | yes | Replaces slots; must not orphan pending jobs |
| `app.approve_post(post_id)` | member of the post's org | `authenticated` | yes | Sets `status='approved'`, `approved_by`, `approved_at` |
| `app.invite_member(org_id, email, role)` | owner | `authenticated` | yes | Needs an `invitations` table — still open, §10 |
| `app.change_role(org_id, user_id, role)` | owner **+ last-owner guard** | `authenticated` | yes | Must refuse if it would leave zero owners `[F-13]` |
| `app.remove_member(org_id, user_id)` | owner **+ last-owner guard** | `authenticated` | yes | Same guard |
| `app.resolve_job(job_id, outcome, fb_post_id, note)` | owner of the job's org | `authenticated` | yes | The three outcomes in §5.2.3. Writes exactly one audit row naming the actor |
| `app.finalize_publish(job_id, fb_post_id)` | **none** — relies entirely on the execute grant | **`service_role` only** | **yes** | Updates `publish_jobs` + `posts` + `usage_counters` in one transaction, **idempotent**: a second call with the same `fb_post_id` is a no-op, not a unique violation `[F-12]`. Must be unreachable by `authenticated`, or a client could forge a published state |
| `app.write_provider_credential(p_actor, p_org, p_provider, p_model, p_tier, p_ciphertext, p_iv, p_key_version, p_masked_hint)` | `p_actor` is an **owner** of `p_org`, re-checked **in the same transaction as the write** | **`service_role` only** | **yes** | §6.2 explains why `p_actor` is trustworthy here and nowhere else |
| `app.connect_social_account(p_actor, p_org, p_external_id, p_name, p_token_ciphertext, p_token_iv, p_key_version, p_scopes, p_tasks)` | same | **`service_role` only** | **yes** | Must reject unless `p_tasks` contains `CREATE_CONTENT` `[V]` |

### 6.2 How an Edge Function establishes "the caller is an owner" `[F-18]`

**The trap.** `app.has_role()` resolves the actor with `auth.uid()`, which reads the JWT claims of
the *current request*. An Edge Function that connects with the **service-role key** has no user
JWT in that context, so `auth.uid()` is **null** and `app.has_role()` returns false for everyone.
A previous revision of this document said credential writes happen "using the service role, after
it has itself checked `app.has_role(org_id,'owner')`" — which cannot work as written. Worse would
be to "fix" it by reading a user id from the request body, which would let any caller name
themselves an owner.

**The required sequence.** Five steps, in this order:

1. **Require the user's own token.** The client calls the function with
   `Authorization: Bearer <the end user's access token>`. A request without one is rejected.
2. **Verify it — do not decode it.** Build a *user-scoped* client (project URL + **anon** key +
   that `Authorization` header) and call `auth.getUser()`, which validates the signature and
   expiry against the auth service. A locally decoded JWT is attacker-controlled data; `[A]` if a
   local JWKS verification is used instead for latency, it must check signature, `exp`, `aud` and
   `iss`, and that is the only acceptable alternative.
3. **Reject any client-supplied identity.** If the request body contains `actor_id`, `user_id`,
   `sub`, or `org_role`, **fail the request** rather than ignoring the field. Failing closed makes
   a confused client visible instead of silently trusting the right value for the wrong reason.
4. **Check ownership as the user.** Call `app.assert_owner(org_id)` **through the user-scoped
   client**, so `auth.uid()` is populated by that request's verified JWT and the check happens in
   the database rather than in function logic.
5. **Then switch to the service role** for the privileged write, calling
   `app.write_provider_credential(p_actor => <the id returned by getUser()>, …)`.

**Why passing `p_actor` is safe here and only here.** The parameter is trusted for exactly two
reasons, both of which must remain true: `EXECUTE` on the function is granted to `service_role`
alone, so no client can call it; and the value originates from `auth.getUser()` inside the
function, never from the request body. If either property is ever relaxed, the function becomes an
impersonation primitive. That is why the function name carries `p_actor` explicitly rather than
hiding it — a reviewer should see the obligation.

**Concurrent membership revocation.** Steps 4 and 5 are separate round trips, so ownership could
be revoked in between. The window is closed by re-checking inside the write:

```sql
-- first statement of app.write_provider_credential, same transaction as the insert
if not exists (
  select 1 from public.memberships
   where org_id = p_org and user_id = p_actor and role = 'owner'
) then
  raise exception 'not an owner of %', p_org using errcode = '42501';
end if;
```

Because the check and the insert share one transaction, a revocation either commits before the
check (the write is refused) or after the write (the write stood, correctly, at the moment it was
authorized). There is no interleaving that authorizes a non-owner. `[A]` This assumes the default
`read committed` isolation, which is sufficient here because the check reads the same snapshot the
write uses; it would not be sufficient if the check and write were in different transactions.

**Token revocation is weaker than membership revocation.** `[A]` A Supabase access token stays
valid until it expires, so a signed-out user's token may still pass step 2 for the remainder of
its lifetime. Membership is therefore the authority, re-read on every privileged call, and token
lifetime is kept short. `[?]` Whether to additionally check a per-user `token_valid_after`
timestamp before S4 is unresolved.

**Notes.**
- The service role bypasses RLS by design; that is why it exists only in the Edge Function
  runtime (`CLAUDE.md` R5). It does **not** bypass table or column privileges, which is what makes
  the `audit_logs` revoke above meaningful.
- `orgs` has no `insert` policy for `authenticated`: creation goes through `app.create_org()`, so a
  user can never create an org they are not a member of.
- `app.is_member` and `app.has_role` are `SECURITY DEFINER`, which is also what prevents infinite
  RLS recursion: a policy on `memberships` that queried `memberships` through RLS would recurse.
  This is deliberate, not incidental.
- `[?]` Whether to expose `publish_jobs.last_error` to tenant users, or only a sanitised code,
  is unresolved. Default to the sanitised code.

### 6.3 Post write paths — trusted server-side code only `[B-1]`

Posts carry six `NOT NULL` derived columns, and two of them (`content_hash`, `opening_hash`) back
a security control: `posts_content_hash_key` is how duplicate publication of the same body is
prevented. A client that can write either the body or a hash independently can desynchronise them.
So `posts` follows the credential rule — **no client write path** — with a database backstop
underneath it.

**Three layers, each closing a different hole:**

1. **No grant.** `authenticated` holds `select` and `delete` on `posts` and nothing else (§6).
2. **Trusted writers.** Two Edge Functions create and amend posts, using the service role:
   - **`generate`** (already specified, `ARCHITECTURE.md` §3.1) creates posts from topics.
   - **`update-post-body`** handles a manual edit of a draft. It authorises the caller using the
     §6.2 sequence — reduced to **member**, not owner, since authoring is a member action per the
     role matrix — recomputes the three counts and `bangla_ratio` with `Intl.Segmenter`, writes
     `body` and the counts, and refuses the edit if the resulting body collides with an existing
     `content_hash` in the same org.
3. **Database backstop.** `posts_hash_guard` (§8) recomputes both hashes from `body` on every
   insert and update, so the two can never disagree regardless of which writer acted.

**Why these are Edge Functions and not Postgres RPCs.** §7 defines `grapheme_count` and
`word_count` through `Intl.Segmenter`, which exists in Deno and not in Postgres. A plain SQL
function cannot compute them, so the grapheme-aware work has to happen in a JavaScript runtime.
The hashes are byte-level and therefore *can* be computed in SQL, which is exactly why the
backstop is possible.

**Canonical hash definitions — the database's versions win.** Because the trigger overwrites both
hashes, its expressions are the definition, and the Edge Functions need not compute them at all:

```sql
-- normalised body: NFC, trimmed, internal whitespace runs collapsed to one space
content_hash := encode(digest(
  regexp_replace(btrim(normalize(new.body, NFC)), '\s+', ' ', 'g'), 'sha256'), 'hex');

-- first 8 whitespace-separated tokens of that same normalised text
opening_hash := encode(digest(
  (select string_agg(tok, ' ')
     from (select tok, row_number() over () rn
             from regexp_split_to_table(
                    regexp_replace(btrim(normalize(new.body, NFC)), '\s+', ' ', 'g'),
                    ' ') tok) t
    where rn <= 8), 'sha256'), 'hex');
```

`[D]` `opening_hash` is deliberately defined on **whitespace-separated tokens**, not on
`Intl.Segmenter` word segments as §7 defines `word_count`. The two definitions differ on purpose:
`word_count` needs linguistic accuracy for a user-facing number, whereas `opening_hash` needs only
to be deterministic and identical on every write path, which rules out a JS-only segmenter. Bangla
separates words with spaces, so the approximation is adequate for repetition detection. `[A]`
Verify the tokenisation behaves sensibly on Bangla conjuncts and mixed-script openings before
relying on the anti-repetition index.

`[A]` Dependencies to confirm at migration time: `normalize(text, NFC)` requires PostgreSQL 13+
(we already require 15+ for §4.1, so this is satisfied if that check passes) and `digest()`
requires the `pgcrypto` extension, already listed as an assumption in §1.

---

## 7. Text counting specification

Bangla breaks naive counting, so the schema stores three numbers and names which one is
authoritative.

| Column | Definition | Used for |
|---|---|---|
| `grapheme_count` | User-perceived characters via `Intl.Segmenter(locale, {granularity: 'grapheme'})`. A conjunct such as ক্ষ counts 1. A multi-code-point emoji counts 1. | **Authoritative.** All min/max validation and the UI counter |
| `codepoint_count` | `[...s].length` | Diagnostics, provider token estimation |
| `word_count` | `Intl.Segmenter(locale, {granularity: 'word'})`, counting word-like segments only | Optional word targets |

Normalisation applied **before** counting and hashing, in this order: NFC normalise → trim →
collapse runs of spaces/tabs to one space → collapse 3+ newlines to exactly two. Each newline
counts as 1 grapheme. Emoji count toward `grapheme_count` but are limited separately by
`brand_voices.emoji_pref`.

`bangla_ratio` = Bengali-block code points ÷ (Bengali-block + Latin-block code points), ignoring
whitespace, digits, punctuation, and emoji. Validated against
`bangla_ratio_target ± ratio_tolerance`.

`[A]` Facebook's maximum post length is often cited as 63,206 characters but was not verified for
this document; `max_graphemes` is bounded far below any plausible limit, so it does not matter
operationally. Do not hardcode the figure from memory.

---

## 8. Triggers to implement

| Trigger | On | Purpose |
|---|---|---|
| `touch_updated_at` | `publish_jobs`, `org_settings` | Maintain `updated_at` |
| `enforce_region_tier` | `provider_credentials` ins/upd | **Reject** when the org's `region = 'eu_uk'` and `tier = 'unpaid'`. `[V]` Required by Gemini's EEA clause |
| `enforce_region_change` | `orgs` update of `region` | **Reject** a change to `eu_uk` while any `unpaid` credential exists for that org, with an error telling the user to replace the credential first. Without this, the rule is enforced only at credential-write time and a region change silently leaves a non-compliant org. `[F-08]` |
| `assert_actor_is_member` | `posts.approved_by`, `provider_credentials.created_by`, `social_accounts.connected_by` | Assert the referenced actor is a member of the row's org. Cannot be a foreign key because `profiles` has no `org_id`. §4.1 |
| `audit_credential_change` | `provider_credentials`, `social_accounts` | Insert an `audit_logs` row on create/update/delete, with no secret material |
| `prevent_published_mutation` | `posts` upd/del | Block changes to a `posts` row in state `published` by any role except the service role |
| `posts_hash_guard` | `posts` **before** ins/upd | **Overwrite** `content_hash` and `opening_hash` from `body`, unconditionally, discarding whatever the writer supplied. This is the B-1 backstop: it makes duplicate prevention a structural property rather than something that holds only while every writer computes it correctly, and it therefore also protects against a service-role bug — which RLS and column grants by definition cannot. See §6.3 for the expressions |
| `guard_last_owner` | `memberships` upd/del | Reject any change leaving an org with zero `owner` members. Belt-and-braces alongside the RPC check. `[F-13]` |
| `request_sent_at_immutable` | `publish_jobs` before upd | **Reject any change to a non-NULL `request_sent_at`.** `[K21]` This makes `[F]` J4's "never reset" structural rather than dependent on every writer remembering `coalesce`. The read-back window anchors on this value (§5.4), so a single careless overwrite would silently exclude a post created on an earlier attempt |

`[A]` `enforce_region_tier`, `enforce_region_change`, and `assert_actor_is_member` all need
cross-table lookups, so they must be triggers rather than `check` constraints.

**Defence in depth for the EU/UK rule.** The database trigger is the backstop, not the only
control. The generation job must independently re-check region and tier before each provider call,
because a trigger cannot catch a credential that became non-compliant for a reason outside the
rows it watches — for example `[A]` a key the user downgraded from paid to unpaid on Google's side,
which we cannot detect at all. `tier` is a **user attestation**, not a verified fact. `[?]` Whether
a paid Gemini key can be distinguished from an unpaid one through any API response is unverified;
until it is, the product must record the attestation in `audit_logs` and say plainly in the UI that
the user is responsible for it. `[?]` Also unresolved: `org_region` is org-level, but Google's
clause concerns where *users* are. An org marked `global` with a member in the EEA is arguably
non-compliant. Out of scope for S2 (single owner, Bangladesh); must be resolved before EU/UK
onboarding.

---

## 9. Migration policy

1. Forward-only. Numbered files in `supabase/migrations/`. No file edited after merge.
2. Every migration is idempotent where cheap (`if not exists`) and reviewed for lock duration.
3. Enum values are added, never removed or renamed (`alter type … add value`).
4. A migration that adds a tenant table must, in the same commit: enable RLS, add at least one
   policy with `using` **and** `with check`, and add the table to the §11 matrix. CI fails
   otherwise.
5. No schema change is made in the Supabase dashboard. `[R10]`
6. Destructive changes ship in two steps (add + backfill, then drop in a later release).

---

## 10. Open questions

1. ~~`[?]` Confirm `pgcrypto`, `pg_cron`, and `pg_net` are all enabled on the free plan.~~
   **Resolved `[V] 2026-10-22`.** All three are available and installed on the free plan, on
   separate evidence. `pg_net` and `pg_cron`: the `net` and `cron` schemas exist on the hosted
   development project, owned by `supabase_admin`, and neither extension creates its schema unless
   installed. `pgcrypto`: migration `20261020230300_triggers.sql` calls `digest()` and applied
   successfully, which it could not have done otherwise. Note the consequence recorded in ADR-015 —
   `net`'s grants cannot be revoked from the `postgres` role.
2. `[?]` Confirm the server is **PostgreSQL 15 or later** — required by both `security_invoker`
   views and the `on delete set null (column)` clauses in §4.1. Fallbacks are documented for both.
3. `[?]` Expose `last_error` to users, or only a sanitised code?
4. `[?]` Should `audit_logs` be partitioned by month before S4? Depends on volume.
5. `[?]` Retention for `publish_jobs` rows — 1 year proposed, unconfirmed.
6. `[?]` Should a Page be connectable by more than one org? The current partial unique index
   forbids it. Two consequences to decide on: it blocks the agency use case, and the unique
   violation itself **tells org B that some other org has already connected that Page** — a small
   cross-tenant information leak. If the rule stays, the API must return a generic "this Page
   cannot be connected" message rather than surfacing the constraint. `[F-16]`
7. `[?]` No `invitations` table is specified yet, so `app.invite_member` has nowhere to write.
   Needed before S3 (multi-user), not before S2.
8. `[?]` Is a `profiles` row auto-created for every new `auth.users` row? Supabase's usual pattern
   is a trigger on `auth.users`. Without it, `orgs.created_by` and every actor reference fail on
   first use. `[F-13]`

---

## 11. Tenant isolation test matrix (SEC-01)

For every table below, authenticate as a user in org B and attempt each operation against a row
owned by org A. Expected result: **0 rows returned, or an error.** Any other result is a failing
build. A new tenant table without a row here fails CI.

| Table | select | insert (into A) | update | delete |
|---|---|---|---|---|
| `orgs` | ☐ | ☐ | ☐ | ☐ |
| `memberships` | ☐ | ☐ | ☐ | ☐ |
| `org_settings` | ☐ | ☐ | ☐ | ☐ |
| `provider_credentials` | ☐ | ☐ | ☐ | ☐ |
| `provider_credentials_safe` (view) | ☐ | n/a | n/a | n/a |
| `social_accounts` | ☐ | ☐ | ☐ | ☐ |
| `brand_voices` | ☐ | ☐ | ☐ | ☐ |
| `topics` | ☐ | ☐ | ☐ | ☐ |
| `posts` | ☐ | ☐ | ☐ | ☐ |
| `schedule_slots` | ☐ | ☐ | ☐ | ☐ |
| `publish_jobs` | ☐ | ☐ | ☐ | ☐ |
| `usage_counters` | ☐ | ☐ | ☐ | ☐ |
| `audit_logs` | ☐ | ☐ | ☐ | ☐ |

Additional required cases:

- ☐ `anon` (no JWT) gets 0 rows from every table above.
- ☐ A user with **no** membership gets 0 rows.
- ☐ A removed member loses access immediately after their `memberships` row is deleted.
- ☐ `insert` with a forged `org_id` in the payload is rejected by `with check`.
- ☐ Each policy is verified to **fail** the test when the policy is dropped (proving the test
  tests something).

### 11.1 Column-privilege tests (SEC-16) `[F-01]`

As an authenticated member of the row's **own** org:

- ☐ `select ciphertext from provider_credentials` → **permission denied**
- ☐ `select iv, key_version from provider_credentials` → **permission denied**
- ☐ `select token_ciphertext, token_iv from social_accounts` → **permission denied**
- ☐ `select *` on `provider_credentials` → **permission denied** (and the UI uses
  `provider_credentials_safe` instead)
- ☐ `select * from provider_credentials_safe` → succeeds, contains no ciphertext column
- ☐ `insert`/`update`/`delete` on `provider_credentials` → **denied** (no policy, no grant)
- ☐ `update social_accounts set status='active'` → **denied**
- ☐ `insert into posts (org_id, body) …` → **denied** (no insert grant at all) `[B-1]`
- ☐ `update posts set body = '…'` → **denied** (no update grant at all) `[B-1]`
- ☐ `update posts set status='published', fb_post_id='x'` → **denied**
- ☐ `delete from posts` on an own-org **draft** → **succeeds**; on a `published` row → **denied**
  by `prevent_published_mutation`
- ☐ `update org_settings set auto_publish=true` → **denied**
- ☐ `update org_settings set paused=true` → **succeeds** for any member (emergency stop)
- ☐ `update org_settings set target_buffer=50` → **denied**; succeeds only via
  `app.update_org_settings` as an `owner`

### 11.2 Cross-tenant reference tests (SEC-17) `[F-03]`

Using the **service role** (which bypasses RLS, so only the constraints are under test):

- ☐ `insert into posts (org_id, topic_id) values (B, <topic of A>)` → **foreign key violation**
- ☐ `insert into posts (org_id, brand_voice_id) values (B, <voice of A>)` → **violation**
- ☐ `insert into publish_jobs (org_id, slot_id) values (B, <slot of A>)` → **violation**
- ☐ `insert into publish_jobs (org_id, post_id) values (B, <post of A>)` → **violation**
- ☐ `update posts set org_id = B where org_id = A` → **violation** (the composite FK follows)
- ☐ Deleting a topic nulls only `posts.topic_id` and leaves `posts.org_id` intact
- ☐ A second `publish_jobs` row referencing an already-attached `post_id` → **unique violation**
  `[F-04]`
- ☐ `posts.approved_by` set to a user who is not a member of that org → **rejected by trigger**

### 11.3 Role authorization tests (SEC-22) `[F-07]`

For every row of the matrix in `docs/SECURITY.md` §7, assert both directions: an `owner` succeeds
and a `member` is refused. A test that only checks the owner path proves nothing.

- ☐ `member` cannot connect or disconnect a Page
- ☐ `member` cannot create, update, or delete a credential
- ☐ `member` cannot change the schedule
- ☐ `member` cannot invite, remove, or re-role a user
- ☐ `member` **can** set `paused` and `kill_switch`
- ☐ Removing or demoting the last `owner` is refused by both the RPC and the trigger

### 11.4 Audit-log privilege tests (SEC-19) `[F-11]`

Every operation, for **both** `authenticated` and `service_role`:

| Operation | `authenticated` | `service_role` |
|---|---|---|
| `select` | ☐ own org only | ☐ **allowed — assert this succeeds.** Deliberate per `[B-2]`; without it the automated backup omits the audit log. A test that expected a denial here would enshrine the bug |
| `insert` | ☐ **denied** | ☐ allowed |
| `update` | ☐ **denied** | ☐ **denied** |
| `delete` | ☐ **denied** | ☐ **denied** |
| `truncate audit_logs` | ☐ **denied** | ☐ **denied** |
| `select setval('audit_logs_id_seq', 1)` | ☐ **denied** | ☐ **denied** |
| `alter table audit_logs disable row level security` | ☐ **denied** | ☐ **denied** |

- ☐ A migration containing `grant all on audit_logs` fails review (CI grep).
- ☐ The documented limitation is asserted, not hidden: a test run **as the table owner** is
  expected to **succeed** at update and truncate, confirming that the control's boundary is where
  §6 says it is.

### 11.5 RPC execution-grant tests (SEC-23) `[F-17]`

For **every** function in schema `app`:

- ☐ As `anon`: `select app.<fn>(…)` → **permission denied** (proves the `PUBLIC` default was
  revoked, not merely overridden for `anon`)
- ☐ As `authenticated`, for `app.finalize_publish`, `app.write_provider_credential`, and
  `app.connect_social_account` → **permission denied**
- ☐ As `authenticated`, for each user-facing RPC → callable, but **refused** by its internal check
  when the caller lacks the role
- ☐ Every function in `app` declares `security definer` and `set search_path = ''` (CI check over
  the migration files, not a runtime test)
- ☐ `anon` has no `USAGE` on schema `app`
- ☐ A new function added without an explicit `revoke execute … from public` fails CI

### 11.6 Human-resolution tests (SEC-24) `[R4]`

- ☐ `resolve_job('published', id)` on an `unresolved` job → `published`, `fb_post_id` stored,
  `posts.status='published'`, `published` counter +1, one audit row naming the actor
- ☐ Calling it twice with the same id → no-op, no unique violation, **no second counter increment**
- ☐ `resolve_job('not_published')` with `attempts = 1` → `pending`; with `attempts = 3` → `failed`
- ☐ After `resolve_job('not_published')`, `request_sent_at` and `request_sent_attempt` are
  **unchanged** (the marker is never reset), and the prior `request_sent_at` appears in the audit row
- ☐ After the requeue, a fresh claim increments `attempts`, making `request_sent_attempt < attempts`
  so the next crash classifies as "not sent" — verifying the design works without a reset
- ☐ `resolve_job('indeterminate')` → stays `unresolved`, `escalated_at` refreshed, audit row written
- ☐ `resolve_job` by a `member` → refused
- ☐ `resolve_job` on a job in any state other than `unresolved` → refused
- ☐ A requeued job whose slot window has passed becomes `skipped`, not published late
- ☐ **No automatic path exists from `needs_verification` to `pending`**: run the verify job 10
  times against a mock returning clean empty reads and assert the job reaches `unresolved` and
  never `pending`

### 11.7 Kill-switch scope tests (SEC-09) `[R9]`

With `kill_switch = true`, using a mock that counts every outbound request:

- ☐ `generate` job → **zero** outbound calls
- ☐ `publish` job → **zero** outbound calls
- ☐ `verify` job → **zero** outbound calls (the case the original spec missed)
- ☐ token health check → **zero** outbound calls
- ☐ Each job logs that it aborted on the switch, so the stop is visible rather than silent

With `paused = true`: ☐ generate and publish make zero calls, ☐ `verify` **does** proceed (§5.5).

### 11.8 Post hash-integrity tests (SEC-26) `[B-1]`

The point of these is that the control must hold against a *trusted* writer, so they run **as the
service role**, bypassing RLS and column grants:

- ☐ Insert a post supplying a deliberately wrong `content_hash` → the stored value is the
  trigger's recomputation, not the supplied one
- ☐ Insert a post supplying a wrong `opening_hash` → likewise overwritten
- ☐ Update `body` without touching `content_hash` → the stored hash changes to match the new body
- ☐ Update `body` to a value whose normalised form equals an existing post in the same org →
  **unique violation** on `posts_content_hash_key` (this is the duplicate-prevention bypass that
  the old `grant update (body)` would have permitted silently)
- ☐ Two bodies differing only in leading/trailing whitespace, internal whitespace runs, or NFC
  normalisation → produce the **same** hash, so the second is refused
- ☐ Two bodies differing only after the eighth token → produce the **same** `opening_hash` and
  **different** `content_hash`; the insert succeeds and the repetition index still flags it
- ☐ **Drop `posts_hash_guard` and re-run:** the wrong-hash assertions must now **fail**, proving
  the trigger is what enforces this and not something incidental (`SECURITY.md` §1)

As an authenticated member (covered in §11.1): no insert or update on `posts` is possible at all,
so these paths are only reachable by trusted code.

### 11.9 Backup coverage check (part of SEC-13) `[B-2]`

The audit-log omission was not caused by the grant — it was caused by nothing ever noticing a
missing table. The check must therefore be generic rather than a hard-coded list:

- ☐ The export enumerates `information_schema.tables` for `table_schema = 'public'` and
  `table_type = 'BASE TABLE'`, and **fails** if any table is absent from its own output manifest
- ☐ Dropping `audit_logs` from the export makes the check **fail** (the regression that started
  this)
- ☐ Adding a new table in a migration without touching the export code makes the check **fail**,
  so a future table cannot be silently excluded
- ☐ The manifest records, per table, the row count exported and the public-key fingerprint used
- ☐ Views (`provider_credentials_safe`) are excluded by the `BASE TABLE` filter and that exclusion
  is asserted, not assumed
- ☐ An explicit, reviewed deny-list is the only way to omit a table, and the check names any entry
  on it in the manifest
