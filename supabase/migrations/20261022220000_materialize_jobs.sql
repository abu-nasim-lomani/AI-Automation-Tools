-- ============================================================================
-- 20261022220000_materialize_jobs.sql — app.materialize_jobs()
--
-- The first piece of the job engine. Turns schedule_slots into publish_jobs
-- rows for a rolling horizon, and attaches an approved post to each. This is
-- the step docs/DATABASE.md referenced but never defined; the specification is
-- docs/JOBS_AND_SCHEDULING.md §3.
--
-- It makes NO outbound call, so it is the one clock ADR-017 keeps inside the
-- database (on pg_cron), away from the net schema ADR-015 could not close.
--
-- security definer with an empty search_path, execute revoked from every
-- client role: no caller other than the clock may invoke it. It runs as its
-- owner (the migration role), which owns the tenant tables and so is not
-- filtered by their RLS — materialization is deliberately cross-org work that
-- no single tenant's policy would permit.
--
-- Idempotent by two independent means (JOBS §3.2): the (org_id, run_date,
-- slot_id) unique key makes a repeated run insert nothing, and the
-- one-post-per-job unique index makes a concurrent attach fail rather than
-- double-attach. Re-running the whole function is therefore free and safe,
-- which is why the clock can fire hourly with no catch-up path.
--
-- This migration defines the function only. Registering the hourly pg_cron
-- schedule that calls it is the deliberate "turn the engine on" step, done
-- when a real org exists and the function has been exercised on the hosted
-- project — not as a side effect of applying a migration.
-- ============================================================================

create or replace function app.materialize_jobs(p_horizon_days int default 2)
returns table (jobs_created int, posts_attached int)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_created   int := 0;
  v_attached  int := 0;
  o           record;
  s           record;
  i           int;
  v_today     date;
  v_date      date;
  v_scheduled timestamptz;
  v_job_id    uuid;
  v_post_id   uuid;
begin
  -- A horizon beyond a fortnight is almost certainly a caller error, and a
  -- negative one is nonsense. Fail loudly rather than materialize a wild range.
  if p_horizon_days < 0 or p_horizon_days > 14 then
    raise exception 'materialize_jobs: horizon out of range (%).', p_horizon_days;
  end if;

  for o in
    select og.id as org_id, os.timezone as tz
      from public.orgs og
      join public.org_settings os on os.org_id = og.id
     where og.deleted_at is null
  loop
    -- "Today" is the local date in the org's own timezone, so a slot near
    -- midnight lands on the date the owner means (JOBS §4).
    v_today := (now() at time zone o.tz)::date;

    -- ── Create jobs for every enabled slot across the horizon ──────────────
    for i in 0 .. p_horizon_days loop
      v_date := v_today + i;

      for s in
        select sl.id as slot_id, sl.local_time
          from public.schedule_slots sl
         where sl.org_id = o.org_id
           and sl.enabled = true
      loop
        -- Interpret the wall-clock slot time in the org's timezone to get the
        -- UTC instant. `at time zone` on a plain timestamp returns timestamptz.
        v_scheduled := (v_date + s.local_time) at time zone o.tz;

        -- A slot already more than 45 minutes past would only be skipped the
        -- moment it was claimed (JOBS §3.2 step 5, F J5); creating it is noise.
        if v_scheduled < now() - interval '45 minutes' then
          continue;
        end if;

        insert into public.publish_jobs (org_id, run_date, slot_id, scheduled_at)
        values (o.org_id, v_date, s.slot_id, v_scheduled)
        on conflict (org_id, run_date, slot_id) do nothing
        returning id into v_job_id;

        if v_job_id is not null then
          v_created := v_created + 1;
        end if;
      end loop;
    end loop;

    -- ── Reconcile attachments (JOBS §3.4, early binding) ───────────────────
    -- Detach any pending job whose post is no longer approved: publishing a
    -- rejected post is worse than missing a slot. The freed slot is re-filled
    -- by the pass below, in the same run.
    update public.publish_jobs j
       set post_id = null
      from public.posts p
     where j.org_id = o.org_id
       and j.status = 'pending'
       and j.post_id = p.id
       and p.status <> 'approved';

    -- Fill each pending job that lacks a post, earliest slot first, with the
    -- oldest approved post not already attached anywhere. An empty buffer
    -- simply leaves the job pending with post_id null (JOBS §7.2 handles it).
    for v_job_id in
      select j.id
        from public.publish_jobs j
       where j.org_id = o.org_id
         and j.status = 'pending'
         and j.post_id is null
       order by j.scheduled_at asc
    loop
      select p.id
        into v_post_id
        from public.posts p
       where p.org_id = o.org_id
         and p.status = 'approved'
         and not exists (
           select 1 from public.publish_jobs j2 where j2.post_id = p.id
         )
       order by p.created_at asc
       limit 1;

      exit when v_post_id is null;   -- buffer exhausted for this org

      update public.publish_jobs
         set post_id = v_post_id
       where id = v_job_id;

      v_attached := v_attached + 1;
    end loop;
  end loop;

  -- One summary row per run, never one per job (JOBS §3.2 step 8). No actor:
  -- the clock has no human identity. org_id is null because the run spans orgs.
  insert into public.audit_logs (org_id, actor, action, detail)
  values (
    null, null, 'materialize_jobs',
    jsonb_build_object(
      'horizon_days',   p_horizon_days,
      'jobs_created',   v_created,
      'posts_attached', v_attached
    )
  );

  jobs_created   := v_created;
  posts_attached := v_attached;
  return next;
end;
$$;

-- Execute defaults to PUBLIC; anon inherits it. Close it, as the §6.1 pattern
-- does for every app function. The owner (the clock's role) always retains it.
revoke all on function app.materialize_jobs(int) from public, anon, authenticated;
