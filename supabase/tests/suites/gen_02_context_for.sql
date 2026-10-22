-- ============================================================================
-- GEN-2 — app.generation_context_for() (on-demand, one org, no gates)
-- ============================================================================

-- Give org A (which already has a seeded credential and topic) a usable setup.
do $$ begin
  update provider_credentials set status = 'valid'
   where org_id = 'aa000000-0000-4000-8000-00000000000a';
end $$;

create temp table ctx2(j jsonb);
do $$ begin
  insert into ctx2 select app.generation_context_for('aa000000-0000-4000-8000-00000000000a');
exception when others then insert into ctx2 values (null);
end $$;

select t.expect('GEN-2','context_for returns voice, topic and credentials for the org',
  (select j #>> '{voice,id}' from ctx2) is not null
  and (select j #>> '{topic,id}' from ctx2) is not null
  and (select jsonb_array_length(j -> 'credentials') from ctx2) >= 1,
  'context incomplete');

select t.expect('GEN-2','context_for reports kill_switch for R9',
  (select (j -> 'kill_switch')::text from ctx2) in ('true','false'),
  'kill_switch missing');

select t.expect('GEN-2','a non-existent org yields null',
  (select app.generation_context_for('00000000-0000-4000-8000-0000000000ff')) is null,
  'an unknown org should yield null');

set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_denied('GEN-2','authenticated cannot call context_for',
  $$select app.generation_context_for('aa000000-0000-4000-8000-00000000000a')$$);
reset request.jwt.claims;
reset role;
