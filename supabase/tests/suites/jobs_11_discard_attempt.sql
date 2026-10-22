-- ============================================================================
-- JOBS-11 — app.discard_failed_attempt() (migration 20261023030000)
--
-- The owner's guarded resolution of a stuck publish: a needs_verification job is
-- detached (post_id null) and marked skipped, freeing the post to be published
-- again. A published or missing attempt is refused, and only an owner may do it.
-- Client-callable: authorises on auth.uid().
-- ============================================================================

do $$
begin
  insert into orgs (id, name, region, created_by) values
    ('fe000000-0000-4000-8000-00000000000a','Discard','bd','a0000000-0000-4000-8000-000000000001');
  insert into memberships (org_id, user_id, role) values
    ('fe000000-0000-4000-8000-00000000000a','a0000000-0000-4000-8000-000000000001','owner');
  insert into org_settings (org_id) values ('fe000000-0000-4000-8000-00000000000a');
  insert into schedule_slots (id, org_id, local_time) values
    ('fea00000-0000-4000-8000-000000000001','fe000000-0000-4000-8000-00000000000a','09:00'),
    ('fea00000-0000-4000-8000-000000000002','fe000000-0000-4000-8000-00000000000a','10:00');
  insert into posts (id, org_id, body, grapheme_count, codepoint_count,
                     word_count, bangla_ratio, status) values
    ('feb00000-0000-4000-8000-000000000001','fe000000-0000-4000-8000-00000000000a','stuck এক',8,8,2,0.5,'approved'),
    ('feb00000-0000-4000-8000-000000000002','fe000000-0000-4000-8000-00000000000a','done দুই',8,8,2,0.5,'published'),
    ('feb00000-0000-4000-8000-000000000003','fe000000-0000-4000-8000-00000000000a','free তিন',8,8,2,0.5,'approved');
  insert into publish_jobs
    (id, org_id, run_date, slot_id, scheduled_at, status, attempts,
     request_sent_at, request_sent_attempt, post_id) values
    ('fec00000-0000-4000-8000-000000000001','fe000000-0000-4000-8000-00000000000a',
     '2026-04-01','fea00000-0000-4000-8000-000000000001', now()-interval '2 min',
     'needs_verification',1, now()-interval '1 min',1,'feb00000-0000-4000-8000-000000000001'),
    ('fec00000-0000-4000-8000-000000000002','fe000000-0000-4000-8000-00000000000a',
     '2026-04-02','fea00000-0000-4000-8000-000000000002', now()-interval '2 min',
     'published',1, now()-interval '1 min',1,'feb00000-0000-4000-8000-000000000002');
end $$;

-- ── Owner discards the stuck attempt ─────────────────────────────────────────
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select app.discard_failed_attempt('fe000000-0000-4000-8000-00000000000a','feb00000-0000-4000-8000-000000000001');
reset request.jwt.claims;
reset role;

select t.expect('JOBS-11','the discarded job is skipped and detached',
  (select status from publish_jobs where id='fec00000-0000-4000-8000-000000000001')='skipped'
  and (select post_id from publish_jobs where id='fec00000-0000-4000-8000-000000000001') is null,
  'job not detached/skipped');

select t.expect('JOBS-11','the post has no attached job and can be published again',
  (select count(*) from publish_jobs where post_id='feb00000-0000-4000-8000-000000000001')=0,
  'post still has a job attached');

select t.expect('JOBS-11','the discard is audited',
  exists(select 1 from audit_logs
          where org_id='fe000000-0000-4000-8000-00000000000a'
            and action='publish.attempt_discarded'),
  'discard not audited');

-- ── Refusals ─────────────────────────────────────────────────────────────────
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_denied('JOBS-11','a published attempt cannot be discarded',
  $$select app.discard_failed_attempt('fe000000-0000-4000-8000-00000000000a','feb00000-0000-4000-8000-000000000002')$$);
select t.expect_denied('JOBS-11','a post with no attempt cannot be discarded',
  $$select app.discard_failed_attempt('fe000000-0000-4000-8000-00000000000a','feb00000-0000-4000-8000-000000000003')$$);
reset request.jwt.claims;
reset role;

-- A non-member cannot discard.
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000009"}';
select t.expect_denied('JOBS-11','a non-owner cannot discard an attempt',
  $$select app.discard_failed_attempt('fe000000-0000-4000-8000-00000000000a','feb00000-0000-4000-8000-000000000001')$$);
reset request.jwt.claims;
reset role;
