-- ============================================================================
-- 0003_triggers.sql — structural controls
-- Source of truth: docs/DATABASE.md §8, §6.3 (frozen)
--
-- These exist because a control that survives a service-role bug is worth more
-- than one that assumes there will not be any (ADR-012, ADR-014).
-- ============================================================================

-- ── updated_at maintenance ──────────────────────────────────────────────────
create or replace function app.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger touch_updated_at before update on publish_jobs
  for each row execute function app.touch_updated_at();
create trigger touch_updated_at before update on org_settings
  for each row execute function app.touch_updated_at();

-- ── posts_hash_guard: the duplicate-prevention backstop (B-1, §6.3) ─────────
-- Recomputes BOTH hashes from `body` on every insert and update, discarding
-- whatever the writer supplied. Makes duplicate prevention structural rather
-- than dependent on every writer computing it correctly — including the service
-- role, which RLS and column grants cannot constrain.
--
-- opening_hash is defined on WHITESPACE-SEPARATED TOKENS, deliberately not on
-- Intl.Segmenter word segments as §7 defines word_count: the hash must be
-- computable in SQL and identical on every write path. §6.3 records why.
create or replace function app.posts_hash_guard()
returns trigger language plpgsql as $$
declare
  norm text;
begin
  norm := regexp_replace(btrim(normalize(new.body, NFC)), '\s+', ' ', 'g');
  new.content_hash := encode(digest(norm, 'sha256'), 'hex');
  new.opening_hash := encode(
    digest(
      coalesce((
        select string_agg(tok, ' ' order by ord)
          from unnest(string_to_array(norm, ' ')) with ordinality as t(tok, ord)
         where ord <= 8
      ), ''),
      'sha256'
    ), 'hex');
  return new;
end $$;

create trigger posts_hash_guard before insert or update of body on posts
  for each row execute function app.posts_hash_guard();

-- ── request_sent_at_immutable: makes J4's "never reset" structural (K21) ────
-- The read-back window anchors on this value (§5.4). A single careless
-- overwrite would silently exclude a post created on an earlier attempt, which
-- is the failure K5 exists to prevent.
create or replace function app.request_sent_at_immutable()
returns trigger language plpgsql as $$
begin
  if old.request_sent_at is not null
     and new.request_sent_at is distinct from old.request_sent_at then
    raise exception
      'request_sent_at is write-once (docs/DATABASE.md §4, J4): attempted to '
      'change % to % on job %', old.request_sent_at, new.request_sent_at, old.id
      using errcode = '23514';
  end if;
  return new;
end $$;

create trigger request_sent_at_immutable before update on publish_jobs
  for each row execute function app.request_sent_at_immutable();

-- ── prevent_published_mutation ──────────────────────────────────────────────
-- A published post is history. Blocked for client roles; the service role and
-- administrative roles are permitted, because finalize_publish must be able to
-- write the row that makes it published.
create or replace function app.prevent_published_mutation()
returns trigger language plpgsql as $$
begin
  if old.status = 'published' and current_user in ('authenticated', 'anon') then
    raise exception
      'post % is published and cannot be modified or deleted', old.id
      using errcode = '42501';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger prevent_published_mutation before update or delete on posts
  for each row execute function app.prevent_published_mutation();

-- ── EU/UK tier enforcement (§8, Gemini EEA clause) ──────────────────────────
-- Backstop only. The generation job must independently re-check region and tier
-- before each provider call: a trigger cannot catch a key the user downgraded
-- on Google's side, and `tier` is a user attestation rather than a verified fact
-- (SECURITY.md R-A8).
create or replace function app.enforce_region_tier()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.tier = 'unpaid'
     and (select o.region from public.orgs o where o.id = new.org_id) = 'eu_uk' then
    raise exception
      'an eu_uk organization may not hold an unpaid AI credential: Google''s '
      'Gemini terms permit only Paid Services when making API clients available '
      'to users in the EEA'
      using errcode = '23514';
  end if;
  return new;
end $$;

create trigger enforce_region_tier before insert or update on provider_credentials
  for each row execute function app.enforce_region_tier();

-- Without this, the rule is enforced only at credential-write time and a region
-- change silently leaves a non-compliant org (F-08).
create or replace function app.enforce_region_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.region = 'eu_uk' and old.region is distinct from 'eu_uk'
     and exists (select 1 from public.provider_credentials c
                  where c.org_id = new.id and c.tier = 'unpaid') then
    raise exception
      'cannot set region to eu_uk while unpaid AI credentials exist for org %: '
      'replace them with paid-tier credentials first', new.id
      using errcode = '23514';
  end if;
  return new;
end $$;

create trigger enforce_region_change before update of region on orgs
  for each row execute function app.enforce_region_change();

-- ── assert_actor_is_member (§4.1) ───────────────────────────────────────────
-- Cannot be a foreign key because `profiles` has no org_id. The referencing
-- column name is passed as a trigger argument.
create or replace function app.assert_actor_is_member()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  actor uuid;
  org   uuid;
begin
  actor := (to_jsonb(new) ->> tg_argv[0])::uuid;
  org   := (to_jsonb(new) ->> 'org_id')::uuid;
  if actor is not null and not exists (
    select 1 from public.memberships m
     where m.org_id = org and m.user_id = actor
  ) then
    raise exception
      '%.% references user %, who is not a member of org %',
      tg_table_name, tg_argv[0], actor, org
      using errcode = '42501';
  end if;
  return new;
end $$;

create trigger assert_approver_is_member before insert or update of approved_by on posts
  for each row execute function app.assert_actor_is_member('approved_by');
create trigger assert_creator_is_member before insert on provider_credentials
  for each row execute function app.assert_actor_is_member('created_by');
create trigger assert_connector_is_member before insert on social_accounts
  for each row execute function app.assert_actor_is_member('connected_by');

-- ── guard_last_owner (F-13) ─────────────────────────────────────────────────
-- Belt-and-braces alongside the RPC check, because the RPC is the thing most
-- likely to be bypassed by a future code path.
create or replace function app.guard_last_owner()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- Skip when the org itself is gone: an org delete cascades to memberships and
  -- must not be blocked by this guard.
  if not exists (select 1 from public.orgs o where o.id = old.org_id) then
    return null;
  end if;
  if not exists (
    select 1 from public.memberships m
     where m.org_id = old.org_id and m.role = 'owner'
  ) then
    raise exception
      'org % would be left with no owner', old.org_id using errcode = '23514';
  end if;
  return null;
end $$;

create trigger guard_last_owner after update or delete on memberships
  for each row execute function app.guard_last_owner();

-- ── audit_credential_change (§13) ───────────────────────────────────────────
-- No secret material: provider, tier and status only. Never ciphertext, never
-- iv, never a masked hint beyond what is already non-secret (R3).
create or replace function app.audit_credential_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  rec  jsonb;
  act  text;
begin
  rec := to_jsonb(coalesce(new, old));
  act := lower(tg_table_name) || '.' || lower(tg_op);
  insert into public.audit_logs (org_id, actor, action, target, detail)
  values (
    (rec ->> 'org_id')::uuid,
    null,
    act,
    rec ->> 'id',
    jsonb_strip_nulls(jsonb_build_object(
      'provider', rec ->> 'provider',
      'tier',     rec ->> 'tier',
      'status',   rec ->> 'status',
      'platform', rec ->> 'platform'
    ))
  );
  return null;
end $$;

create trigger audit_credential_change
  after insert or update or delete on provider_credentials
  for each row execute function app.audit_credential_change();
create trigger audit_social_account_change
  after insert or update or delete on social_accounts
  for each row execute function app.audit_credential_change();

-- Trigger functions in `app` must not be callable by clients.
revoke execute on all functions in schema app from public, anon;
