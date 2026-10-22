-- ============================================================================
-- GEN-1 — app.pick_generation_context() and app.record_generation()
--
-- pick scans all orgs and returns one, so the suite first pauses every existing
-- org and builds its own eligible org G, making G the only candidate. Toggling
-- G's state then drives pick to null. The DB is rebuilt per run and this suite
-- runs last, so the mass pause is safe.
--
-- The happy-path results are captured into temp tables inside exception-guarded
-- blocks, so that if the function under test is removed (the mutation run), the
-- assertion reads a null/empty table and FAILS rather than erroring the whole
-- statement away.
-- ============================================================================

do $$
begin
  update public.org_settings set paused = true;   -- make every other org ineligible

  insert into orgs (id, name, region, created_by) values
    ('f9000000-0000-4000-8000-00000000000a', 'Gen Org', 'bd',
     'a0000000-0000-4000-8000-000000000001');
  -- The credential's created_by must be a member (assert_creator_is_member).
  insert into memberships (org_id, user_id, role) values
    ('f9000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'owner');
  insert into org_settings (org_id, target_buffer, daily_gen_cap) values
    ('f9000000-0000-4000-8000-00000000000a', 3, 5);
  insert into brand_voices (id, org_id, name, is_default, exclusions) values
    ('f9100000-0000-4000-8000-00000000000a', 'f9000000-0000-4000-8000-00000000000a',
     'Default', true, array['politics']);
  insert into topics (id, org_id, title, enabled, last_used_at) values
    ('f9200000-0000-4000-8000-00000000000a', 'f9000000-0000-4000-8000-00000000000a',
     'the value of patience', true, null);
  insert into provider_credentials
    (id, org_id, provider, model, tier, ciphertext, iv, masked_hint, created_by, is_default) values
    ('f9300000-0000-4000-8000-00000000000a', 'f9000000-0000-4000-8000-00000000000a',
     'gemini', 'gemini-flash-latest', 'unpaid',
     '\xdeadbeef'::bytea, '\x000102030405060708090a0b'::bytea, 'FAKE…0a',
     'a0000000-0000-4000-8000-000000000001', true);
end $$;

-- ── pick: the happy case, captured exception-safe ────────────────────────────
create temp table ctx(j jsonb);
do $$ begin
  insert into ctx select app.pick_generation_context();
exception when others then insert into ctx values (null);
end $$;

select t.expect('GEN-1','pick returns the eligible org',
  (select j->>'org_id' from ctx) = 'f9000000-0000-4000-8000-00000000000a',
  'eligible org not chosen');
select t.expect('GEN-1','pick includes the default voice with its id',
  (select j#>>'{voice,id}' from ctx) = 'f9100000-0000-4000-8000-00000000000a'
  and (select j#>>'{voice,tone}' from ctx) is not null,
  'voice missing or wrong');
select t.expect('GEN-1','pick includes the LRU topic',
  (select j#>>'{topic,id}' from ctx) = 'f9200000-0000-4000-8000-00000000000a',
  'topic missing or wrong');
select t.expect('GEN-1','pick returns credential ciphertext as base64, never raw',
  (select j#>>'{credentials,0,ciphertext}' from ctx) = encode('\xdeadbeef'::bytea,'base64')
  and (select j#>>'{credentials,0,provider}' from ctx) = 'gemini',
  'credential not encoded correctly');

-- ── pick: each disqualifier drives it to null ────────────────────────────────
do $$ begin
  insert into posts (id, org_id, body, grapheme_count, codepoint_count, word_count, bangla_ratio, status)
  values ('f9400000-0000-4000-8000-000000000001','f9000000-0000-4000-8000-00000000000a','approved এক',10,10,2,0.5,'approved'),
         ('f9400000-0000-4000-8000-000000000002','f9000000-0000-4000-8000-00000000000a','approved দুই',10,10,2,0.5,'approved'),
         ('f9400000-0000-4000-8000-000000000003','f9000000-0000-4000-8000-00000000000a','approved তিন',10,10,2,0.5,'approved');
end $$;
select t.expect('GEN-1','a full approved buffer removes the org',
  (select app.pick_generation_context()) is null, 'full buffer still picked');

do $$ begin delete from posts where org_id='f9000000-0000-4000-8000-00000000000a' and status='approved'; end $$;
do $$ begin update org_settings set paused=true where org_id='f9000000-0000-4000-8000-00000000000a'; end $$;
select t.expect('GEN-1','a paused org is not picked',
  (select app.pick_generation_context()) is null, 'paused org picked');
do $$ begin update org_settings set paused=false, kill_switch=true where org_id='f9000000-0000-4000-8000-00000000000a'; end $$;
select t.expect('GEN-1','a kill-switched org is not picked',
  (select app.pick_generation_context()) is null, 'killed org picked');
do $$ begin update org_settings set kill_switch=false where org_id='f9000000-0000-4000-8000-00000000000a'; end $$;

do $$
declare v_day date;
begin
  select (now() at time zone timezone)::date into v_day from org_settings
   where org_id='f9000000-0000-4000-8000-00000000000a';
  insert into usage_counters (org_id, day, generated)
  values ('f9000000-0000-4000-8000-00000000000a', v_day, 5);  -- cap is 5
end $$;
select t.expect('GEN-1','an org at its daily cap is not picked',
  (select app.pick_generation_context()) is null, 'capped org picked');
do $$ begin delete from usage_counters where org_id='f9000000-0000-4000-8000-00000000000a'; end $$;

do $$ begin update topics set enabled=false where org_id='f9000000-0000-4000-8000-00000000000a'; end $$;
select t.expect('GEN-1','an org with no enabled topic is not picked',
  (select app.pick_generation_context()) is null, 'topicless org picked');
do $$ begin update topics set enabled=true where org_id='f9000000-0000-4000-8000-00000000000a'; end $$;

do $$ begin update provider_credentials set status='invalid' where org_id='f9000000-0000-4000-8000-00000000000a'; end $$;
select t.expect('GEN-1','an org with no usable credential is not picked',
  (select app.pick_generation_context()) is null, 'credential-less org picked');
do $$ begin update provider_credentials set status='valid' where org_id='f9000000-0000-4000-8000-00000000000a'; end $$;

-- ── record_generation, captured exception-safe ──────────────────────────────
create temp table gen_post(id uuid);
do $$
declare v uuid;
begin
  v := app.record_generation(
    'f9000000-0000-4000-8000-00000000000a',
    'f9200000-0000-4000-8000-00000000000a',
    'f9100000-0000-4000-8000-00000000000a',
    'ধৈর্য একটি নীরব শক্তি, প্রতিদিন চর্চার যোগ্য।',
    40, 44, 7, 0.900, 'gemini', 'gemini-flash-latest', 'gen-v1',
    '{"accepted":true,"layer":"ok"}'::jsonb);
  insert into gen_post values (v);
exception when others then null;
end $$;

select t.expect('GEN-1','record_generation writes a draft post',
  (select count(*) from gen_post g join posts p on p.id=g.id
     where p.status='draft' and p.provider='gemini' and p.grapheme_count=40) = 1,
  'post not written as a draft');
select t.expect('GEN-1','record_generation hashes are filled by the trigger',
  (select count(*) from gen_post g join posts p on p.id=g.id
     where length(p.content_hash)=64) = 1,
  'content_hash not derived');
select t.expect('GEN-1','record_generation bumps the topic last_used_at',
  (select last_used_at is not null from topics where id='f9200000-0000-4000-8000-00000000000a'),
  'topic not bumped');
select t.expect('GEN-1','record_generation raises the generated counter to 1',
  (select generated from usage_counters
     where org_id='f9000000-0000-4000-8000-00000000000a'
       and day=(now() at time zone 'Asia/Dhaka')::date) = 1,
  'generated counter not 1');

do $$ begin perform app.record_generation(
  'f9000000-0000-4000-8000-00000000000a','f9200000-0000-4000-8000-00000000000a',
  'f9100000-0000-4000-8000-00000000000a','আরেকটি খসড়া পোস্ট এখানে।',
  25,25,4,0.95,'gemini','gemini-flash-latest','gen-v1','{"accepted":false}'::jsonb);
exception when others then null; end $$;
select t.expect('GEN-1','a second generation accumulates the counter to 2',
  (select generated from usage_counters
     where org_id='f9000000-0000-4000-8000-00000000000a'
       and day=(now() at time zone 'Asia/Dhaka')::date) = 2,
  'counter did not reach 2');

-- ── authorization ────────────────────────────────────────────────────────────
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_denied('GEN-1','authenticated cannot pick',
  $$select app.pick_generation_context()$$);
select t.expect_denied('GEN-1','authenticated cannot record a generation',
  $$select app.record_generation('f9000000-0000-4000-8000-00000000000a',
     'f9200000-0000-4000-8000-00000000000a','f9100000-0000-4000-8000-00000000000a',
     'forged', 5,5,1,0.5,'gemini','m','v','{}'::jsonb)$$);
reset request.jwt.claims;
reset role;
