-- ============================================================================
-- JOBS-10 — app.enqueue_manual_publish() and app.claim_job()
-- (migration 20261023020000). The on-demand "publish now" enqueue: approve the
-- draft, create ONE due job on a throwaway slot, and claim exactly that job.
-- ============================================================================

do $$
begin
  insert into orgs (id, name, region, created_by) values
    ('fd000000-0000-4000-8000-00000000000a','Manual','bd','a0000000-0000-4000-8000-000000000001');
  insert into memberships (org_id, user_id, role) values
    ('fd000000-0000-4000-8000-00000000000a','a0000000-0000-4000-8000-000000000001','owner');
  insert into org_settings (org_id) values ('fd000000-0000-4000-8000-00000000000a');
  insert into posts (id, org_id, body, grapheme_count, codepoint_count,
                     word_count, bangla_ratio, status) values
    ('fdb00000-0000-4000-8000-000000000001','fd000000-0000-4000-8000-00000000000a','draft এক',8,8,2,0.5,'draft'),
    ('fdb00000-0000-4000-8000-000000000002','fd000000-0000-4000-8000-00000000000a','draft দুই',8,8,2,0.5,'draft'),
    ('fdb00000-0000-4000-8000-000000000003','fd000000-0000-4000-8000-00000000000a','rejected তিন',12,12,2,0.5,'rejected');
end $$;

-- ── enqueue approves the draft and creates one due job ───────────────────────
create temp table enq1(id uuid);
do $$ begin
  insert into enq1 select app.enqueue_manual_publish(
    'a0000000-0000-4000-8000-000000000001',
    'fd000000-0000-4000-8000-00000000000a',
    'fdb00000-0000-4000-8000-000000000001');
exception when others then insert into enq1 values (null);
end $$;

select t.expect('JOBS-10','enqueue returns a job id',
  (select id from enq1) is not null, 'no job id returned');

select t.expect('JOBS-10','the draft is approved by the actor',
  (select status from posts where id='fdb00000-0000-4000-8000-000000000001')='approved'
  and (select approved_by from posts where id='fdb00000-0000-4000-8000-000000000001')
      ='a0000000-0000-4000-8000-000000000001',
  'post not approved');

select t.expect('JOBS-10','a due pending job is attached to the post',
  (select status from publish_jobs where id=(select id from enq1))='pending'
  and (select post_id from publish_jobs where id=(select id from enq1))
      ='fdb00000-0000-4000-8000-000000000001'
  and (select scheduled_at <= now() from publish_jobs where id=(select id from enq1)),
  'job not created due');

-- ── claim_job claims exactly that job ────────────────────────────────────────
create temp table clm(status job_status);
do $$ begin
  insert into clm select status from app.claim_job((select id from enq1));
exception when others then insert into clm values (null);
end $$;
select t.expect('JOBS-10','claim_job claims the named job',
  (select status from clm)='claimed', 'job not claimed');

-- ── a second same-day manual publish does not collide ────────────────────────
create temp table enq2(id uuid);
do $$ begin
  insert into enq2 select app.enqueue_manual_publish(
    'a0000000-0000-4000-8000-000000000001',
    'fd000000-0000-4000-8000-00000000000a',
    'fdb00000-0000-4000-8000-000000000002');
exception when others then insert into enq2 values (null);
end $$;
select t.expect('JOBS-10','a second same-day manual publish enqueues (no slot collision)',
  (select id from enq2) is not null, 'second enqueue collided');

-- ── claim_job returns nothing for a paused org ───────────────────────────────
do $$ begin update org_settings set paused = true where org_id='fd000000-0000-4000-8000-00000000000a'; end $$;
select t.expect('JOBS-10','claim_job yields nothing when the org is paused',
  (select count(*) from app.claim_job((select id from enq2)))=0,
  'a paused org''s job was claimed');
do $$ begin update org_settings set paused = false where org_id='fd000000-0000-4000-8000-00000000000a'; end $$;

-- ── refusals ─────────────────────────────────────────────────────────────────
select t.expect_denied('JOBS-10','a rejected post cannot be enqueued',
  $$select app.enqueue_manual_publish('a0000000-0000-4000-8000-000000000001',
      'fd000000-0000-4000-8000-00000000000a','fdb00000-0000-4000-8000-000000000003')$$);

select t.expect_denied('JOBS-10','the same post cannot be queued twice',
  $$select app.enqueue_manual_publish('a0000000-0000-4000-8000-000000000001',
      'fd000000-0000-4000-8000-00000000000a','fdb00000-0000-4000-8000-000000000001')$$);

select t.expect_denied('JOBS-10','a non-owner cannot enqueue',
  $$select app.enqueue_manual_publish('a0000000-0000-4000-8000-000000000009',
      'fd000000-0000-4000-8000-00000000000a','fdb00000-0000-4000-8000-000000000002')$$);

-- ── Authorization: only the service role may call these ──────────────────────
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_denied('JOBS-10','authenticated cannot enqueue a manual publish',
  $$select app.enqueue_manual_publish('a0000000-0000-4000-8000-000000000001',
      'fd000000-0000-4000-8000-00000000000a','fdb00000-0000-4000-8000-000000000002')$$);
select t.expect_denied('JOBS-10','authenticated cannot claim a job',
  $$select app.claim_job((select id from enq2))$$);
reset request.jwt.claims;
reset role;
