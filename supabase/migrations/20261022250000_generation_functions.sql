-- ============================================================================
-- 20261022250000_generation_functions.sql
--
-- The two SQL sides of the generate Edge Function (docs/CONTENT_ENGINE.md §1,
-- §7, §8). The handler is thin glue between them: it decrypts the provider
-- keys (outside the database, ADR-006) and runs the orchestrator; the database
-- chooses the target and records the result.
--
--   app.pick_generation_context()  — choose one org that needs a post, and
--                                    return its voice, topic and credential
--                                    ciphertext as JSON. No key leaves here;
--                                    the ciphertext is base64 for the handler
--                                    to decrypt.
--   app.record_generation(...)     — write the draft, bump the topic, and
--                                    raise the daily generated counter, in one
--                                    transaction. Counts come from the handler
--                                    (Intl.Segmenter, Deno); hashes are left to
--                                    the posts_hash_guard trigger.
--
-- Both security definer, empty search_path, service_role only — the handler
-- runs as service_role (R5).
-- ============================================================================

create or replace function app.pick_generation_context()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org   record;
  v_voice jsonb;
  v_topic jsonb;
  v_creds jsonb;
begin
  -- One live org that is below its approved buffer and under today's cap, not
  -- stopped. for update skip locked keeps two concurrent runs off one org.
  select o.id as org_id, o.region, s.timezone
    into v_org
    from public.orgs o
    join public.org_settings s on s.org_id = o.id
   where o.deleted_at is null
     and s.kill_switch = false
     and s.paused = false
     and (select count(*) from public.posts p
           where p.org_id = o.id and p.status = 'approved') < s.target_buffer
     and (select coalesce(max(uc.generated), 0) from public.usage_counters uc
           where uc.org_id = o.id
             and uc.day = (now() at time zone s.timezone)::date) < s.daily_gen_cap
   order by o.created_at
   for update of s skip locked
   limit 1;
  if not found then return null; end if;

  -- Default voice, falling back to any. No voice ⇒ cannot generate.
  select jsonb_build_object(
           'id', bv.id,
           'tone', bv.tone,
           'language_primary', bv.language_primary,
           'bangla_ratio_target', bv.bangla_ratio_target,
           'ratio_tolerance', bv.ratio_tolerance,
           'min_graphemes', bv.min_graphemes,
           'max_graphemes', bv.max_graphemes,
           'hashtag_max', bv.hashtag_max,
           'emoji_pref', bv.emoji_pref,
           'opening_style', bv.opening_style,
           'closing_style', bv.closing_style,
           'custom_instructions', bv.custom_instructions,
           'exclusions', bv.exclusions)
    into v_voice
    from public.brand_voices bv
   where bv.org_id = v_org.org_id
   order by bv.is_default desc, bv.created_at asc
   limit 1;
  if v_voice is null then return null; end if;

  -- Least-recently-used enabled topic (CONTENT_ENGINE §9 proposal). No topic ⇒
  -- nothing to write about.
  select jsonb_build_object('id', t.id, 'title', t.title, 'instructions', t.instructions)
    into v_topic
    from public.topics t
   where t.org_id = v_org.org_id and t.enabled = true
   order by t.last_used_at asc nulls first, t.weight desc, t.created_at asc
   limit 1;
  if v_topic is null then return null; end if;

  -- Usable credentials, default-first, ciphertext base64-encoded for the
  -- handler. An invalid credential is skipped. None ⇒ cannot generate.
  select jsonb_agg(
           jsonb_build_object(
             'id', pc.id,
             'provider', pc.provider,
             'model', pc.model,
             'tier', pc.tier,
             'key_version', pc.key_version,
             'ciphertext', encode(pc.ciphertext, 'base64'),
             'iv', encode(pc.iv, 'base64'))
           order by pc.is_default desc, pc.created_at asc)
    into v_creds
    from public.provider_credentials pc
   where pc.org_id = v_org.org_id and pc.status <> 'invalid';
  if v_creds is null then return null; end if;

  return jsonb_build_object(
    'org_id', v_org.org_id,
    'region', v_org.region,
    'timezone', v_org.timezone,
    'voice', v_voice,
    'topic', v_topic,
    'credentials', v_creds);
end;
$$;

create or replace function app.record_generation(
  p_org            uuid,
  p_topic          uuid,
  p_voice          uuid,
  p_body           text,
  p_grapheme       int,
  p_codepoint      int,
  p_word           int,
  p_ratio          numeric,
  p_provider       provider_kind,
  p_model          text,
  p_prompt_version text,
  p_notes          jsonb
)
returns uuid
language plpgsql
security definer
-- NOT the empty search_path the other app functions use. Inserting a post fires
-- posts_hash_guard (0003), whose body is frozen and calls `digest()` UNQUALIFIED
-- — it resolves only when the extension's schema is on the path (public here,
-- `extensions` on Supabase). Under an empty path the trigger errors, so this is
-- a FIXED, non-caller-controlled path that covers both. It is safe for the same
-- reason '' is: the caller cannot change it. Recorded as an amendment candidate
-- against the trigger, which should pin its own search_path and qualify digest.
set search_path = pg_catalog, public, extensions
as $$
declare
  v_post uuid;
  v_tz   text;
  v_day  date;
begin
  -- status is always 'draft' (CONTENT_ENGINE §8); approval is a separate human
  -- step. The hashes are filled by posts_hash_guard, not here. Own references
  -- stay schema-qualified regardless of the path above.
  insert into public.posts
    (org_id, topic_id, brand_voice_id, body,
     grapheme_count, codepoint_count, word_count, bangla_ratio,
     status, provider, model, prompt_version, critic_notes)
  values
    (p_org, p_topic, p_voice, p_body,
     p_grapheme, p_codepoint, p_word, p_ratio,
     'draft', p_provider, p_model, p_prompt_version, p_notes)
  returning id into v_post;

  update public.topics set last_used_at = now()
   where id = p_topic and org_id = p_org;

  select timezone into v_tz from public.org_settings where org_id = p_org;
  v_day := (now() at time zone coalesce(v_tz, 'Asia/Dhaka'))::date;
  insert into public.usage_counters (org_id, day, generated)
  values (p_org, v_day, 1)
  on conflict (org_id, day) do update set generated = usage_counters.generated + 1;

  return v_post;
end;
$$;

revoke all on function app.pick_generation_context() from public, anon, authenticated;
revoke all on function app.record_generation(
  uuid, uuid, uuid, text, int, int, int, numeric, provider_kind, text, text, jsonb)
  from public, anon, authenticated;
grant execute on function app.pick_generation_context() to service_role;
grant execute on function app.record_generation(
  uuid, uuid, uuid, text, int, int, int, numeric, provider_kind, text, text, jsonb)
  to service_role;
