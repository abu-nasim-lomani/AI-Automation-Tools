-- ============================================================================
-- SEC-01 — cross-tenant CRUD matrix (docs/DATABASE.md §11, SECURITY.md T1)
--
-- Authenticated as BOB (org B). Every assertion targets ORG A's rows.
-- Expected everywhere: 0 rows, or refusal. Anything else is a tenancy breach.
-- ============================================================================

set role authenticated;
set request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002"}';

-- ── SELECT: must see none of org A ──────────────────────────────────────────
select t.expect_count('SEC-01','orgs: select A',
  $$select 1 from orgs where id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','memberships: select A',
  $$select 1 from memberships where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','org_settings: select A',
  $$select 1 from org_settings where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','provider_credentials: select A',
  $$select 1 from provider_credentials where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','provider_credentials_safe: select A',
  $$select 1 from provider_credentials_safe where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','social_accounts: select A',
  $$select 1 from social_accounts where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','brand_voices: select A',
  $$select 1 from brand_voices where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','topics: select A',
  $$select 1 from topics where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','posts: select A',
  $$select 1 from posts where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','schedule_slots: select A',
  $$select 1 from schedule_slots where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','publish_jobs: select A',
  $$select 1 from publish_jobs where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','usage_counters: select A',
  $$select 1 from usage_counters where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','audit_logs: select A',
  $$select 1 from audit_logs where org_id = 'aa000000-0000-4000-8000-00000000000a'$$, 0);
select t.expect_count('SEC-01','profiles: cannot read a non-co-member',
  $$select 1 from profiles where id = 'a0000000-0000-4000-8000-000000000001'$$, 0);

-- ── INSERT into org A: must be refused (grant or with-check) ────────────────
select t.expect_denied('SEC-01','topics: insert into A',
  $$insert into topics (org_id, title) values ('aa000000-0000-4000-8000-00000000000a','smuggled')$$);
select t.expect_denied('SEC-01','brand_voices: insert into A',
  $$insert into brand_voices (org_id, name) values ('aa000000-0000-4000-8000-00000000000a','smuggled')$$);
select t.expect_denied('SEC-01','posts: insert into A',
  $$insert into posts (org_id, body, grapheme_count, codepoint_count, word_count, bangla_ratio)
    values ('aa000000-0000-4000-8000-00000000000a','x',1,1,1,0.5)$$);
select t.expect_denied('SEC-01','org_settings: insert for A',
  $$insert into org_settings (org_id) values ('aa000000-0000-4000-8000-00000000000a')$$);
select t.expect_denied('SEC-01','memberships: grant self into A',
  $$insert into memberships (org_id, user_id, role)
    values ('aa000000-0000-4000-8000-00000000000a','b0000000-0000-4000-8000-000000000002','owner')$$);
select t.expect_denied('SEC-01','provider_credentials: insert for A',
  $$insert into provider_credentials (org_id, provider, model, ciphertext, iv, masked_hint, created_by)
    values ('aa000000-0000-4000-8000-00000000000a','groq','m','\x00'::bytea,
            '\x000102030405060708090a0b'::bytea,'x','b0000000-0000-4000-8000-000000000002')$$);
select t.expect_denied('SEC-01','social_accounts: insert for A',
  $$insert into social_accounts (org_id, external_id, display_name, token_ciphertext, token_iv, connected_by)
    values ('aa000000-0000-4000-8000-00000000000a','1','p','\x00'::bytea,
            '\x000102030405060708090a0b'::bytea,'b0000000-0000-4000-8000-000000000002')$$);
select t.expect_denied('SEC-01','schedule_slots: insert for A',
  $$insert into schedule_slots (org_id, local_time) values ('aa000000-0000-4000-8000-00000000000a','09:00')$$);
select t.expect_denied('SEC-01','publish_jobs: insert for A',
  $$insert into publish_jobs (org_id, run_date, slot_id, scheduled_at)
    values ('aa000000-0000-4000-8000-00000000000a','2026-10-22',
            'a5000000-0000-4000-8000-00000000000a', now())$$);
select t.expect_denied('SEC-01','audit_logs: insert',
  $$insert into audit_logs (org_id, action) values ('aa000000-0000-4000-8000-00000000000a','forged')$$);

-- ── Forged org_id on an own-org insert must fail the with-check ─────────────
select t.expect_denied('SEC-01','topics: insert with forged org_id',
  $$insert into topics (org_id, title) values ('aa000000-0000-4000-8000-00000000000a','forged org')$$);

-- ── UPDATE / DELETE org A: must affect zero rows or be refused ──────────────
select t.expect_zero_affected('SEC-01','orgs: rename A',
  $$update orgs set name = 'hijacked' where id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_zero_affected('SEC-01','org_settings: pause A',
  $$update org_settings set paused = true where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_zero_affected('SEC-01','topics: rename A''s topic',
  $$update topics set title = 'hijacked' where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_zero_affected('SEC-01','brand_voices: rename A''s voice',
  $$update brand_voices set name = 'hijacked' where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_zero_affected('SEC-01','topics: delete A''s topic',
  $$delete from topics where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_zero_affected('SEC-01','posts: delete A''s post',
  $$delete from posts where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_zero_affected('SEC-01','memberships: delete A''s owner',
  $$delete from memberships where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('SEC-01','posts: update A''s body',
  $$update posts set body = 'hijacked' where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('SEC-01','provider_credentials: update A''s row',
  $$update provider_credentials set tier = 'paid' where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('SEC-01','audit_logs: update A''s rows',
  $$update audit_logs set action = 'rewritten' where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('SEC-01','audit_logs: delete A''s rows',
  $$delete from audit_logs where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('SEC-01','audit_logs: truncate',
  $$truncate audit_logs$$);

-- ── Own org still works, so the policies are not simply denying everything ──
select t.expect_count('SEC-01','CONTROL: bob sees his own org',
  $$select 1 from orgs where id = 'bb000000-0000-4000-8000-00000000000b'$$, 1);
select t.expect_ok('SEC-01','CONTROL: bob can create a topic in his own org',
  $$insert into topics (org_id, title) values ('bb000000-0000-4000-8000-00000000000b','bob own topic')$$);

reset role;
reset request.jwt.claims;

-- ── anon sees nothing, anywhere ─────────────────────────────────────────────
set role anon;
select t.expect_count('SEC-01','anon: orgs',   $$select 1 from orgs$$, 0);
select t.expect_count('SEC-01','anon: posts',  $$select 1 from posts$$, 0);
select t.expect_count('SEC-01','anon: topics', $$select 1 from topics$$, 0);
select t.expect_count('SEC-01','anon: provider_credentials', $$select 1 from provider_credentials$$, 0);
select t.expect_count('SEC-01','anon: audit_logs', $$select 1 from audit_logs$$, 0);
reset role;

-- ── A user with no membership at all sees nothing ───────────────────────────
set role authenticated;
set request.jwt.claims = '{"sub":"d0000000-0000-4000-8000-000000000009"}';
select t.expect_count('SEC-01','non-member: orgs',  $$select 1 from orgs$$, 0);
select t.expect_count('SEC-01','non-member: posts', $$select 1 from posts$$, 0);
reset role;
reset request.jwt.claims;
