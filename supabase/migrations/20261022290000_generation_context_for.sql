-- ============================================================================
-- 20261022290000_generation_context_for.sql — app.generation_context_for()
--
-- The on-demand twin of app.pick_generation_context: it returns the voice,
-- topic and credentials for ONE named org, with none of the buffer / cap /
-- paused eligibility gates, because a "generate a sample now" is a deliberate
-- owner action rather than the scheduled clock. It still reports kill_switch so
-- the caller can honour R9 (no outbound call while the emergency stop is on).
--
-- service_role only — the generate-now Edge Function verifies the caller's
-- membership first, then calls this as the service role. Ciphertext is base64;
-- no key leaves the database.
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

  select jsonb_agg(
           jsonb_build_object(
             'id', pc.id, 'provider', pc.provider, 'model', pc.model, 'tier', pc.tier,
             'key_version', pc.key_version,
             'ciphertext', encode(pc.ciphertext, 'base64'),
             'iv', encode(pc.iv, 'base64'))
           order by pc.is_default desc, pc.created_at asc)
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
