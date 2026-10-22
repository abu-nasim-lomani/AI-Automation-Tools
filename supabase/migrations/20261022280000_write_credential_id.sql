-- ============================================================================
-- 20261022280000_write_credential_id.sql
--
-- Corrects app.write_provider_credential to take the credential id as a
-- parameter. The envelope AAD binds the ciphertext to org : credential id :
-- key version (SECURITY.md §5), so the id must be known BEFORE the key is
-- sealed. The previous version let the database generate the id with a default,
-- which could never match the id the Edge Function sealed against — decryption
-- at generate time would then fail every time. The Edge Function now generates
-- the id, seals with it, and passes it here.
--
-- Forward-only: drop the id-less signature (nothing calls it yet — the Edge
-- Function does not exist) and create the id-taking one.
-- ============================================================================

drop function if exists app.write_provider_credential(
  uuid, uuid, provider_kind, text, credential_tier, bytea, bytea, int, text);

create or replace function app.write_provider_credential(
  p_id          uuid,
  p_actor       uuid,
  p_org         uuid,
  p_provider    provider_kind,
  p_model       text,
  p_tier        credential_tier,
  p_ciphertext  bytea,
  p_iv          bytea,
  p_key_version int,
  p_masked_hint text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid;
  v_first boolean;
begin
  if not exists (
    select 1 from public.memberships m
     where m.org_id = p_org and m.user_id = p_actor and m.role = 'owner'
  ) then
    raise exception 'write_provider_credential: actor is not an owner of the org'
      using errcode = '42501';
  end if;

  select not exists (select 1 from public.provider_credentials where org_id = p_org)
    into v_first;

  insert into public.provider_credentials
    (id, org_id, provider, model, tier, ciphertext, iv, key_version, masked_hint,
     status, is_default, created_by)
  values
    (p_id, p_org, p_provider, p_model, p_tier, p_ciphertext, p_iv, p_key_version, p_masked_hint,
     'unvalidated', v_first, p_actor)
  returning id into v_id;

  insert into public.audit_logs (org_id, actor, action, detail)
  values (p_org, p_actor, 'credential.written',
          jsonb_build_object('provider', p_provider, 'masked_hint', p_masked_hint));

  return v_id;
end;
$$;

revoke all on function app.write_provider_credential(
  uuid, uuid, uuid, provider_kind, text, credential_tier, bytea, bytea, int, text)
  from public, anon, authenticated;
grant execute on function app.write_provider_credential(
  uuid, uuid, uuid, provider_kind, text, credential_tier, bytea, bytea, int, text)
  to service_role;
