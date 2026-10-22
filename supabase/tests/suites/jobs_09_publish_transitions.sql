-- ============================================================================
-- JOBS-9 — the non-published publish transitions
--   app.mark_job_needs_verification() and app.pause_org_publishing()
-- (migration 20261023010000). Every ambiguous/error outcome routes a claimed
-- job to needs_verification (never failed, K6); a config fault also pauses the
-- org (API_INTEGRATIONS §5.1).
-- ============================================================================

do $$
begin
  insert into orgs (id, name, region, created_by) values
    ('fc000000-0000-4000-8000-00000000000a', 'Transitions', 'bd',
     'a0000000-0000-4000-8000-000000000001');
  insert into org_settings (org_id) values ('fc000000-0000-4000-8000-00000000000a');
  insert into schedule_slots (id, org_id, local_time) values
    ('fca00000-0000-4000-8000-00000000000a', 'fc000000-0000-4000-8000-00000000000a', '09:00');
  insert into posts (id, org_id, body, grapheme_count, codepoint_count,
                     word_count, bangla_ratio, status) values
    ('fcb00000-0000-4000-8000-000000000001','fc000000-0000-4000-8000-00000000000a',
     'post এক', 7,7,2,0.5,'approved');
  -- A claimed, already-sent job (the publisher holds the lease), and a pending
  -- job (wrong state for these transitions).
  insert into publish_jobs
    (id, org_id, run_date, slot_id, scheduled_at, status, attempts,
     request_sent_at, request_sent_attempt, post_id) values
    ('fcc00000-0000-4000-8000-000000000001','fc000000-0000-4000-8000-00000000000a',
     '2026-03-01','fca00000-0000-4000-8000-00000000000a', now()-interval '2 min',
     'claimed',1, now()-interval '1 min',1,'fcb00000-0000-4000-8000-000000000001'),
    ('fcc00000-0000-4000-8000-000000000002','fc000000-0000-4000-8000-00000000000a',
     '2026-03-02','fca00000-0000-4000-8000-00000000000a', now()-interval '2 min',
     'pending',0, null,null,null);
end $$;

-- ── mark_job_needs_verification moves a claimed job and records the reason ────
select app.mark_job_needs_verification('fcc00000-0000-4000-8000-000000000001',
  'unconfirmed Graph error (code 506)');

select t.expect('JOBS-9','a claimed job becomes needs_verification with the reason',
  (select status from publish_jobs where id='fcc00000-0000-4000-8000-000000000001')='needs_verification'
  and (select last_error from publish_jobs where id='fcc00000-0000-4000-8000-000000000001')
      = 'unconfirmed Graph error (code 506)',
  'job not moved to needs_verification');

select t.expect('JOBS-9','the write-once request marker is untouched by the move',
  (select request_sent_at is not null from publish_jobs
     where id='fcc00000-0000-4000-8000-000000000001'),
  'request_sent_at was disturbed');

-- ── a job that is not claimed cannot be moved ────────────────────────────────
select t.expect_denied('JOBS-9','a pending job cannot be marked needs_verification',
  $$select app.mark_job_needs_verification('fcc00000-0000-4000-8000-000000000002','x')$$);

-- ── pause_org_publishing stops the org and audits it ─────────────────────────
select app.pause_org_publishing('fc000000-0000-4000-8000-00000000000a',
  'permission or capability fault (code 10)');

select t.expect('JOBS-9','pause_org_publishing sets paused = true',
  (select paused from org_settings where org_id='fc000000-0000-4000-8000-00000000000a'),
  'org not paused');

select t.expect('JOBS-9','the pause is written to the audit log',
  exists(select 1 from audit_logs
          where org_id='fc000000-0000-4000-8000-00000000000a'
            and action='publishing.paused'),
  'pause not audited');

-- ── Authorization: only the service role may call either ─────────────────────
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_denied('JOBS-9','authenticated cannot mark needs_verification',
  $$select app.mark_job_needs_verification('fcc00000-0000-4000-8000-000000000001','forged')$$);
select t.expect_denied('JOBS-9','authenticated cannot pause an org',
  $$select app.pause_org_publishing('fc000000-0000-4000-8000-00000000000a','forged')$$);
reset request.jwt.claims;
reset role;
