-- ============================================================================
-- 20261022230000_job_claim.sql — the publisher's SQL spine.
--
-- Four functions, all pure SQL with no outbound call, so they can be proven in
-- the harness before the publisher Edge Function (Deno, secrets, Meta) is
-- built on top of them. Specification: docs/JOBS_AND_SCHEDULING.md §5.3 /
-- docs/DATABASE.md §5.2–5.3, which give the claim, marker and reclaim SQL
-- verbatim; this migration packages them as callable functions and adds the
-- stale-skip sweep from §5.2.
--
--   app.claim_due_job()        lease the oldest due job (for a live org)
--   app.mark_request_sent()    phase-2 write-once marker, before the request
--   app.reclaim_expired_leases()  crash recovery for abandoned leases
--   app.skip_stale_jobs()      the 45-minute → skipped sweep
--
-- security definer, empty search_path, execute revoked from client roles and
-- granted to service_role: the publisher Edge Function runs as service_role
-- (CLAUDE.md R5). The clock's role (the owner) always retains execute.
--
-- ── One refinement of frozen §5.3, recorded as JOBS §17.1 A4 ────────────────
-- The frozen claim SQL does not filter on org_settings. If a paused org's jobs
-- were claimed, each claim would increment `attempts` while the publisher
-- declined to send, and after three ticks the reclaim sweep would mark them
-- `failed` (request_sent_at IS NULL, attempts >= 3) — the exact opposite of
-- what §5.5 says pausing should do. So claim_due_job filters out paused and
-- kill_switch orgs. This does NOT replace R9's authoritative kill check, which
-- still runs in the publisher immediately before the request to catch a switch
-- thrown AFTER a claim; it only stops stopped orgs' jobs from being leased and
-- burned in the first place.
-- ============================================================================

-- ── claim ───────────────────────────────────────────────────────────────────
-- Returns 0 or 1 rows: the job just leased, or nothing if none is due. The
-- `for update skip locked` makes two concurrent publishers safe with no
-- distributed lock (JOBS §6 layer 3).
create or replace function app.claim_due_job()
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
     where jj.status = 'pending'
       and jj.scheduled_at <= now()
       and jj.scheduled_at >  now() - interval '45 minutes'
       and os.kill_switch = false        -- A4: do not lease a stopped org's job
       and os.paused      = false
     order by jj.scheduled_at
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

-- ── phase-2 marker ──────────────────────────────────────────────────────────
-- Committed in its own statement BEFORE the outbound request, never in the
-- same transaction as it (JOBS §6.2, J4). request_sent_at is write-once: the
-- coalesce keeps the FIRST send instant, the attempt number is overwritten.
-- The request_sent_at_immutable trigger (0003) is the backstop. Returns the
-- updated row so the caller can read back the committed marker.
create or replace function app.mark_request_sent(p_job uuid)
returns setof public.publish_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.publish_jobs;
begin
  update public.publish_jobs
     set request_sent_at      = coalesce(request_sent_at, now()),
         request_sent_attempt = attempts,
         updated_at           = now()
   where id = p_job
     and status = 'claimed'
  returning * into v_job;

  if not found then
    raise exception 'mark_request_sent: job % is not claimed', p_job
      using errcode = '23514';
  end if;
  return next v_job;
end;
$$;

-- ── reclaim sweep ───────────────────────────────────────────────────────────
-- Expired leases only. Keyed on whether the job has EVER sent (request_sent_at),
-- never on the per-attempt marker, because a marker stale for the current
-- attempt says nothing about earlier attempts (K16). Returns the count moved.
create or replace function app.reclaim_expired_leases()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.publish_jobs
     set status = (case
           when request_sent_at is not null then 'needs_verification'
           when attempts >= 3               then 'failed'
           else                                  'pending'
         end)::public.job_status,
         lease_until = null,
         updated_at  = now()
   where status = 'claimed'
     and lease_until < now();
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ── stale-skip sweep ────────────────────────────────────────────────────────
-- A pending job whose slot window closed (more than 45 minutes past) is
-- skipped, never failed: nothing was attempted (DATABASE.md §5.2). Returns the
-- count skipped.
create or replace function app.skip_stale_jobs()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.publish_jobs
     set status = 'skipped',
         updated_at = now()
   where status = 'pending'
     and scheduled_at < now() - interval '45 minutes';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ── grants: service_role (the publisher runtime) only ───────────────────────
revoke all on function app.claim_due_job()          from public, anon, authenticated;
revoke all on function app.mark_request_sent(uuid)  from public, anon, authenticated;
revoke all on function app.reclaim_expired_leases() from public, anon, authenticated;
revoke all on function app.skip_stale_jobs()        from public, anon, authenticated;
grant execute on function app.claim_due_job()          to service_role;
grant execute on function app.mark_request_sent(uuid)  to service_role;
grant execute on function app.reclaim_expired_leases() to service_role;
grant execute on function app.skip_stale_jobs()        to service_role;
