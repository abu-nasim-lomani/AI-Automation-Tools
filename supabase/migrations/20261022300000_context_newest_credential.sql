-- ============================================================================
-- 20261022300000_context_newest_credential.sql
--
-- generation_context_for now orders credentials NEWEST first, so replacing a
-- key in the UI takes effect immediately. Previously it ordered by is_default,
-- and a second ("replacement") credential is not the default, so the original
-- key kept being used — which is why a replaced key appeared to do nothing.
-- Only the ORDER BY changes.
-- ============================================================================

create or replace function app.generation_context_for(p_org uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   record;
  v_voice jsonb;
  v_topic jsonb;
  v_creds jsonb;
begin
  select o.id as org_id, o.region, s.timezone, s.kill_switch
    into v_row
    from public.orgs o
    join public.org_settings s on s.org_id = o.id
   where o.id = p_org and o.deleted_at is null;
  if not found then return null; end if;

  select jsonb_build_object(
           'id', bv.id, 'tone', bv.tone, 'language_primary', bv.language_primary,
           'bangla_ratio_target', bv.bangla_ratio_target, 'ratio_tolerance', bv.ratio_tolerance,
           'min_graphemes', bv.min_graphemes, 'max_graphemes', bv.max_graphemes,
           'hashtag_max', bv.hashtag_max, 'emoji_pref', bv.emoji_pref,
           'opening_style', bv.opening_style, 'closing_style', bv.closing_style,
           'custom_instructions', bv.custom_instructions, 'exclusions', bv.exclusions)
    into v_voice
    from public.brand_voices bv
   where bv.org_id = p_org
   order by bv.is_default desc, bv.created_at asc
   limit 1;
  if v_voice is null then return null; end if;

  select jsonb_build_object('id', t.id, 'title', t.title, 'instructions', t.instructions)
    into v_topic
    from public.topics t
   where t.org_id = p_org and t.enabled = true
   order by t.last_used_at asc nulls first, t.weight desc, t.created_at asc
   limit 1;
  if v_topic is null then return null; end if;

  -- Newest credential first, so a replaced key is used right away.
  select jsonb_agg(
           jsonb_build_object(
             'id', pc.id, 'provider', pc.provider, 'model', pc.model, 'tier', pc.tier,
             'key_version', pc.key_version,
             'ciphertext', encode(pc.ciphertext, 'base64'),
             'iv', encode(pc.iv, 'base64'))
           order by pc.created_at desc)
    into v_creds
    from public.provider_credentials pc
   where pc.org_id = p_org and pc.status <> 'invalid';
  if v_creds is null then return null; end if;

  return jsonb_build_object(
    'org_id', v_row.org_id, 'region', v_row.region, 'timezone', v_row.timezone,
    'kill_switch', v_row.kill_switch,
    'voice', v_voice, 'topic', v_topic, 'credentials', v_creds);
end;
$$;

revoke all on function app.generation_context_for(uuid) from public, anon, authenticated;
grant execute on function app.generation_context_for(uuid) to service_role;
