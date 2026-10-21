-- ============================================================================
-- 20261022203000_net_privileges.sql — close the net schema to client roles.
--
-- Observed on the hosted development project on 2026-10-22, before this ran:
--
--   schema net                    {supabase_admin=UC/…, =U/…,
--                                  supabase_functions_admin=U/…, postgres=U/…,
--                                  anon=U/…, authenticated=U/…,
--                                  service_role=U/…}
--   net.http_request_queue        {supabase_admin=arwdDxtm/…, =arwdDxtm/…}
--   net._http_response            {supabase_admin=arwdDxtm/…, =arwdDxtm/…}
--   net.http_request_queue_id_seq {supabase_admin=rwU/…,      =rwU/…}
--
-- An ACL entry with an empty grantee is PUBLIC. PUBLIC therefore held the
-- full set — insert, select, update, delete, truncate — on both tables, not
-- merely select as the vendor documentation describes.
--
-- Why this is not cosmetic. net.http_request_queue is the outbound request
-- queue: rows in it carry the Authorization header used to reach an Edge
-- Function, and pg_net's background worker sends whatever it finds there.
-- Insert access to that table is outbound HTTP that never passes through the
-- application, which makes R9's kill switch unenforceable by construction —
-- the switch is checked in job code, not by the worker. Delete and update
-- access would let a publish be suppressed or altered behind the state
-- machine R4 describes. The queue is also where a Page token would appear if
-- one were ever sent this way.
--
-- Not exploitable today: anon and authenticated are NOLOGIN on Supabase and
-- net is not served through the Data API. Both of those are Supabase's
-- choices, not this project's, and a grant to PUBLIC is inherited by every
-- role created later. Migration 0002 revokes across `public` and grants back
-- by name; net sat outside that discipline.
--
-- Why revoking is safe: the vendor documents net.http_get, net.http_post and
-- net.http_delete as SECURITY DEFINER functions, so a caller needs no table
-- privilege of its own — the function runs as its owner. Removing table
-- access does not break legitimate use through those functions.
--
-- service_role is deliberately left alone. It is a trusted server-side role
-- that already bypasses RLS; narrowing it belongs with the job engine, where
-- whether Edge Functions reach the network through pg_net or through fetch is
-- actually decided.
--
-- Supabase may restore these grants when the extension is upgraded. This is
-- therefore a standing check, not a one-time fix:
-- supabase/tests/verify_hosted.sql reports the live ACLs.
-- ============================================================================

do $$
begin
  if to_regnamespace('net') is null then
    -- The test harness applies migrations to a vanilla postgres:15 container
    -- where pg_net does not exist. Nothing to close.
    raise notice 'net schema absent (pg_net not installed here), skipped';
    return;
  end if;

  -- Tables and sequences: no role outside the extension owner needs direct
  -- access, for the SECURITY DEFINER reason above.
  execute 'revoke all on all tables in schema net from public, anon, authenticated';
  execute 'revoke all on all sequences in schema net from public, anon, authenticated';

  -- Functions: execute defaults to PUBLIC. Because these are SECURITY
  -- DEFINER, that default lets any role able to connect make the database
  -- issue an arbitrary outbound request. Revoke it, then grant it back by
  -- name. postgres matters because pg_cron jobs run as postgres;
  -- supabase_functions_admin drives Supabase's own webhook machinery and
  -- would otherwise lose access it had only through PUBLIC.
  execute 'revoke all on all functions in schema net from public, anon, authenticated';
  execute 'grant execute on all functions in schema net to postgres';
  if exists (select 1 from pg_roles where rolname = 'supabase_functions_admin') then
    execute 'grant execute on all functions in schema net to supabase_functions_admin';
  end if;

  -- Schema usage last: postgres, supabase_functions_admin, service_role and
  -- the owner all hold it explicitly, so only the inherited paths are closed.
  execute 'revoke usage on schema net from public, anon, authenticated';

  raise notice 'net schema closed to public, anon, authenticated';
end $$;
