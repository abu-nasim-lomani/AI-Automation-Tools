-- ============================================================================
-- JOBS-3 — app.materialize_jobs() (docs/JOBS_AND_SCHEDULING.md §3)
--
-- Builds three isolated test orgs so the assertions do not depend on the
-- shared seed:
--   f-org: one enabled slot (23:30) + one disabled slot (06:00), two approved
--          posts of known age — exercises creation, the disabled-slot skip,
--          early binding and oldest-first ordering.
--   e-org: one enabled slot, no approved posts — exercises the empty buffer.
--   d-org: soft-deleted, one enabled slot — must be skipped entirely.
--
-- 23:30 and 12:00 are chosen so the +1 and +2 horizon dates are always in the
-- future regardless of the wall clock, which keeps the counts deterministic.
-- ============================================================================

-- ── Fixtures (as the superuser; RLS is not the subject here) ────────────────
do $$
begin
  insert into orgs (id, name, region, created_by) values
    ('f0000000-0000-4000-8000-0000000000ff', 'Mat F', 'bd',
     'a0000000-0000-4000-8000-000000000001'),
    ('f0000000-0000-4000-8000-0000000000e0', 'Mat E (empty buffer)', 'bd',
     'a0000000-0000-4000-8000-000000000001'),
    ('f0000000-0000-4000-8000-0000000000d0', 'Mat D (deleted)', 'bd',
     'a0000000-0000-4000-8000-000000000001');

  update orgs set deleted_at = now()
   where id = 'f0000000-0000-4000-8000-0000000000d0';

  insert into org_settings (org_id) values
    ('f0000000-0000-4000-8000-0000000000ff'),
    ('f0000000-0000-4000-8000-0000000000e0'),
    ('f0000000-0000-4000-8000-0000000000d0');

  insert into schedule_slots (id, org_id, local_time, enabled) values
    ('fa000000-0000-4000-8000-000000000001',
     'f0000000-0000-4000-8000-0000000000ff', '23:30', true),
    ('fa000000-0000-4000-8000-000000000002',
     'f0000000-0000-4000-8000-0000000000ff', '06:00', false),
    ('fa000000-0000-4000-8000-000000000003',
     'f0000000-0000-4000-8000-0000000000e0', '12:00', true),
    ('fa000000-0000-4000-8000-000000000004',
     'f0000000-0000-4000-8000-0000000000d0', '12:00', true);

  -- Two approved posts in f-org, with explicit ages so "oldest first" is testable.
  insert into posts (id, org_id, body, grapheme_count, codepoint_count,
                     word_count, bangla_ratio, status, created_at) values
    ('fb000000-0000-4000-8000-000000000001',
     'f0000000-0000-4000-8000-0000000000ff', 'পুরনো approved post', 18, 18, 3, 0.700,
     'approved', now() - interval '2 days'),
    ('fb000000-0000-4000-8000-000000000002',
     'f0000000-0000-4000-8000-0000000000ff', 'নতুন approved post', 17, 17, 3, 0.700,
     'approved', now() - interval '1 day');
end $$;

-- ── Run 1 ───────────────────────────────────────────────────────────────────
select app.materialize_jobs(2);

-- ── Creation, skip rule, horizon ─────────────────────────────────────────────
select t.expect('JOBS-3','materialize creates jobs for the test org',
  (select count(*) from publish_jobs where org_id='f0000000-0000-4000-8000-0000000000ff') > 0,
  'no jobs were created');

select t.expect('JOBS-3','disabled slot produces no job',
  (select count(*) from publish_jobs
     where slot_id='fa000000-0000-4000-8000-000000000002') = 0,
  'a disabled slot was materialized');

select t.expect('JOBS-3','no job is more than 45 minutes in the past',
  (select count(*) from publish_jobs
     where org_id='f0000000-0000-4000-8000-0000000000ff'
       and scheduled_at < now() - interval '45 minutes') = 0,
  'a stale slot was materialized');

select t.expect('JOBS-3','horizon respected: at most 3 distinct run_dates',
  (select count(distinct run_date) from publish_jobs
     where org_id='f0000000-0000-4000-8000-0000000000ff') <= 3,
  'more dates than the 2-day horizon allows');

-- ── Early binding (§3.4) ─────────────────────────────────────────────────────
select t.expect('JOBS-3','earliest job gets the oldest approved post',
  (select post_id from publish_jobs
     where org_id='f0000000-0000-4000-8000-0000000000ff'
     order by scheduled_at asc limit 1) = 'fb000000-0000-4000-8000-000000000001',
  'oldest-first ordering not honoured');

select t.expect('JOBS-3','both approved posts are attached',
  (select count(*) from publish_jobs
     where org_id='f0000000-0000-4000-8000-0000000000ff'
       and post_id is not null) = 2,
  'expected exactly the two approved posts attached');

select t.expect('JOBS-3','empty buffer leaves jobs pending with no post',
  (select count(*) from publish_jobs
     where org_id='f0000000-0000-4000-8000-0000000000e0'
       and post_id is not null) = 0
  and (select count(*) from publish_jobs
         where org_id='f0000000-0000-4000-8000-0000000000e0') > 0,
  'an empty buffer should still create jobs, all unattached');

select t.expect('JOBS-3','a soft-deleted org is skipped',
  (select count(*) from publish_jobs
     where org_id='f0000000-0000-4000-8000-0000000000d0') = 0,
  'a deleted org was materialized');

select t.expect('JOBS-3','no job attaches a post from another org',
  (select count(*) from publish_jobs j
     join posts p on p.id = j.post_id
    where j.org_id <> p.org_id) = 0,
  'a cross-org post was attached');

-- ── Idempotency (§3.2): a second run changes nothing ────────────────────────
create temp table jobs_before as select count(*) as c from publish_jobs;
select app.materialize_jobs(2);
select t.expect('JOBS-3','re-running creates no new jobs',
  (select count(*) from publish_jobs) = (select c from jobs_before),
  'a second identical run changed the row count');

-- ── Detach on reject (§3.4) ─────────────────────────────────────────────────
update posts set status='rejected'
 where id='fb000000-0000-4000-8000-000000000001';
select app.materialize_jobs(2);
select t.expect('JOBS-3','a rejected post is detached from its job',
  (select count(*) from publish_jobs
     where post_id='fb000000-0000-4000-8000-000000000001') = 0,
  'a rejected post is still attached');

-- ── Audit (§3.2 step 8): one summary row per run, not one per job ───────────
select t.expect('JOBS-3','a materialize summary is audited',
  (select count(*) from audit_logs where action='materialize_jobs') >= 1,
  'no materialize audit row');

-- ── Guard rail: an absurd horizon is refused ────────────────────────────────
select t.expect_denied('JOBS-3','a horizon beyond the cap is rejected',
  $$select app.materialize_jobs(99)$$);

-- ── Authorization (§3.1): no client role may invoke the clock ───────────────
set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_denied('JOBS-3','authenticated cannot invoke materialize',
  $$select app.materialize_jobs(2)$$);
reset request.jwt.claims;
reset role;
