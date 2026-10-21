-- ============================================================================
-- 0001_schema.sql — enums, tables, constraints, indexes
-- Source of truth: docs/DATABASE.md §3, §4, §4.1 (frozen)
-- Forward-only. Never edited after merge (CLAUDE.md R10).
-- ============================================================================

-- ── Preflight: PostgreSQL 15+ is a hard requirement ─────────────────────────
-- §4.1 uses `on delete set null (column)`, added in PG 15 for foreign keys that
-- include a tenant id. §6 uses `security_invoker` views, also PG 15. Fail loudly
-- here rather than with a confusing syntax error 200 lines down.
do $$
begin
  if current_setting('server_version_num')::int < 150000 then
    raise exception
      'PostgreSQL 15+ required, found %. docs/DATABASE.md §4.1 documents the '
      'fallbacks (on delete restrict + soft-deleted topics) if this cannot be met.',
      current_setting('server_version');
  end if;
end $$;

create extension if not exists pgcrypto;  -- digest() for posts_hash_guard (§6.3)

create schema if not exists app;

-- ── Enum types (§3) ─────────────────────────────────────────────────────────
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

-- ── Identity and tenancy (§4) ───────────────────────────────────────────────
create table profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  locale       text not null default 'bn-BD',
  created_at   timestamptz not null default now()
);

create table orgs (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 120),
  region     org_region not null default 'bd',
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table memberships (
  org_id     uuid not null references orgs(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  role       member_role not null default 'member',
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);
create index memberships_user_idx on memberships (user_id);

create table org_settings (
  org_id        uuid primary key references orgs(id) on delete cascade,
  kill_switch   boolean not null default false,  -- checked first by every job (R9)
  paused        boolean not null default false,
  timezone      text not null default 'Asia/Dhaka',
  auto_publish  boolean not null default false,
  target_buffer int not null default 10 check (target_buffer between 1 and 60),
  daily_gen_cap int not null default 20 check (daily_gen_cap between 1 and 200),
  updated_at    timestamptz not null default now()
);

-- ── Credentials: ciphertext only (§4, SECURITY.md §5) ───────────────────────
create table provider_credentials (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references orgs(id) on delete cascade,
  provider          provider_kind not null,
  model             text not null,
  tier              credential_tier not null default 'unpaid',
  ciphertext        bytea not null,
  iv                bytea not null check (octet_length(iv) = 12),
  key_version       int not null default 1,
  masked_hint       text not null check (char_length(masked_hint) <= 16),
  status            cred_status not null default 'unvalidated',
  last_validated_at timestamptz,
  is_default        boolean not null default false,
  created_by        uuid not null references profiles(id),
  created_at        timestamptz not null default now()
);
create unique index provider_credentials_default_idx
  on provider_credentials (org_id) where is_default;
create index provider_credentials_org_idx on provider_credentials (org_id, provider);

create table social_accounts (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references orgs(id) on delete cascade,
  platform         text not null default 'facebook_page'
                     check (platform in ('facebook_page')),
  external_id      text not null,
  display_name     text not null,
  token_ciphertext bytea not null,
  token_iv         bytea not null check (octet_length(token_iv) = 12),
  key_version      int not null default 1,
  granted_scopes   text[] not null default '{}',
  granted_tasks    text[] not null default '{}',   -- must contain CREATE_CONTENT
  status           account_status not null default 'active',
  token_checked_at timestamptz,
  connected_by     uuid not null references profiles(id),
  created_at       timestamptz not null default now(),
  unique (org_id, platform, external_id)
);
-- One Page connected by one org at a time (§10 open question 6 keeps this rule).
create unique index social_accounts_external_unique
  on social_accounts (platform, external_id) where status <> 'revoked';

-- ── Content configuration ───────────────────────────────────────────────────
create table brand_voices (
  id                  uuid not null default gen_random_uuid(),
  org_id              uuid not null references orgs(id) on delete cascade,
  name                text not null,
  tone                tone_kind not null default 'conversational',
  language_primary    text not null default 'bn',
  bangla_ratio_target numeric(4,3) not null default 0.850
                        check (bangla_ratio_target between 0 and 1),
  ratio_tolerance     numeric(4,3) not null default 0.050
                        check (ratio_tolerance between 0 and 0.5),
  min_graphemes       int not null default 400 check (min_graphemes >= 1),
  max_graphemes       int not null default 1400,
  word_target_min     int,
  word_target_max     int,
  hashtag_max         int not null default 3 check (hashtag_max between 0 and 10),
  emoji_pref          emoji_policy not null default 'minimal',
  opening_style       text,
  closing_style       text,
  custom_instructions text,                         -- untrusted data (SEC-15)
  exclusions          text[] not null default '{}',
  is_default          boolean not null default false,
  created_at          timestamptz not null default now(),
  primary key (id),
  unique (org_id, id),                              -- composite-FK target §4.1
  check (max_graphemes > min_graphemes),
  check (word_target_max is null or word_target_min is null
         or word_target_max >= word_target_min)
);
create unique index brand_voices_default_idx on brand_voices (org_id) where is_default;

create table topics (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references orgs(id) on delete cascade,
  title        text not null check (char_length(title) between 1 and 200),
  instructions text check (char_length(instructions) <= 4000),
  weight       int not null default 1 check (weight between 0 and 10),
  enabled      boolean not null default true,
  last_used_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (org_id, title),
  unique (org_id, id)                               -- composite-FK target §4.1
);
create index topics_pick_idx on topics (org_id, enabled, last_used_at nulls first);

-- ── Content ─────────────────────────────────────────────────────────────────
create table posts (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  -- Single-column FKs are deliberately NOT used: they would allow a post in
  -- org B to reference a topic in org A. Composite FKs are declared below (§4.1).
  topic_id        uuid,
  brand_voice_id  uuid,
  body            text not null,
  grapheme_count  int not null check (grapheme_count > 0),
  codepoint_count int not null,
  word_count      int not null,
  bangla_ratio    numeric(4,3) not null check (bangla_ratio between 0 and 1),
  -- Both hashes are DERIVED by posts_hash_guard (0003). No writer can supply a
  -- value that disagrees with the body. Canonical definitions: §6.3.
  content_hash    text not null,
  opening_hash    text not null,
  status          post_status not null default 'draft',
  provider        provider_kind,
  model           text,
  prompt_version  text,
  critic_notes    jsonb,
  approved_by     uuid references profiles(id),
  approved_at     timestamptz,
  published_at    timestamptz,
  fb_post_id      text,
  created_at      timestamptz not null default now(),
  unique (org_id, id),                              -- composite-FK target §4.1
  constraint posts_topic_same_org foreign key (org_id, topic_id)
    references topics (org_id, id) on delete set null (topic_id),
  constraint posts_voice_same_org foreign key (org_id, brand_voice_id)
    references brand_voices (org_id, id) on delete set null (brand_voice_id)
);
create unique index posts_content_hash_key on posts (org_id, content_hash);
-- Scoped to the org: a GLOBAL unique index would let one tenant insert a guessed
-- fb_post_id and permanently block another tenant's finalize step (F-05).
create unique index posts_fb_post_id_key on posts (org_id, fb_post_id)
  where fb_post_id is not null;
create index posts_pick_idx    on posts (org_id, status, created_at);
create index posts_opening_idx on posts (org_id, opening_hash, created_at desc);

-- ── Scheduling and jobs ─────────────────────────────────────────────────────
create table schedule_slots (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references orgs(id) on delete cascade,
  local_time time not null,                 -- interpreted in org_settings.timezone
  enabled    boolean not null default true,
  created_at timestamptz not null default now(),
  unique (org_id, local_time),
  unique (org_id, id)                               -- composite-FK target §4.1
);

create table publish_jobs (
  id              uuid primary key default gen_random_uuid(),
  org_id          uuid not null references orgs(id) on delete cascade,
  run_date        date not null,            -- local date in the org's timezone
  slot_id         uuid not null,
  scheduled_at    timestamptz not null,     -- resolved UTC instant
  post_id         uuid,
  status          job_status not null default 'pending',
  attempts        int not null default 0 check (attempts >= 0 and attempts <= 10),
  verify_attempts int not null default 0 check (verify_attempts >= 0),
  lease_until     timestamptz,
  claimed_at      timestamptz,
  -- request_sent_at is WRITE-ONCE (first send); request_sent_attempt is
  -- overwritten each attempt and is NOT the basis of any requeue decision.
  -- `request_sent_at IS NULL` is the only evidence permitting an automatic
  -- requeue (§4 column notes, §5.3). Immutability enforced in 0003.
  request_sent_at      timestamptz,
  request_sent_attempt int,
  escalated_at    timestamptz,
  -- Accepted human attestations of absence, capped at 1 => at most two requests
  -- per job. An application-level limit, NOT a guarantee against duplicate
  -- publication (SECURITY.md R-A10).
  attestation_count int not null default 0
    check (attestation_count between 0 and 1),
  fb_post_id      text,
  last_error      text,                     -- code + safe message, never a body
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (org_id, run_date, slot_id),
  constraint request_marker_coherent check (
    (request_sent_at is null) = (request_sent_attempt is null)
  ),
  constraint publish_jobs_slot_same_org foreign key (org_id, slot_id)
    references schedule_slots (org_id, id) on delete cascade,
  constraint publish_jobs_post_same_org foreign key (org_id, post_id)
    references posts (org_id, id) on delete set null (post_id)
);
-- A post may be attached to at most one job: two slots can never publish the
-- same body (F-04).
create unique index publish_jobs_post_unique on publish_jobs (post_id)
  where post_id is not null;
create index jobs_due_idx   on publish_jobs (status, scheduled_at)
  where status in ('pending', 'needs_verification', 'unresolved');
create index jobs_stale_idx on publish_jobs (lease_until) where status = 'claimed';
create index jobs_org_idx   on publish_jobs (org_id, scheduled_at desc);

-- ── Observability ───────────────────────────────────────────────────────────
create table usage_counters (
  org_id         uuid not null references orgs(id) on delete cascade,
  day            date not null,
  generated      int not null default 0,
  published      int not null default 0,
  failed         int not null default 0,
  provider_calls int not null default 0,
  primary key (org_id, day)
);

create table audit_logs (
  id     bigserial primary key,
  at     timestamptz not null default now(),
  org_id uuid references orgs(id) on delete set null,
  actor  uuid references profiles(id) on delete set null,
  action text not null,
  target text,                              -- opaque id, never a secret
  ip     inet,
  detail jsonb not null default '{}'::jsonb -- redacted before insert (R3)
);
create index audit_logs_org_at_idx on audit_logs (org_id, at desc);
