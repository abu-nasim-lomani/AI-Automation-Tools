-- ============================================================================
-- SEC-16 — column privileges (docs/DATABASE.md §11.1, SECURITY.md T16)
--
-- Authenticated as ALICE, an OWNER of org A, operating on her OWN org's rows.
-- The point: RLS lets her see these rows, so anything denied here is denied by
-- COLUMN PRIVILEGE, which is the control under test. 14 assertions.
-- ============================================================================

set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';

-- 1–4: ciphertext columns are unreadable even to the owner of the row
select t.expect_denied('SEC-16','1. select ciphertext from provider_credentials',
  $$select ciphertext from provider_credentials$$);
select t.expect_denied('SEC-16','2. select iv, key_version from provider_credentials',
  $$select iv, key_version from provider_credentials$$);
select t.expect_denied('SEC-16','3. select token_ciphertext, token_iv from social_accounts',
  $$select token_ciphertext, token_iv from social_accounts$$);
select t.expect_denied('SEC-16','4. select * from provider_credentials',
  $$select * from provider_credentials$$);

-- 5: the safe view works and exposes no ciphertext column
select t.expect_count('SEC-16','5. select * from provider_credentials_safe succeeds',
  $$select * from provider_credentials_safe$$, 1);
select t.expect('SEC-16','5b. safe view has no ciphertext/iv column',
  not exists (
    select 1 from information_schema.columns
     where table_name = 'provider_credentials_safe'
       and column_name in ('ciphertext','iv','token_ciphertext','token_iv')),
  'view column list must omit all ciphertext columns');

-- 6: no client write path to credentials at all
select t.expect_denied('SEC-16','6a. insert provider_credentials',
  $$insert into provider_credentials (org_id, provider, model, ciphertext, iv, masked_hint, created_by)
    values ('aa000000-0000-4000-8000-00000000000a','groq','m','\x00'::bytea,
            '\x000102030405060708090a0b'::bytea,'x','a0000000-0000-4000-8000-000000000001')$$);
select t.expect_denied('SEC-16','6b. update provider_credentials',
  $$update provider_credentials set tier = 'paid'$$);
select t.expect_denied('SEC-16','6c. delete provider_credentials',
  $$delete from provider_credentials$$);

-- 7: Page connection is owner-only via RPC, never a direct write
select t.expect_denied('SEC-16','7. update social_accounts status',
  $$update social_accounts set status = 'active'$$);

-- 8–10: posts have no client insert or update (B-1)
select t.expect_denied('SEC-16','8. insert into posts',
  $$insert into posts (org_id, body, grapheme_count, codepoint_count, word_count, bangla_ratio)
    values ('aa000000-0000-4000-8000-00000000000a','নতুন',4,4,1,1.0)$$);
select t.expect_denied('SEC-16','9. update posts set body',
  $$update posts set body = 'edited' where id = 'a3000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('SEC-16','10. update posts set status/fb_post_id',
  $$update posts set status = 'published', fb_post_id = 'forged'
     where id = 'a3000000-0000-4000-8000-00000000000a'$$);

-- 11: a draft can be discarded; a published post cannot
-- Asserts the row count, not just the absence of an error: a delete matching
-- zero rows would "succeed" and prove nothing. A data-modifying CTE has to be
-- at statement top level, hence the DO block.
do $$
declare n int;
begin
  with d as (
    delete from posts where id = 'a9000000-0000-4000-8000-00000000000a' returning 1)
  select count(*) into n from d;
  perform t.expect('SEC-16','11a. delete own-org DRAFT succeeds', n = 1,
                   'expected exactly 1 deleted, got ' || n);
exception when others then
  perform t.expect('SEC-16','11a. delete own-org DRAFT succeeds', false,
                   'unexpectedly denied: ' || sqlstate || ': ' || left(sqlerrm, 80));
end $$;
select t.expect_denied('SEC-16','11b. delete own-org PUBLISHED post is refused',
  $$delete from posts where id = 'a4000000-0000-4000-8000-00000000000a'$$);

-- 12–14: org_settings — the emergency stop is open, everything else is not
select t.expect_denied('SEC-16','12. update org_settings auto_publish',
  $$update org_settings set auto_publish = true$$);
select t.expect_ok('SEC-16','13. update org_settings paused SUCCEEDS (emergency stop)',
  $$update org_settings set paused = true
     where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('SEC-16','14. update org_settings target_buffer',
  $$update org_settings set target_buffer = 50$$);

-- The emergency stop must also work for a plain MEMBER, not just an owner
-- (SECURITY.md §7.1: a stop that needs the right role fails when needed).
reset role; reset request.jwt.claims;
set role authenticated;
set request.jwt.claims = '{"sub":"c0000000-0000-4000-8000-000000000003"}';
select t.expect_ok('SEC-16','15. a plain MEMBER can set kill_switch',
  $$update org_settings set kill_switch = true
     where org_id = 'aa000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('SEC-16','16. a plain MEMBER cannot set auto_publish',
  $$update org_settings set auto_publish = true$$);

reset role;
reset request.jwt.claims;
-- restore state for later suites
update org_settings set paused = false, kill_switch = false
 where org_id = 'aa000000-0000-4000-8000-00000000000a';
