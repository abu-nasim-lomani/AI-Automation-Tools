-- ============================================================================
-- SEC-17 — cross-tenant foreign keys (docs/DATABASE.md §11.2, SECURITY.md T17)
--
-- Run AS THE SERVICE ROLE, which has BYPASSRLS. That is the whole point: RLS is
-- out of the picture, so only the composite foreign keys are under test. These
-- are the constraints that protect against a service-role bug — the class of
-- mistake RLS by definition cannot catch (ADR-012).
-- ============================================================================

set role service_role;

-- A post in org B may not reference org A's topic or brand voice
select t.expect_denied('SEC-17','posts: org B referencing org A topic',
  $$insert into posts (org_id, topic_id, body, grapheme_count, codepoint_count, word_count, bangla_ratio)
    values ('bb000000-0000-4000-8000-00000000000b','a2000000-0000-4000-8000-00000000000a',
            'x',1,1,1,0.5)$$);
select t.expect_denied('SEC-17','posts: org B referencing org A brand voice',
  $$insert into posts (org_id, brand_voice_id, body, grapheme_count, codepoint_count, word_count, bangla_ratio)
    values ('bb000000-0000-4000-8000-00000000000b','a1000000-0000-4000-8000-00000000000a',
            'x',1,1,1,0.5)$$);

-- A job in org B may not reference org A's slot or post
select t.expect_denied('SEC-17','publish_jobs: org B referencing org A slot',
  $$insert into publish_jobs (org_id, run_date, slot_id, scheduled_at)
    values ('bb000000-0000-4000-8000-00000000000b','2026-10-25',
            'a5000000-0000-4000-8000-00000000000a', now())$$);
select t.expect_denied('SEC-17','publish_jobs: org B referencing org A post',
  $$insert into publish_jobs (org_id, run_date, slot_id, scheduled_at, post_id)
    values ('bb000000-0000-4000-8000-00000000000b','2026-10-26',
            'b5000000-0000-4000-8000-00000000000b', now(),
            'a3000000-0000-4000-8000-00000000000a')$$);

-- Moving a row between tenants must fail: the composite key follows
select t.expect_denied('SEC-17','posts: update org_id A -> B',
  $$update posts set org_id = 'bb000000-0000-4000-8000-00000000000b'
     where id = 'a3000000-0000-4000-8000-00000000000a'$$);

-- A post may be attached to at most one job (F-04)
select t.expect_denied('SEC-17','publish_jobs: second job for an attached post',
  $$insert into publish_jobs (org_id, run_date, slot_id, scheduled_at, post_id)
    values ('aa000000-0000-4000-8000-00000000000a','2026-10-27',
            'a5000000-0000-4000-8000-00000000000a', now(),
            'a3000000-0000-4000-8000-00000000000a')$$);

-- An actor who is not a member of the row's org is rejected by trigger,
-- because profiles has no org_id and no foreign key can express this (§4.1)
select t.expect_denied('SEC-17','posts: approved_by a non-member',
  $$update posts set approved_by = 'b0000000-0000-4000-8000-000000000002'
     where id = 'a3000000-0000-4000-8000-00000000000a'$$);

-- Deleting a topic nulls only posts.topic_id and leaves org_id intact.
-- This is the PG 15 `on delete set null (column)` behaviour the schema relies on.
select t.expect_ok('SEC-17','topics: delete org B topic (cascade prep)',
  $$delete from topics where id = 'b2000000-0000-4000-8000-00000000000b'$$);
select t.expect('SEC-17','posts: topic_id nulled, org_id intact after topic delete',
  exists (select 1 from posts
            where id = 'b3000000-0000-4000-8000-00000000000b'
              and topic_id is null
              and org_id = 'bb000000-0000-4000-8000-00000000000b'),
  'on delete set null (topic_id) must not touch org_id');

-- CONTROL: a same-org reference still works, so the constraints are not simply
-- rejecting everything
select t.expect_ok('SEC-17','CONTROL: same-org post reference succeeds',
  $$insert into posts (org_id, topic_id, brand_voice_id, body,
                       grapheme_count, codepoint_count, word_count, bangla_ratio)
    values ('aa000000-0000-4000-8000-00000000000a','a2000000-0000-4000-8000-00000000000a',
            'a1000000-0000-4000-8000-00000000000a','control post সফল',16,16,3,0.75)$$);

reset role;
