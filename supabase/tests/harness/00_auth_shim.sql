-- ============================================================================
-- 00_auth_shim.sql — local test harness only. NEVER applied to a real project.
--
-- Recreates just enough of Supabase's platform surface that the migrations and
-- the RLS suites behave as they will in production:
--   * the anon / authenticated / service_role roles
--   * service_role with BYPASSRLS, as Supabase configures it
--   * auth.users and auth.uid() reading request.jwt.claims
--   * Supabase's BROAD DEFAULT PRIVILEGES on public tables
--
-- That last item matters more than it looks. Migration 0002 begins with
-- `revoke all on all tables in schema public from anon, authenticated`. If this
-- harness did not first grant those defaults, the revoke would be a no-op and
-- SEC-16 would pass trivially while proving nothing. Granting them here makes
-- the revoke do real work, exactly as it must against a real project.
-- ============================================================================

-- ── Roles ───────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    -- BYPASSRLS mirrors Supabase: the service role ignores policies but NOT
    -- table or column privileges. That distinction is what makes the
    -- audit_logs hardening and the SEC-17 constraint tests meaningful.
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;

-- ── auth schema ─────────────────────────────────────────────────────────────
create schema if not exists auth;

create table if not exists auth.users (
  id    uuid primary key default gen_random_uuid(),
  email text unique
);

-- Supabase's auth.uid() reads the `sub` claim of the request JWT. Tests set it
-- with:  set local request.jwt.claims = '{"sub":"<uuid>"}';
create or replace function auth.uid()
returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant select on auth.users to authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;

-- ── Supabase's broad default privileges (deliberate — see header) ───────────
alter default privileges for role postgres in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on functions to anon, authenticated, service_role;
