-- ============================================================================
-- 10_assert.sql — minimal assertion harness. Local test use only.
--
-- Records every result rather than aborting on the first failure, so one run
-- reports the whole picture. 99_report.sql exits non-zero if anything failed.
-- ============================================================================

create schema if not exists t;

drop table if exists t.results;
create table t.results (
  id     serial primary key,
  suite  text not null,
  name   text not null,
  ok     boolean not null,
  detail text
);
grant all on t.results to anon, authenticated, service_role;
grant all on sequence t.results_id_seq to anon, authenticated, service_role;
grant usage on schema t to anon, authenticated, service_role;

-- A statement that MUST be refused (privilege error, RLS violation, constraint,
-- or trigger). Succeeding is the failure.
create or replace function t.expect_denied(p_suite text, p_name text, p_sql text)
returns void language plpgsql as $$
begin
  execute p_sql;
  insert into t.results(suite, name, ok, detail)
  values (p_suite, p_name, false, 'statement SUCCEEDED but must be denied');
exception when others then
  insert into t.results(suite, name, ok, detail)
  values (p_suite, p_name, true, sqlstate || ': ' || left(sqlerrm, 90));
end $$;

-- A statement that must succeed.
create or replace function t.expect_ok(p_suite text, p_name text, p_sql text)
returns void language plpgsql as $$
begin
  execute p_sql;
  insert into t.results(suite, name, ok, detail) values (p_suite, p_name, true, null);
exception when others then
  insert into t.results(suite, name, ok, detail)
  values (p_suite, p_name, false, 'unexpectedly denied: ' || sqlstate || ': ' || left(sqlerrm, 90));
end $$;

-- A query that must return exactly p_expected rows. Used for RLS visibility:
-- cross-tenant SELECT is not an error, it simply returns nothing.
create or replace function t.expect_count(p_suite text, p_name text, p_sql text, p_expected bigint)
returns void language plpgsql as $$
declare n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') s' into n;
  insert into t.results(suite, name, ok, detail)
  values (p_suite, p_name, n = p_expected,
          case when n = p_expected then null
               else 'expected ' || p_expected || ' rows, got ' || n end);
exception when others then
  -- A privilege error here is also an acceptable denial for a 0-row expectation.
  insert into t.results(suite, name, ok, detail)
  values (p_suite, p_name, p_expected = 0, 'denied: ' || sqlstate || ': ' || left(sqlerrm, 70));
end $$;

-- DML that must affect zero rows (RLS filtered it away) or be refused outright.
create or replace function t.expect_zero_affected(p_suite text, p_name text, p_sql text)
returns void language plpgsql as $$
declare n bigint;
begin
  execute p_sql;
  get diagnostics n = row_count;
  insert into t.results(suite, name, ok, detail)
  values (p_suite, p_name, n = 0,
          case when n = 0 then null else 'affected ' || n || ' cross-tenant rows' end);
exception when others then
  insert into t.results(suite, name, ok, detail)
  values (p_suite, p_name, true, 'denied: ' || sqlstate || ': ' || left(sqlerrm, 70));
end $$;

-- A free-form boolean check with a computed value.
create or replace function t.expect(p_suite text, p_name text, p_ok boolean, p_detail text default null)
returns void language plpgsql as $$
begin
  insert into t.results(suite, name, ok, detail) values (p_suite, p_name, coalesce(p_ok,false), p_detail);
end $$;

grant execute on all functions in schema t to anon, authenticated, service_role;
