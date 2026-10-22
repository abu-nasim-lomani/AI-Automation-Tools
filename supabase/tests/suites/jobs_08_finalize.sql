-- ============================================================================
-- JOBS-8 — app.finalize_publish() (docs/DATABASE.md §6.1, J8)
--
-- The publish success path and its idempotency: a second finalize with the
-- same id must not increment the counter a second time.
-- ============================================================================

do $$
begin
  insert into orgs (id, name, region, created_by) values
    ('f8000000-0000-4000-8000-00000000000a', 'Finalize', 'bd',
     'a0000000-0000-4000-8000-000000000001');
  insert into org_settings (org_id) values ('f8000000-0000-4000-8000-00000000000a');
  insert into schedule_slots (id, org_id, local_time) values
    ('f8a00000-0000-4000-8000-00000000000a', 'f8000000-0000-4000-8000-00000000000a', '12:00');

  -- Four approved posts, distinct bodies (content_hash is unique per org).
  insert into posts (id, org_id, body, grapheme_count, codepoint_count,
                     word_count, bangla_ratio, status) values
    ('f8b00000-0000-4000-8000-000000000001','f8000000-0000-4000-8000-00000000000a',
     'post এক', 7,7,2,0.5,'approved'),
    ('f8b00000-0000-4000-8000-000000000002','f8000000-0000-4000-8000-00000000000a',
     'post দুই',7,7,2,0.5,'approved'),
    ('f8b00000-0000-4000-8000-000000000004','f8000000-0000-4000-8000-00000000000a',
     'post চার',7,7,2,0.5,'approved');

  -- Jobs: a sent claimed job, a needs_verification (recovery) job, a no-post
  -- job, and a pending job (wrong state).
  insert into publish_jobs
    (id, org_id, run_date, slot_id, scheduled_at, status, attempts,
     request_sent_at, request_sent_attempt, post_id) values
    ('f8c00000-0000-4000-8000-000000000001','f8000000-0000-4000-8000-00000000000a',
     '2026-02-01','f8a00000-0000-4000-8000-00000000000a', now()-interval '2 min',
     'claimed',1, now()-interval '1 min',1,'f8b00000-0000-4000-8000-000000000001'),
    ('f8c00000-0000-4000-8000-000000000002','f8000000-0000-4000-8000-00000000000a',
     '2026-02-02','f8a00000-0000-4000-8000-00000000000a', now()-interval '2 min',
     'needs_verification',1, now()-interval '1 min',1,'f8b00000-0000-4000-8000-000000000002'),
    ('f8c00000-0000-4000-8000-000000000003','f8000000-0000-4000-8000-00000000000a',
     '2026-02-03','f8a00000-0000-4000-8000-00000000000a', now()-interval '2 min',
     'claimed',1, now()-interval '1 min',1, null),
    ('f8c00000-0000-4000-8000-000000000004','f8000000-0000-4000-8000-00000000000a',
     '2026-02-04','f8a00000-0000-4000-8000-00000000000a', now()-interval '2 min',
     'pending',0, null,null,'f8b00000-0000-4000-8000-000000000004');
end $$;

-- ── First finalize: job + post + counter ─────────────────────────────────────
select app.finalize_publish('f8c00000-0000-4000-8000-000000000001', 'FBID_1');

select t.expect('JOBS-8','job becomes published with the fb id',
  (select status from publish_jobs where id='f8c00000-0000-4000-8000-000000000001')='published'
  and (select fb_post_id from publish_jobs where id='f8c00000-0000-4000-8000-000000000001')='FBID_1',
  'job not marked published');

select t.expect('JOBS-8','the attached post is marked published',
  (select status from posts where id='f8b00000-0000-4000-8000-000000000001')='published'
  and (select published_at is not null from posts where id='f8b00000-0000-4000-8000-000000000001')
  and (select fb_post_id from posts where id='f8b00000-0000-4000-8000-000000000001')='FBID_1',
  'post not finalized');

select t.expect('JOBS-8','the daily published counter is 1',
  (select published from usage_counters
     where org_id='f8000000-0000-4000-8000-00000000000a'
       and day=(now() at time zone 'Asia/Dhaka')::date)=1,
  'counter not incremented to 1');

-- ── Idempotent repeat: same id, no second increment ──────────────────────────
select app.finalize_publish('f8c00000-0000-4000-8000-000000000001', 'FBID_1');
select t.expect('JOBS-8','a repeat finalize does not double-count',
  (select published from usage_counters
     where org_id='f8000000-0000-4000-8000-00000000000a'
       and day=(now() at time zone 'Asia/Dhaka')::date)=1,
  'idempotent repeat incremented the counter');

-- ── A different id on a published job is refused ─────────────────────────────
select t.expect_denied('JOBS-8','a different fb id on a published job is refused',
  $$select app.finalize_publish('f8c00000-0000-4000-8000-000000000001','FBID_OTHER')$$);

-- ── Recovery path: needs_verification -> published ───────────────────────────
select app.finalize_publish('f8c00000-0000-4000-8000-000000000002', 'FBID_2');
select t.expect('JOBS-8','a needs_verification job can be finalized (recovery)',
  (select status from publish_jobs where id='f8c00000-0000-4000-8000-000000000002')='published',
  'recovery finalize did not publish');

select t.expect('JOBS-8','the counter accumulates across jobs in a day',
  (select published from usage_counters
     where org_id='f8000000-0000-4000-8000-00000000000a'
       and day=(now() at time zone 'Asia/Dhaka')::date)=2,
  'second publish did not raise the counter to 2');

-- ── Bad states are refused ───────────────────────────────────────────────────
select t.expect_denied('JOBS-8','a job with no attached post is refused',
  $$select app.finalize_publish('f8c00000-0000-4000-8000-000000000003','FBID_3')$$);

select t.expect_denied('JOBS-8','a pending job cannot be finalized',
  $$select app.finalize_publish('f8c00000-0000-4000-8000-000000000004','FBID_4')$$);

select t.expect_denied('JOBS-8','an empty fb id is refused',
  $$select app.finalize_publish('f8c00000-0000-4000-8000-000000000001','')$$);

-- ── Authorization: only the service role may finalize ────────────────────────
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_denied('JOBS-8','authenticated cannot finalize',
  $$select app.finalize_publish('f8c00000-0000-4000-8000-000000000004','FORGED')$$);
reset request.jwt.claims;
reset role;
