-- ============================================================================
-- 99_report.sql — print the result table and fail the run if anything failed.
-- ============================================================================

\echo ''
\echo '================ FAILURES (empty is good) ================'
select suite, name, coalesce(detail,'') as detail
  from t.results where not ok order by id;

\echo ''
\echo '================ SUMMARY BY SUITE ================'
select suite,
       count(*)                      as total,
       count(*) filter (where ok)     as passed,
       count(*) filter (where not ok) as failed
  from t.results group by suite order by suite;

\echo ''
select count(*) || ' assertions, ' ||
       count(*) filter (where ok) || ' passed, ' ||
       count(*) filter (where not ok) || ' failed' as overall
  from t.results;

-- Non-zero exit if anything failed, so CI can gate on it.
do $$
declare n int;
begin
  select count(*) into n from t.results where not ok;
  if n > 0 then
    raise exception '% assertion(s) failed', n;
  end if;
end $$;
