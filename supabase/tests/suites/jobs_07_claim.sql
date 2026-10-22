-- ============================================================================
-- JOBS-7 — the publisher's SQL spine (docs/JOBS_AND_SCHEDULING.md §5.3)
--
-- claim_due_job / mark_request_sent / reclaim_expired_leases / skip_stale_jobs.
--
-- claim_due_job picks the globally oldest due job, so this suite first clears
-- publish_jobs and builds its own, to keep the assertions independent of what
-- earlier suites left behind. The DB is rebuilt per run, and this suite runs
-- last, so the delete is safe.
-- ============================================================================

do $$
begin
  delete from public.publish_jobs;

  insert into orgs (id, name, region, created_by) values
    ('f7000000-0000-4000-8000-00000000000a', 'Live', 'bd',  'a0000000-0000-4000-8000-000000000001'),
    ('f7000000-0000-4000-8000-00000000000b', 'Paused', 'bd','a0000000-0000-4000-8000-000000000001'),
    ('f7000000-0000-4000-8000-00000000000c', 'Killed', 'bd','a0000000-0000-4000-8000-000000000001');

  insert into org_settings (org_id, paused, kill_switch) values
    ('f7000000-0000-4000-8000-00000000000a', false, false),
    ('f7000000-0000-4000-8000-00000000000b', true,  false),
    ('f7000000-0000-4000-8000-00000000000c', false, true);

  insert into schedule_slots (id, org_id, local_time) values
    ('f7a00000-0000-4000-8000-00000000000a', 'f7000000-0000-4000-8000-00000000000a', '12:00'),
    ('f7a00000-0000-4000-8000-00000000000b', 'f7000000-0000-4000-8000-00000000000b', '12:00'),
    ('f7a00000-0000-4000-8000-00000000000c', 'f7000000-0000-4000-8000-00000000000c', '12:00');

  -- Live org: claimable, non-claimable, and already-claimed (lease) fixtures.
  insert into publish_jobs
    (id, org_id, run_date, slot_id, scheduled_at, status, attempts,
     lease_until, request_sent_at, request_sent_attempt) values
    -- due, oldest
    ('f7b00000-0000-4000-8000-000000000001','f7000000-0000-4000-8000-00000000000a',
     '2026-01-01','f7a00000-0000-4000-8000-00000000000a', now()-interval '5 min','pending',0,null,null,null),
    -- due, newer
    ('f7b00000-0000-4000-8000-000000000002','f7000000-0000-4000-8000-00000000000a',
     '2026-01-02','f7a00000-0000-4000-8000-00000000000a', now()-interval '3 min','pending',0,null,null,null),
    -- not yet due
    ('f7b00000-0000-4000-8000-000000000003','f7000000-0000-4000-8000-00000000000a',
     '2026-01-03','f7a00000-0000-4000-8000-00000000000a', now()+interval '1 day','pending',0,null,null,null),
    -- window closed (stale), for the skip sweep
    ('f7b00000-0000-4000-8000-000000000004','f7000000-0000-4000-8000-00000000000a',
     '2026-01-04','f7a00000-0000-4000-8000-00000000000a', now()-interval '2 hours','pending',0,null,null,null),
    -- claimed, lease expired, HAS sent  -> needs_verification
    ('f7b00000-0000-4000-8000-000000000005','f7000000-0000-4000-8000-00000000000a',
     '2026-01-05','f7a00000-0000-4000-8000-00000000000a', now()-interval '10 min','claimed',1,
     now()-interval '1 min', now()-interval '9 min', 1),
    -- claimed, lease expired, never sent, retries remain -> pending
    ('f7b00000-0000-4000-8000-000000000006','f7000000-0000-4000-8000-00000000000a',
     '2026-01-06','f7a00000-0000-4000-8000-00000000000a', now()-interval '10 min','claimed',1,
     now()-interval '1 min', null, null),
    -- claimed, lease expired, never sent, retries exhausted -> failed
    ('f7b00000-0000-4000-8000-000000000007','f7000000-0000-4000-8000-00000000000a',
     '2026-01-07','f7a00000-0000-4000-8000-00000000000a', now()-interval '10 min','claimed',3,
     now()-interval '1 min', null, null),
    -- claimed, lease still live -> untouched by reclaim
    ('f7b00000-0000-4000-8000-000000000008','f7000000-0000-4000-8000-00000000000a',
     '2026-01-08','f7a00000-0000-4000-8000-00000000000a', now()-interval '10 min','claimed',1,
     now()+interval '5 min', null, null),
    -- paused org: due but must never be claimed
    ('f7b00000-0000-4000-8000-00000000000b','f7000000-0000-4000-8000-00000000000b',
     '2026-01-01','f7a00000-0000-4000-8000-00000000000b', now()-interval '5 min','pending',0,null,null,null),
    -- killed org: due but must never be claimed
    ('f7b00000-0000-4000-8000-00000000000c','f7000000-0000-4000-8000-00000000000c',
     '2026-01-01','f7a00000-0000-4000-8000-00000000000c', now()-interval '5 min','pending',0,null,null,null);
end $$;

-- ── claim: oldest first, one at a time ──────────────────────────────────────
select app.claim_due_job();   -- claim #1
select t.expect('JOBS-7','claim takes the oldest due job',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000001') = 'claimed'
  and (select attempts from publish_jobs where id='f7b00000-0000-4000-8000-000000000001') = 1
  and (select lease_until from publish_jobs where id='f7b00000-0000-4000-8000-000000000001') > now(),
  'oldest due job not leased correctly');

select t.expect('JOBS-7','claim leaves the newer due job for the next call',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000002') = 'pending',
  'claimed more than one job at once');

select app.claim_due_job();   -- claim #2
select t.expect('JOBS-7','a second claim takes the next due job',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000002') = 'claimed',
  'second due job not claimed');

select t.expect_count('JOBS-7','claim returns nothing when none is due',
  $$select * from app.claim_due_job()$$, 0);

select t.expect('JOBS-7','a future job is never claimed',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000003') = 'pending',
  'a not-yet-due job was claimed');

-- ── paused and killed orgs are skipped (A4 refinement of §5.3) ───────────────
select t.expect('JOBS-7','a paused org job is never claimed',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-00000000000b') = 'pending',
  'a paused org job was leased');

select t.expect('JOBS-7','a kill-switched org job is never claimed',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-00000000000c') = 'pending',
  'a kill-switched org job was leased');

-- ── phase-2 marker: write-once ──────────────────────────────────────────────
select app.mark_request_sent('f7b00000-0000-4000-8000-000000000001');
create temp table marker_first as
  select request_sent_at as ts from publish_jobs
   where id='f7b00000-0000-4000-8000-000000000001';

select t.expect('JOBS-7','marker records the send and the attempt',
  (select request_sent_at is not null from publish_jobs
     where id='f7b00000-0000-4000-8000-000000000001')
  and (select request_sent_attempt from publish_jobs
         where id='f7b00000-0000-4000-8000-000000000001') = 1,
  'first marker not written');

-- bump attempts, mark again: request_sent_at must not move, attempt must update
update publish_jobs set attempts = 2 where id='f7b00000-0000-4000-8000-000000000001';
select app.mark_request_sent('f7b00000-0000-4000-8000-000000000001');
select t.expect('JOBS-7','marker is write-once but the attempt updates',
  (select request_sent_at from publish_jobs where id='f7b00000-0000-4000-8000-000000000001')
      = (select ts from marker_first)
  and (select request_sent_attempt from publish_jobs
         where id='f7b00000-0000-4000-8000-000000000001') = 2,
  'write-once marker changed, or attempt did not update');

select t.expect_denied('JOBS-7','marking a non-claimed job is refused',
  $$select * from app.mark_request_sent('f7b00000-0000-4000-8000-000000000003')$$);

-- ── reclaim sweep: classify expired leases by whether they ever sent ────────
select app.reclaim_expired_leases();
select t.expect('JOBS-7','expired lease that sent -> needs_verification',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000005')='needs_verification',
  'a sent job was not routed to needs_verification');
select t.expect('JOBS-7','expired lease never sent, retries remain -> pending',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000006')='pending',
  'a never-sent job was not requeued');
select t.expect('JOBS-7','expired lease never sent, retries exhausted -> failed',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000007')='failed',
  'an exhausted never-sent job was not failed');
select t.expect('JOBS-7','a live lease is left alone',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000008')='claimed',
  'a non-expired lease was reclaimed');

-- ── stale-skip sweep ────────────────────────────────────────────────────────
select app.skip_stale_jobs();
select t.expect('JOBS-7','a window-closed pending job is skipped',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-000000000004')='skipped',
  'a stale job was not skipped');
select t.expect('JOBS-7','the stale sweep does not touch a recent pending job',
  (select status from publish_jobs where id='f7b00000-0000-4000-8000-00000000000b')='pending',
  'the stale sweep skipped a non-stale job');

-- ── authorization: no client role may drive the engine ──────────────────────
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_denied('JOBS-7','authenticated cannot claim',
  $$select * from app.claim_due_job()$$);
select t.expect_denied('JOBS-7','authenticated cannot mark',
  $$select * from app.mark_request_sent('f7b00000-0000-4000-8000-000000000002')$$);
select t.expect_denied('JOBS-7','authenticated cannot reclaim',
  $$select app.reclaim_expired_leases()$$);
select t.expect_denied('JOBS-7','authenticated cannot skip',
  $$select app.skip_stale_jobs()$$);
reset request.jwt.claims;
reset role;
