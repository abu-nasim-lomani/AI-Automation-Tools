-- ============================================================================
-- ORG-1 — app.create_org() (docs/DATABASE.md §6.1)
--
-- A signed-in user with no profile row makes a workspace; the function builds
-- the whole starter set in one transaction and the result is RLS-isolated.
-- ============================================================================

-- A fresh auth user with no profile and no membership yet.
do $$ begin
  insert into auth.users (id, email)
  values ('e1000000-0000-4000-8000-00000000000a', 'owner@example.test');
end $$;

-- Call it exactly as the browser will: as authenticated, with that user's JWT.
-- The new org id is captured in a session setting (not a temp table, which the
-- authenticated role could not write to), defaulting to empty so that if the
-- function is removed the capture stays empty and the assertions FAIL rather
-- than error — which is what lets the mutation run detect it.
set role authenticated;
set request.jwt.claims = '{"sub":"e1000000-0000-4000-8000-00000000000a"}';
do $$
declare v uuid;
begin
  perform set_config('test.new_org', '', false);
  v := app.create_org('My Workspace');
  perform set_config('test.new_org', v::text, false);
exception when others then null;
end $$;
reset request.jwt.claims;
reset role;

-- Verify the starter set (as superuser, so RLS does not hide it).
select t.expect('ORG-1','create_org returns an org owned by the caller',
  (select count(*) from orgs o where o.id = nullif(current_setting('test.new_org',true),'')::uuid
     and o.created_by = 'e1000000-0000-4000-8000-00000000000a') = 1,
  'org not created or wrong owner');

select t.expect('ORG-1','the caller is made an owner member',
  (select count(*) from memberships m where m.org_id = nullif(current_setting('test.new_org',true),'')::uuid
     and m.user_id = 'e1000000-0000-4000-8000-00000000000a' and m.role = 'owner') = 1,
  'owner membership missing');

select t.expect('ORG-1','a profile row is ensured for the caller',
  (select count(*) from profiles where id = 'e1000000-0000-4000-8000-00000000000a') = 1,
  'profile not created');

select t.expect('ORG-1','org_settings, a default voice and a default slot are created',
  (select count(*) from org_settings s where s.org_id = nullif(current_setting('test.new_org',true),'')::uuid) = 1
  and (select count(*) from brand_voices b where b.org_id = nullif(current_setting('test.new_org',true),'')::uuid and b.is_default) = 1
  and (select count(*) from schedule_slots sl where sl.org_id = nullif(current_setting('test.new_org',true),'')::uuid) = 1,
  'starter set incomplete');

select t.expect('ORG-1','an org.created audit row is written',
  (select count(*) from audit_logs a where a.org_id = nullif(current_setting('test.new_org',true),'')::uuid
     and a.action = 'org.created'
       and a.actor = 'e1000000-0000-4000-8000-00000000000a') = 1,
  'audit row missing');

-- RLS isolation: a different authenticated user cannot see the new org.
set role authenticated;
set request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002"}';
select t.expect_count('ORG-1','another user cannot see the new org',
  $$select 1 from orgs where id = nullif(current_setting('test.new_org',true),'')::uuid$$, 0);
reset request.jwt.claims;
reset role;

-- Guard rails.
select t.expect_denied('ORG-1','an empty name is refused', $$
  do $x$ begin perform set_config('request.jwt.claims','{"sub":"e1000000-0000-4000-8000-00000000000a"}', true);
    perform app.create_org('   '); end $x$ $$);

-- Unauthenticated: auth.uid() is null, so it must refuse.
set role authenticated;
reset request.jwt.claims;
select t.expect_denied('ORG-1','an unauthenticated call is refused',
  $$select app.create_org('No JWT')$$);
reset role;

-- anon may not execute it at all.
set role anon;
select t.expect_denied('ORG-1','anon cannot create an org',
  $$select app.create_org('anon org')$$);
reset role;
