-- ============================================================================
-- 20261023010000_publish_transitions.sql — the non-published outcomes
--
-- app.finalize_publish already handles the one happy outcome (2xx + id →
-- published, JOBS §9.2 J8). The publisher needs two more transitions, and these
-- are all it needs, because JOBS §9.2 and API_INTEGRATIONS §5 route EVERY other
-- outcome to needs_verification — no API response ever yields `failed` (K6):
--
--   * mark_job_needs_verification — a timeout, 5xx, unparseable body, 2xx with
--     no id, a 506, or any other Graph error. The outcome is unknown, so the
--     read-back verifier decides; R4 forbids an automatic return to pending.
--   * pause_org_publishing — a Class A configuration fault (codes 3, 10,
--     200–299): the Page/token/app is misconfigured, so stop the org and alert
--     once rather than attempt every slot (API_INTEGRATIONS §5.1). The job is
--     still only moved to needs_verification; pausing is the ADDITIONAL action.
--
-- Both are service_role only — the publisher runs as the service role on the
-- job clock, never a client. Neither resets request_sent_at (it is write-once,
-- trigger-enforced) and neither touches a published job.
-- ============================================================================

-- A job the publisher could not resolve cleanly. It holds the claim, so the
-- guard is status = 'claimed'. last_error carries a code + safe reason only,
-- never an upstream body (schema note on publish_jobs.last_error, R3).
create or replace function app.mark_job_needs_verification(p_job uuid, p_reason text)
returns setof public.publish_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.publish_jobs;
begin
  update public.publish_jobs
     set status     = 'needs_verification',
         last_error = left(coalesce(p_reason, ''), 500),
         updated_at = now()
   where id = p_job
     and status = 'claimed'
  returning * into v_job;

  if not found then
    raise exception 'mark_job_needs_verification: job % is not claimed', p_job
      using errcode = '23514';
  end if;
  return next v_job;
end;
$$;

-- A configuration fault pauses the org's publishing (and generation): R9 says
-- `paused` stops publish and generate but lets verification keep reconciling.
-- A system action, so actor is null; the reason is a safe string, never a body.
create or replace function app.pause_org_publishing(p_org uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.org_settings
     set paused = true, updated_at = now()
   where org_id = p_org;

  insert into public.audit_logs (org_id, actor, action, detail)
  values (p_org, null, 'publishing.paused',
          jsonb_build_object('reason', left(coalesce(p_reason, ''), 500)));
end;
$$;

revoke all on function app.mark_job_needs_verification(uuid, text) from public, anon, authenticated;
grant execute on function app.mark_job_needs_verification(uuid, text) to service_role;

revoke all on function app.pause_org_publishing(uuid, text) from public, anon, authenticated;
grant execute on function app.pause_org_publishing(uuid, text) to service_role;
