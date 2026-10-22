-- ============================================================================
-- 20261023020000_manual_publish.sql — on-demand ("publish now") enqueue
--
-- The scheduled model creates one job per time-slot per day. A manual "publish
-- this draft now" does not fit that shape, so it gets its own enqueue that still
-- runs through the SAME tested publish path (claim → mark_request_sent →
-- finalize / needs_verification), so R4 holds unchanged.
--
--   * enqueue_manual_publish — owner-only; approves the draft if needed and
--     creates ONE due job for it, on a throwaway disabled slot (so the scheduler
--     never touches it) with a microsecond-unique local_time (so same-day manual
--     publishes do not collide on the (org, run_date, slot) key). posts already
--     carry a one-job-per-post unique index, so a post cannot be queued twice.
--   * claim_job — claims ONE named job (the one just enqueued), honouring the
--     same kill_switch/paused exclusion as claim_due_job, so the publisher can
--     process exactly the post the owner chose rather than the oldest due job.
--
-- Both service_role only; the publish-now Edge Function derives p_actor from the
-- caller's verified token, never the body, and ownership is re-checked here.
-- ============================================================================

create or replace function app.enqueue_manual_publish(
  p_actor uuid,
  p_org   uuid,
  p_post  uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.post_status;
  v_tz     text;
  v_slot   uuid;
  v_job    uuid;
begin
  -- Ownership (R11), re-checked in the write's transaction.
  if not exists (
    select 1 from public.memberships m
     where m.org_id = p_org and m.user_id = p_actor and m.role = 'owner'
  ) then
    raise exception 'enqueue_manual_publish: actor is not an owner of the org'
      using errcode = '42501';
  end if;

  -- The post must be this org's, and publishable. Lock it so the approve and the
  -- job insert are one unit.
  select status into v_status
    from public.posts
   where id = p_post and org_id = p_org
   for update;
  if not found then
    raise exception 'enqueue_manual_publish: no such post in this org'
      using errcode = 'P0002';
  end if;
  if v_status not in ('draft', 'approved') then
    raise exception 'enqueue_manual_publish: post is % and cannot be published', v_status
      using errcode = '22023';
  end if;

  -- Clicking "publish now" is the approval. Record it if not already approved.
  if v_status = 'draft' then
    update public.posts
       set status = 'approved', approved_by = p_actor, approved_at = now()
     where id = p_post;
  end if;

  select timezone into v_tz from public.org_settings where org_id = p_org;

  -- A throwaway, disabled slot carries the ad-hoc job's FK. enabled = false so
  -- materialize_jobs never creates scheduled jobs from it; a microsecond-unique
  -- local_time keeps several same-day manual publishes from colliding.
  insert into public.schedule_slots (org_id, local_time, enabled)
  values (p_org, clock_timestamp()::time, false)
  returning id into v_slot;

  -- Due now, so claim_job sees it immediately. The one-job-per-post unique index
  -- raises 23505 if this post is already queued or published.
  insert into public.publish_jobs
    (org_id, run_date, slot_id, scheduled_at, status, post_id)
  values
    (p_org, (now() at time zone v_tz)::date, v_slot, now(), 'pending', p_post)
  returning id into v_job;

  insert into public.audit_logs (org_id, actor, action, detail)
  values (p_org, p_actor, 'publish.enqueued_manual',
          jsonb_build_object('post_id', p_post, 'job_id', v_job));

  return v_job;
end;
$$;

-- Claim ONE named job, with the same stopped-org exclusion as claim_due_job.
create or replace function app.claim_job(p_job uuid)
returns setof public.publish_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.publish_jobs;
begin
  update public.publish_jobs j set
    status      = 'claimed',
    attempts    = attempts + 1,
    claimed_at  = now(),
    lease_until = now() + interval '5 minutes',
    updated_at  = now()
  where j.id = (
    select jj.id
      from public.publish_jobs jj
      join public.org_settings os on os.org_id = jj.org_id
     where jj.id = p_job
       and jj.status = 'pending'
       and jj.scheduled_at <= now()
       and jj.scheduled_at >  now() - interval '45 minutes'
       and os.kill_switch = false
       and os.paused      = false
     for update skip locked
     limit 1
  )
  returning j.* into v_job;

  if found then
    return next v_job;
  end if;
  return;
end;
$$;

revoke all on function app.enqueue_manual_publish(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function app.enqueue_manual_publish(uuid, uuid, uuid) to service_role;

revoke all on function app.claim_job(uuid) from public, anon, authenticated;
grant execute on function app.claim_job(uuid) to service_role;
