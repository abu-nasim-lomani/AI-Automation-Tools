-- ============================================================================
-- CRED-1 — app.write_provider_credential() (docs/DATABASE.md §6.1, §6.2)
--
-- Uses org B (Bob is its owner, and it has no seeded credential) so the first
-- write becomes the default. Ciphertext/iv are obviously fake bytes — the
-- encryption happens in the Edge Function, not here.
-- ============================================================================

create temp table cred(id uuid);
do $$
declare v uuid;
begin
  v := app.write_provider_credential(
    'b0000000-0000-4000-8000-000000000002',          -- actor: Bob, owner of org B
    'bb000000-0000-4000-8000-00000000000b',          -- org B
    'gemini', 'gemini-flash-latest', 'unpaid',
    '\xcafebabe'::bytea, '\x000102030405060708090a0b'::bytea, 1, 'AIza…beef');
  insert into cred values (v);
exception when others then null;
end $$;

select t.expect('CRED-1','a credential is stored, unvalidated, and defaulted',
  (select count(*) from cred c join provider_credentials pc on pc.id = c.id
     where pc.org_id = 'bb000000-0000-4000-8000-00000000000b'
       and pc.status = 'unvalidated'
       and pc.is_default = true
       and pc.masked_hint = 'AIza…beef') = 1,
  'credential not stored correctly');

select t.expect('CRED-1','the created_by is the actor',
  (select count(*) from cred c join provider_credentials pc on pc.id = c.id
     where pc.created_by = 'b0000000-0000-4000-8000-000000000002') = 1,
  'created_by wrong');

select t.expect('CRED-1','a credential.written audit row is recorded',
  (select count(*) from audit_logs
     where org_id = 'bb000000-0000-4000-8000-00000000000b'
       and action = 'credential.written') = 1,
  'audit row missing');

-- A non-owner actor is refused, even with the right org.
select t.expect_denied('CRED-1','a non-owner actor is refused',
  $$select app.write_provider_credential(
      'c0000000-0000-4000-8000-000000000003',        -- Carol: member of org A, not owner of B
      'bb000000-0000-4000-8000-00000000000b',
      'gemini','m','unpaid','\x01'::bytea,'\x000102030405060708090a0b'::bytea,1,'x')$$);

-- A bad IV length is refused by the column constraint.
select t.expect_denied('CRED-1','a wrong-length iv is refused',
  $$select app.write_provider_credential(
      'b0000000-0000-4000-8000-000000000002',
      'bb000000-0000-4000-8000-00000000000b',
      'gemini','m','unpaid','\x01'::bytea,'\x0001'::bytea,1,'x')$$);

-- Authorization: only the service role may call it.
set role authenticated;
set request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002"}';
select t.expect_denied('CRED-1','authenticated cannot write a credential',
  $$select app.write_provider_credential(
      'b0000000-0000-4000-8000-000000000002',
      'bb000000-0000-4000-8000-00000000000b',
      'gemini','m','unpaid','\x01'::bytea,'\x000102030405060708090a0b'::bytea,1,'x')$$);
reset request.jwt.claims;
reset role;
