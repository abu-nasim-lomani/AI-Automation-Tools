-- ============================================================================
-- 20261022240000_finalize_publish.sql — app.finalize_publish()
--
-- The success path of the publish state machine: a claimed (or recovered
-- needs_verification) job that reached Facebook becomes `published`, its post
-- is marked published, and the org's daily published counter rises by one —
-- all in one transaction (DATABASE.md §6.1, J8).
--
-- Idempotent [F-12]: a second call with the SAME fb_post_id is a no-op, with
-- no second counter increment. This matters because a finalize can be retried
-- after a crash between the Graph 200 and the commit, and a double count would
-- silently corrupt the usage figures the buffer and quota logic rely on.
--
-- security definer, empty search_path, execute revoked from client roles and
-- granted to service_role only. finalize_publish writes a `published` state, so
-- a client able to call it could forge a published job (SECURITY.md T23) —
-- hence service_role only, enforced by the grant, asserted by SEC-23.
--
-- It runs as its owner, so current_user is neither 'authenticated' nor 'anon';
-- prevent_published_mutation (0003) therefore permits the posts write, and the
-- idempotent repeat on an already-published post is permitted too.
-- ============================================================================

create or replace function app.finalize_publish(p_job uuid, p_fb_post_id text)
returns public.publish_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.publish_jobs;
  v_tz  text;
  v_day date;
begin
  if p_fb_post_id is null or length(btrim(p_fb_post_id)) = 0 then
    raise exception 'finalize_publish: fb_post_id is required'
      using errcode = '23514';
  end if;

  -- Lock the job row so two concurrent finalizes serialize rather than both
  -- incrementing the counter (JOBS §6.1).
  select * into v_job from public.publish_jobs where id = p_job for update;
  if not found then
    raise exception 'finalize_publish: job % not found', p_job
      using errcode = '23503';
  end if;

  -- Idempotent repeat. Same id: no-op, no increment. Different id: refuse —
  -- a published job cannot be re-pointed at another post.
  if v_job.status = 'published' then
    if v_job.fb_post_id is distinct from p_fb_post_id then
      raise exception
        'finalize_publish: job % already published as %, refusing %',
        p_job, v_job.fb_post_id, p_fb_post_id using errcode = '23505';
    end if;
    return v_job;
  end if;

  -- Only a job that was sent (claimed) or is being recovered
  -- (needs_verification) can be finalized.
  if v_job.status not in ('claimed', 'needs_verification') then
    raise exception 'finalize_publish: job % is %, not finalizable',
      p_job, v_job.status using errcode = '23514';
  end if;

  if v_job.post_id is null then
    raise exception 'finalize_publish: job % has no attached post', p_job
      using errcode = '23514';
  end if;

  update public.publish_jobs
     set status      = 'published',
         fb_post_id  = p_fb_post_id,
         lease_until = null,
         updated_at  = now()
   where id = p_job
  returning * into v_job;

  update public.posts
     set status       = 'published',
         published_at = now(),
         fb_post_id   = p_fb_post_id
   where id = v_job.post_id
     and org_id = v_job.org_id;

  -- published +1 for the org's local day. Reached only on the first
  -- transition, so the increment happens exactly once per job.
  select timezone into v_tz from public.org_settings where org_id = v_job.org_id;
  v_day := (now() at time zone coalesce(v_tz, 'Asia/Dhaka'))::date;

  insert into public.usage_counters (org_id, day, published)
  values (v_job.org_id, v_day, 1)
  on conflict (org_id, day)
    do update set published = usage_counters.published + 1;

  return v_job;
end;
$$;

revoke all on function app.finalize_publish(uuid, text) from public, anon, authenticated;
grant execute on function app.finalize_publish(uuid, text) to service_role;
