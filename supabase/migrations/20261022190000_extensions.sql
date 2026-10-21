-- ============================================================================
-- 20261022190000_extensions.sql — pg_net and pg_cron.
--
-- Prerequisites for the job engine: pg_cron is the work clock and pg_net is
-- how a cron job reaches an Edge Function.
--
-- Both statements are guarded on pg_available_extensions. On Supabase the
-- extensions exist and are created. The test harness applies these same
-- migrations to a vanilla postgres:15 container where neither extension is
-- compiled in, and an unguarded `create extension` would abort before a
-- single suite ran. The guard is an accommodation for that container, not a
-- licence for dev and prod to drift: anything built on these extensions must
-- assert its own preconditions rather than assume this migration created
-- them.
--
-- Verified against Supabase documentation on 2026-10-22:
--   * `create extension pg_net with schema "extensions";` — pg_net also
--     creates its own `net` schema regardless, to avoid naming conflicts.
--     Registering it in `extensions` keeps it out of `public` and satisfies
--     the Security Advisor check.
--   * `create extension pg_cron with schema pg_catalog;` followed by the two
--     grants below.
--   * pg_net is non-relocatable: `alter extension pg_net set schema ...`
--     cannot move it. A misplaced install must be dropped and re-created.
--   * Dropping either extension destroys data — all pg_cron jobs, and any
--     queued pg_net request or stored response. Neither is dropped here.
--
-- Not verified: whether both extensions are available on the Supabase free
-- plan. Neither vendor page states any plan requirement, so this stays an
-- assumption until a real apply proves it. That apply is the verification
-- docs/DATABASE.md §10 asks for.
-- ============================================================================

create schema if not exists extensions;

-- CREATE EXTENSION is a utility statement, so plpgsql reaches it through
-- EXECUTE rather than running it directly.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    execute 'create extension if not exists pg_net with schema extensions';
    raise notice 'pg_net: created (or already present)';
  else
    raise notice 'pg_net: not available on this server, skipped';
  end if;
end $$;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron with schema pg_catalog';
    execute 'grant usage on schema cron to postgres';
    execute 'grant all privileges on all tables in schema cron to postgres';
    raise notice 'pg_cron: created (or already present)';
  else
    raise notice 'pg_cron: not available on this server, skipped';
  end if;
end $$;
