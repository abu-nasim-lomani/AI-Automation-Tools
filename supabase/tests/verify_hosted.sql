-- ============================================================================
-- verify_hosted.sql — read-only observation of the hosted development project.
--
-- Answers questions a migration log cannot: `supabase db push` does not
-- surface NOTICE output, so a guarded `create extension` that silently took
-- the skip branch is indistinguishable from one that created the extension.
--
-- Read-only by construction. The first statement makes the whole session
-- read-only at the server, so a mistake in this file cannot write; every
-- statement below is a SELECT besides.
-- ============================================================================

set default_transaction_read_only = on;

\echo ''
\echo '================ SERVER ================'
select current_setting('server_version')      as server_version,
       current_database()                     as database,
       current_setting('search_path')         as search_path;

\echo ''
\echo '================ EXTENSIONS: installed ================'
-- The question the deploy log could not answer.
select e.extname,
       n.nspname as schema,
       e.extversion
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
 where e.extname in ('pg_net','pg_cron','pgcrypto','pgjwt','uuid-ossp')
 order by e.extname;

\echo ''
\echo '================ EXTENSIONS: available but NOT installed ================'
select name, default_version
  from pg_available_extensions
 where name in ('pg_net','pg_cron','pgcrypto')
   and installed_version is null
 order by name;

\echo ''
\echo '================ MIGRATIONS RECORDED ================'
-- Reached through dynamic SQL: the table is absent on a plain PostgreSQL
-- server, and a direct reference would fail at parse time before the rest of
-- this file could run.
do $$
declare v text;
begin
  if to_regclass('supabase_migrations.schema_migrations') is null then
    raise notice 'supabase_migrations.schema_migrations absent (not a Supabase project)';
  else
    execute 'select string_agg(version, '', '' order by version)
               from supabase_migrations.schema_migrations' into v;
    raise notice 'recorded: %', coalesce(v, '(none)');
  end if;
end $$;

\echo ''
\echo '================ TENANT TABLES: RLS state (R1) ================'
select c.relname                                        as table_name,
       c.relrowsecurity                                 as rls_enabled,
       c.relforcerowsecurity                            as rls_forced,
       (select count(*) from pg_policy p where p.polrelid = c.oid) as policies
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
 order by c.relname;

\echo ''
\echo '================ CLIENT ROLE GRANTS IN public (R2) ================'
-- Any row here for anon is a finding. authenticated should hold only the
-- privileges migration 0002 grants back explicitly.
select grantee, table_name, string_agg(privilege_type, ',' order by privilege_type) as privs
  from information_schema.role_table_grants
 where table_schema = 'public'
   and grantee in ('anon','authenticated')
 group by grantee, table_name
 order by grantee, table_name;

\echo ''
\echo '================ COLUMN GRANTS ON provider_credentials (R2 / SEC-16) ================'
-- No client role may hold select on a ciphertext column.
select grantee, column_name, privilege_type
  from information_schema.column_privileges
 where table_schema = 'public'
   and table_name   = 'provider_credentials'
   and grantee in ('anon','authenticated')
 order by grantee, column_name;

\echo ''
\echo '================ net SCHEMA EXPOSURE (follow-up to PR #3) ================'
-- Supabase documents that the net schema grants USAGE to PUBLIC, which is
-- outside migration 0002's revoke over the public schema. These two queries
-- show what is actually granted, so hardening can be written against fact
-- rather than against the documentation's description.
select nspname,
       coalesce(nspacl::text, '(default: owner only)') as schema_acl
  from pg_namespace
 where nspname = 'net';

select c.relname as object, c.relacl::text as object_acl
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'net'
 order by c.relname;

\echo ''
\echo '================ cron SCHEMA (present only if pg_cron installed) ================'
select nspname,
       coalesce(nspacl::text, '(default: owner only)') as schema_acl
  from pg_namespace
 where nspname = 'cron';
