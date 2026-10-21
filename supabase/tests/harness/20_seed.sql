-- ============================================================================
-- 20_seed.sql — two tenants, so every isolation assertion has something real
-- to cross. Runs as the migration owner. Local test use only.
--
--   org A  owned by alice   org B  owned by bob
--
-- No real credential values: the ciphertext columns get obviously fake bytes.
-- ============================================================================

-- ids chosen to be readable in failure output
-- alice a0.. / bob b0.. / org A aa.. / org B bb..
insert into auth.users (id, email) values
  ('a0000000-0000-4000-8000-000000000001', 'alice@example.test'),
  ('b0000000-0000-4000-8000-000000000002', 'bob@example.test');

insert into profiles (id, display_name) values
  ('a0000000-0000-4000-8000-000000000001', 'Alice'),
  ('b0000000-0000-4000-8000-000000000002', 'Bob');

insert into orgs (id, name, region, created_by) values
  ('aa000000-0000-4000-8000-00000000000a', 'Org A', 'bd',
   'a0000000-0000-4000-8000-000000000001'),
  ('bb000000-0000-4000-8000-00000000000b', 'Org B', 'bd',
   'b0000000-0000-4000-8000-000000000002');

insert into memberships (org_id, user_id, role) values
  ('aa000000-0000-4000-8000-00000000000a', 'a0000000-0000-4000-8000-000000000001', 'owner'),
  ('bb000000-0000-4000-8000-00000000000b', 'b0000000-0000-4000-8000-000000000002', 'owner');

-- A plain member of org A, to test the role matrix without owner powers.
insert into auth.users (id, email) values
  ('c0000000-0000-4000-8000-000000000003', 'carol@example.test');
insert into profiles (id, display_name) values
  ('c0000000-0000-4000-8000-000000000003', 'Carol');
insert into memberships (org_id, user_id, role) values
  ('aa000000-0000-4000-8000-00000000000a', 'c0000000-0000-4000-8000-000000000003', 'member');

insert into org_settings (org_id) values
  ('aa000000-0000-4000-8000-00000000000a'),
  ('bb000000-0000-4000-8000-00000000000b');

insert into brand_voices (id, org_id, name, is_default) values
  ('a1000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a', 'Voice A', true),
  ('b1000000-0000-4000-8000-00000000000b', 'bb000000-0000-4000-8000-00000000000b', 'Voice B', true);

insert into topics (id, org_id, title) values
  ('a2000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a', 'Topic A'),
  ('b2000000-0000-4000-8000-00000000000b', 'bb000000-0000-4000-8000-00000000000b', 'Topic B');

-- Bangla body, so the hash trigger is exercised on real mixed-script text.
-- content_hash and opening_hash are intentionally omitted: posts_hash_guard
-- derives them (docs/DATABASE.md §6.3).
insert into posts (id, org_id, topic_id, brand_voice_id, body,
                   grapheme_count, codepoint_count, word_count, bangla_ratio, status)
values
  ('a3000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a',
   'a2000000-0000-4000-8000-00000000000a', 'a1000000-0000-4000-8000-00000000000a',
   'আজকের post টি schedule করা হয়েছে', 31, 31, 6, 0.800, 'approved'),
  ('a4000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a',
   'a2000000-0000-4000-8000-00000000000a', 'a1000000-0000-4000-8000-00000000000a',
   'একটি published পোস্ট যা মুছে ফেলা যাবে না', 40, 40, 8, 0.850, 'published'),
  ('b3000000-0000-4000-8000-00000000000b', 'bb000000-0000-4000-8000-00000000000b',
   'b2000000-0000-4000-8000-00000000000b', 'b1000000-0000-4000-8000-00000000000b',
   'org B এর একটি draft', 19, 19, 4, 0.700, 'draft'),
  -- an org A draft, so the "a draft can be discarded" assertion deletes a row
  -- that actually exists rather than passing on a zero-row match
  ('a9000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a',
   'a2000000-0000-4000-8000-00000000000a', 'a1000000-0000-4000-8000-00000000000a',
   'org A এর একটি draft যা মুছে ফেলা যাবে', 37, 37, 7, 0.820, 'draft');

insert into schedule_slots (id, org_id, local_time) values
  ('a5000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a', '07:30'),
  ('b5000000-0000-4000-8000-00000000000b', 'bb000000-0000-4000-8000-00000000000b', '19:00');

insert into publish_jobs (id, org_id, run_date, slot_id, scheduled_at, post_id) values
  ('a6000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a',
   '2026-10-21', 'a5000000-0000-4000-8000-00000000000a',
   '2026-10-21 01:30:00+00', 'a3000000-0000-4000-8000-00000000000a');

-- Obviously fake credential material. iv must be exactly 12 bytes.
insert into provider_credentials
  (id, org_id, provider, model, tier, ciphertext, iv, masked_hint, created_by)
values
  ('a7000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a',
   'gemini', 'gemini-flash-latest', 'unpaid',
   '\xdeadbeefdeadbeef'::bytea, '\x000102030405060708090a0b'::bytea,
   'FAKE…0000', 'a0000000-0000-4000-8000-000000000001');

insert into social_accounts
  (id, org_id, external_id, display_name, token_ciphertext, token_iv,
   granted_tasks, connected_by)
values
  ('a8000000-0000-4000-8000-00000000000a', 'aa000000-0000-4000-8000-00000000000a',
   '000000000000000', 'You Know MD Abu Nasim',
   '\xcafebabecafebabe'::bytea, '\x0b0a09080706050403020100'::bytea,
   array['CREATE_CONTENT'], 'a0000000-0000-4000-8000-000000000001');

insert into usage_counters (org_id, day, generated) values
  ('aa000000-0000-4000-8000-00000000000a', '2026-10-21', 3);
