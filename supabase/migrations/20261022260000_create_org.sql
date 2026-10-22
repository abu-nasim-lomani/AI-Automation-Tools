-- ============================================================================
-- 20261022260000_create_org.sql — app.create_org()
--
-- The first thing a signed-in user does: make a workspace. orgs has no insert
-- policy for authenticated (DATABASE.md §6.1, §9), so creation MUST go through
-- this SECURITY DEFINER function, which also writes the memberships row in the
-- same transaction — a user can never create an org they are not a member of
-- (F-13). It builds the whole starter set so the workspace is usable at once:
-- org + settings + owner membership + a default voice + a default slot + audit.
--
-- Granted to authenticated and reached from the browser. For that the `app`
-- schema is added to the API's exposed schemas (config.toml locally; on the
-- hosted project, Settings → API → Exposed schemas must also include `app`).
-- Exposing `app` is safe: it has no tables, and its service-role-only functions
-- are not granted to authenticated, so they cannot be called from the client.
--
-- A freshly signed-up user has an auth.users row but NO profiles row (there is
-- no signup trigger), and orgs.created_by references profiles. So the function
-- ensures the profile first, upsert-style, which also covers a user who signed
-- in before this existed.
-- ============================================================================

create or replace function app.create_org(p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_org uuid;
begin
  if v_uid is null then
    raise exception 'create_org: not authenticated' using errcode = '42501';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'create_org: a workspace name is required' using errcode = '23514';
  end if;

  -- Ensure the caller has a profile (no signup trigger creates one).
  insert into public.profiles (id, display_name)
  values (v_uid, (select email from auth.users where id = v_uid))
  on conflict (id) do nothing;

  insert into public.orgs (name, created_by)
  values (btrim(p_name), v_uid)
  returning id into v_org;

  insert into public.memberships (org_id, user_id, role)
  values (v_org, v_uid, 'owner');

  insert into public.org_settings (org_id) values (v_org);

  insert into public.brand_voices (id, org_id, name, is_default)
  values (gen_random_uuid(), v_org, 'Default voice', true);

  -- One starter slot; the schedule editor changes it later.
  insert into public.schedule_slots (org_id, local_time, enabled)
  values (v_org, '19:00', true);

  insert into public.audit_logs (org_id, actor, action, detail)
  values (v_org, v_uid, 'org.created', jsonb_build_object('name', btrim(p_name)));

  return v_org;
end;
$$;

revoke all on function app.create_org(text) from public, anon;
grant execute on function app.create_org(text) to authenticated;
