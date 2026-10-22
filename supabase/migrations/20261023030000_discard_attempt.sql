-- ============================================================================
-- 20261023030000_discard_attempt.sql — app.discard_failed_attempt()
--
-- The guarded human resolution for a stuck publish (R4, DATABASE §5.2.1). When a
-- publish ends in needs_verification, the post keeps the job, and one-job-per-
-- post then blocks re-publishing it. If the owner has confirmed the post did NOT
-- appear on the Page (the "attestation of absence" R4 permits), this detaches
-- that attempt — marking it `skipped` and nulling its post_id, so it stays as
-- history AND the post can be published again.
--
-- It NEVER touches a published job (that is final) or an in-flight claimed one.
--
-- Client-callable (like create_org): security definer, authorises on auth.uid()
-- so the caller cannot name someone else, and owner-only (R11).
-- ============================================================================

create or replace function app.discard_failed_attempt(p_org uuid, p_post uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor  uuid := auth.uid();
  v_job    uuid;
  v_status public.job_status;
begin
  if v_actor is null then
    raise exception 'discard_failed_attempt: no authenticated user'
      using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.memberships m
     where m.org_id = p_org and m.user_id = v_actor and m.role = 'owner'
  ) then
    raise exception 'discard_failed_attempt: actor is not an owner of the org'
      using errcode = '42501';
  end if;

  select id, status into v_job, v_status
    from public.publish_jobs
   where org_id = p_org and post_id = p_post
   for update;
  if not found then
    raise exception 'discard_failed_attempt: no attempt attached to this post'
      using errcode = 'P0002';
  end if;
  -- Only a settled, ambiguous attempt may be discarded. Never a published one
  -- (final) and never one still being worked (claimed).
  if v_status <> 'needs_verification' then
    raise exception 'discard_failed_attempt: attempt is % and cannot be discarded', v_status
      using errcode = '22023';
  end if;

  update public.publish_jobs
     set status     = 'skipped',
         post_id    = null,
         last_error = 'discarded by owner (attested not published)',
         updated_at = now()
   where id = v_job;

  insert into public.audit_logs (org_id, actor, action, detail)
  values (p_org, v_actor, 'publish.attempt_discarded',
          jsonb_build_object('post_id', p_post, 'job_id', v_job));
end;
$$;

revoke all on function app.discard_failed_attempt(uuid, uuid) from public, anon;
grant execute on function app.discard_failed_attempt(uuid, uuid) to authenticated;
