-- ============================================================================
-- 0002_privileges_and_rls.sql — helper functions, column privileges, RLS
-- Source of truth: docs/DATABASE.md §6, §6.1 (frozen)
--
-- The ordering in this file is deliberate and load-bearing:
--   1. helper functions   (policies reference them)
--   2. REVOKE             (Supabase grants broad defaults; strip them first)
--   3. column GRANTs      (grant back only what is needed)
--   4. enable RLS         (deny-by-default before any policy exists)
--   5. policies
-- ============================================================================

-- ── 1. Helper functions (§6) ────────────────────────────────────────────────
-- SECURITY DEFINER with an empty search_path: a caller must not be able to
-- shadow a referenced object and have it run as the function owner. The DEFINER
-- property is also what prevents infinite RLS recursion — a policy on
-- memberships that queried memberships through RLS would recurse.

create or replace function app.is_member(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
     where m.org_id = target and m.user_id = auth.uid()
  );
$$;

-- `owner` implies `member`.
create or replace function app.has_role(target uuid, needed member_role)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
     where m.org_id = target
       and m.user_id = auth.uid()
       and (m.role = needed or m.role = 'owner')
  );
$$;

-- Member of an org that has not been soft-deleted. A soft-deleted org must stop
-- being writable the moment deletion starts (F-15).
create or replace function app.live(target uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.memberships m
      join public.orgs o on o.id = m.org_id
     where m.org_id = target and m.user_id = auth.uid()
       and o.deleted_at is null
  );
$$;

-- PostgreSQL grants EXECUTE on new functions to PUBLIC. `anon` inherits that,
-- so revoking from `anon` alone leaves the hole open (F-17).
revoke all on schema app from public, anon;
grant usage on schema app to authenticated, service_role;

revoke execute on function app.is_member(uuid) from public, anon;
revoke execute on function app.has_role(uuid, member_role) from public, anon;
revoke execute on function app.live(uuid) from public, anon;
grant execute on function app.is_member(uuid) to authenticated;
grant execute on function app.has_role(uuid, member_role) to authenticated;
grant execute on function app.live(uuid) to authenticated;

-- ── 2. Strip the broad defaults ─────────────────────────────────────────────
-- RLS filters ROWS, never COLUMNS. Without this revoke, a member could read
-- provider_credentials.ciphertext for their own org (F-01, T16).
revoke all on all tables in schema public from anon, authenticated;

-- ── 3. Grant back exactly what is needed ────────────────────────────────────

-- Credentials: readable metadata only. There is NO client write path at all;
-- plaintext must never reach Postgres (R7), so encryption happens in an Edge
-- Function which writes with the service role.
grant select (id, org_id, provider, model, tier, masked_hint, status,
              last_validated_at, is_default, created_at)
  on provider_credentials to authenticated;

grant select (id, org_id, platform, external_id, display_name, granted_scopes,
              granted_tasks, status, token_checked_at, connected_by, created_at)
  on social_accounts to authenticated;

-- Content the user genuinely authors.
grant select, insert, update, delete on topics       to authenticated;
grant select, insert, update, delete on brand_voices to authenticated;

-- Posts: NO client insert and NO client update (B-1). Six NOT NULL derived
-- columns cannot be satisfied by a client, and an accepted `update (body)` would
-- leave content_hash describing the previous text, silently breaking duplicate
-- prevention. Writes go through trusted server-side code (§6.3).
-- `delete` stays: discarding a draft cannot desynchronise a hash, and
-- prevent_published_mutation blocks published rows.
grant select on posts to authenticated;
grant delete on posts to authenticated;

-- Emergency stop must be reachable by ANY member: the cost of a member pausing
-- the queue is far lower than being unable to stop it. Every other setting is
-- owner-only via app.update_org_settings().
grant select on org_settings to authenticated;
grant update (kill_switch, paused) on org_settings to authenticated;

grant select on orgs, memberships, profiles, schedule_slots,
                publish_jobs, usage_counters to authenticated;

-- Nothing is granted to `anon` on any table. Not one row, not one column.

-- ── 4. Enable RLS on every table in public. No exemptions (R1) ──────────────
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

-- ── 5. Policies ─────────────────────────────────────────────────────────────
-- Every tenant write policy declares `using` AND `with check`: omitting the
-- latter permits writing a row into another tenant.

create policy profiles_self on profiles for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
-- Co-members' display names, so the UI can render "approved by …" (F-14).
create policy profiles_comember_read on profiles for select to authenticated
  using (exists (
    select 1 from memberships mine
      join memberships theirs on theirs.org_id = mine.org_id
     where mine.user_id = auth.uid() and theirs.user_id = profiles.id
  ));

-- `orgs` has no INSERT policy for authenticated: creation goes through
-- app.create_org(), which also writes the memberships row, so a user can never
-- create an org they are not a member of.
create policy orgs_read on orgs for select to authenticated
  using (app.is_member(id));
create policy orgs_update on orgs for update to authenticated
  using (app.is_member(id)) with check (app.is_member(id));

create policy memberships_read on memberships for select to authenticated
  using (app.is_member(org_id));

create policy org_settings_read on org_settings for select to authenticated
  using (app.is_member(org_id));
create policy org_settings_stop on org_settings for update to authenticated
  using (app.live(org_id)) with check (app.live(org_id));

create policy brand_voices_rw on brand_voices for all to authenticated
  using (app.live(org_id)) with check (app.live(org_id));
create policy topics_rw on topics for all to authenticated
  using (app.live(org_id)) with check (app.live(org_id));

-- Posts: read and discard only. The policies mirror the grants above rather
-- than saying `for all`, so a reader of either reaches the same conclusion.
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
create policy provider_credentials_read on provider_credentials for select to authenticated
  using (app.is_member(org_id));

create policy publish_jobs_read on publish_jobs for select to authenticated
  using (app.is_member(org_id));
create policy usage_counters_read on usage_counters for select to authenticated
  using (app.is_member(org_id));

create policy audit_logs_read on audit_logs for select to authenticated
  using (org_id is not null and app.is_member(org_id));

-- ── Safe projection over credentials ────────────────────────────────────────
-- security_invoker makes the view run under the CALLER's RLS and column
-- privileges, so it cannot become a bypass of either. With the column grants
-- above, `select *` on the base table fails with "permission denied for column
-- ciphertext" — the desired outcome, but an unhelpful client error, so the UI
-- queries this view instead.
create view provider_credentials_safe
with (security_invoker = true) as
  select id, org_id, provider, model, tier, masked_hint, status,
         last_validated_at, is_default, created_at
    from provider_credentials;
grant select on provider_credentials_safe to authenticated;

-- ── Audit log: append-only against the application ──────────────────────────
-- `revoke update, delete` alone is NOT sufficient: TRUNCATE is a separate
-- privilege that empties the table without a DELETE, and the identity sequence
-- can be rewound with setval. Revoke everything, then grant back only what is
-- needed. A migration must never contain `grant all` on this table (F-11).
revoke all on audit_logs from anon, authenticated, service_role;
grant select on audit_logs to authenticated;    -- RLS still filters the rows
grant insert on audit_logs to service_role;
-- SELECT for the service role is DELIBERATE (B-2): the protected property is
-- INTEGRITY, not confidentiality against our own job runtime. Without it the
-- automated backup would silently omit the audit log while the incident runbook
-- requires audit rows preserved before any cleanup.
grant select on audit_logs to service_role;
revoke all on sequence audit_logs_id_seq from anon, authenticated, service_role;
grant usage on sequence audit_logs_id_seq to service_role;  -- nextval, not setval

-- Note recorded in docs/DATABASE.md §6: these grants stop anon, authenticated
-- and service_role. They do NOT stop the table owner or a superuser, i.e.
-- anyone holding the database password. The log is append-only against the
-- application, not against its administrator (SECURITY.md R-A7).
