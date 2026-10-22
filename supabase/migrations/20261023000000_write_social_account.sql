-- ============================================================================
-- 20261023000000_write_social_account.sql — app.write_social_account()
--
-- Connects a Facebook Page: stores the Page access token, already encrypted by
-- the Edge Function (the envelope module, ADR-006 — no plaintext and no master
-- key ever reach the database). The twin of app.write_provider_credential for
-- the social_accounts table. docs/DATABASE.md §6, docs/SECURITY.md §5.
--
-- service_role only, for the same two reasons as write_provider_credential:
-- EXECUTE is granted to service_role alone, so no client can call it; and the
-- Edge Function derives p_actor from auth.getUser() on the caller's verified
-- token, never from the request body. Ownership (R11) is re-checked HERE, in
-- the same transaction as the write.
--
-- The envelope AAD binds the ciphertext to org : external_id : key version. The
-- Page id (external_id) is the credential id, not the row id, so a reconnect
-- (which updates the same row in place) re-seals against the SAME context and
-- the stored token stays decryptable. docs/SECURITY.md §5.
-- ============================================================================

create or replace function app.write_social_account(
  p_actor            uuid,
  p_org              uuid,
  p_external_id      text,
  p_display_name     text,
  p_token_ciphertext bytea,
  p_token_iv         bytea,
  p_key_version      int,
  p_granted_scopes   text[],
  p_granted_tasks    text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  -- Ownership (R11), re-checked in the same transaction as the write.
  if not exists (
    select 1 from public.memberships m
     where m.org_id = p_org and m.user_id = p_actor and m.role = 'owner'
  ) then
    raise exception 'write_social_account: actor is not an owner of the org'
      using errcode = '42501';
  end if;

  -- The schema's documented invariant: a connected Page must grant the task we
  -- publish with. Enforced here so no code path can store a token that cannot
  -- post. (Validation against Meta is a later token-health job, not this write.)
  if not ('CREATE_CONTENT' = any(coalesce(p_granted_tasks, '{}'))) then
    raise exception 'write_social_account: granted_tasks must contain CREATE_CONTENT'
      using errcode = '22023';
  end if;

  -- First connect inserts; a reconnect of the same Page updates that one row in
  -- place (the AAD is external_id, so the re-sealed token stays coherent). The
  -- unique (org_id, platform, external_id) is the conflict target; the partial
  -- unique on (platform, external_id) where status <> 'revoked' still forbids a
  -- DIFFERENT org from connecting a Page that is active elsewhere.
  insert into public.social_accounts
    (org_id, platform, external_id, display_name,
     token_ciphertext, token_iv, key_version,
     granted_scopes, granted_tasks, status, token_checked_at, connected_by)
  values
    (p_org, 'facebook_page', p_external_id, p_display_name,
     p_token_ciphertext, p_token_iv, p_key_version,
     coalesce(p_granted_scopes, '{}'), p_granted_tasks, 'active', null, p_actor)
  on conflict (org_id, platform, external_id) do update
    set display_name     = excluded.display_name,
        token_ciphertext = excluded.token_ciphertext,
        token_iv         = excluded.token_iv,
        key_version      = excluded.key_version,
        granted_scopes   = excluded.granted_scopes,
        granted_tasks    = excluded.granted_tasks,
        status           = 'active',
        token_checked_at = null,
        connected_by     = excluded.connected_by
  returning id into v_id;

  insert into public.audit_logs (org_id, actor, action, detail)
  values (p_org, p_actor, 'social_account.connected',
          jsonb_build_object('platform', 'facebook_page',
                             'external_id', p_external_id,
                             'display_name', p_display_name));

  return v_id;
end;
$$;

revoke all on function app.write_social_account(
  uuid, uuid, text, text, bytea, bytea, int, text[], text[])
  from public, anon, authenticated;
grant execute on function app.write_social_account(
  uuid, uuid, text, text, bytea, bytea, int, text[], text[])
  to service_role;
