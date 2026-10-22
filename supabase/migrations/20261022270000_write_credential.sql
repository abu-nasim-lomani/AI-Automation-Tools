-- ============================================================================
-- 20261022270000_write_credential.sql — app.write_provider_credential()
--
-- Stores an AI provider key, already encrypted by the Edge Function (the
-- envelope module, ADR-006 — no plaintext and no master key ever reach the
-- database). docs/DATABASE.md §6.1, §6.2.
--
-- service_role only. The p_actor argument is trusted for exactly two reasons,
-- both of which must hold: EXECUTE is granted to service_role alone, so no
-- client can call it; and the Edge Function derives p_actor from auth.getUser()
-- on the caller's verified token, never from the request body (§6.2). Ownership
-- is re-checked HERE, in the same transaction as the write, so the check and
-- the insert cannot drift apart.
-- ============================================================================

create or replace function app.write_provider_credential(
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
  -- Ownership, re-checked in the same transaction as the write (§6.2).
  if not exists (
    select 1 from public.memberships m
     where m.org_id = p_org and m.user_id = p_actor and m.role = 'owner'
  ) then
    raise exception 'write_provider_credential: actor is not an owner of the org'
      using errcode = '42501';
  end if;

  -- The first credential for an org becomes its default.
  select not exists (select 1 from public.provider_credentials where org_id = p_org)
    into v_first;

  insert into public.provider_credentials
    (org_id, provider, model, tier, ciphertext, iv, key_version, masked_hint,
     status, is_default, created_by)
  values
    (p_org, p_provider, p_model, p_tier, p_ciphertext, p_iv, p_key_version, p_masked_hint,
     'unvalidated', v_first, p_actor)
  returning id into v_id;

  insert into public.audit_logs (org_id, actor, action, detail)
  values (p_org, p_actor, 'credential.written',
          jsonb_build_object('provider', p_provider, 'masked_hint', p_masked_hint));

  return v_id;
end;
$$;

revoke all on function app.write_provider_credential(
  uuid, uuid, provider_kind, text, credential_tier, bytea, bytea, int, text)
  from public, anon, authenticated;
grant execute on function app.write_provider_credential(
  uuid, uuid, provider_kind, text, credential_tier, bytea, bytea, int, text)
  to service_role;
