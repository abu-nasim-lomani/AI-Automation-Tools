-- ============================================================================
-- Trigger behaviour + execute grants
--   SEC-19 (audit immutability)   SEC-23 (execute grants, partial)
--   B-1 posts_hash_guard          K21 request_sent_at_immutable
--   K13 one-shot attestation cap  guard_last_owner, region/tier enforcement
--
-- SEC-22 (full role matrix) and the rest of SEC-23 need the §6.1 RPCs, which
-- were not in M1's approved scope. The portions enforced by grants are covered
-- here and in SEC-16; the RPC-gated portions are recorded as not yet testable.
-- ============================================================================

-- ── SEC-23: PostgreSQL grants EXECUTE to PUBLIC by default (F-17) ───────────
set role anon;
select t.expect_denied('SEC-23','anon cannot execute app.is_member',
  $$select app.is_member('aa000000-0000-4000-8000-00000000000a')$$);
select t.expect_denied('SEC-23','anon cannot execute app.has_role',
  $$select app.has_role('aa000000-0000-4000-8000-00000000000a','owner')$$);
select t.expect_denied('SEC-23','anon cannot execute app.live',
  $$select app.live('aa000000-0000-4000-8000-00000000000a')$$);
reset role;

set role authenticated;
set request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001"}';
select t.expect_ok('SEC-23','authenticated CAN execute app.is_member',
  $$select app.is_member('aa000000-0000-4000-8000-00000000000a')$$);
select t.expect('SEC-23','app.has_role: owner implies member',
  app.has_role('aa000000-0000-4000-8000-00000000000a','member'),
  'an owner must satisfy a member check');
reset role; reset request.jwt.claims;

set role authenticated;
set request.jwt.claims = '{"sub":"c0000000-0000-4000-8000-000000000003"}';
select t.expect('SEC-23','app.has_role: a member is NOT an owner',
  not app.has_role('aa000000-0000-4000-8000-00000000000a','owner'),
  'carol is a plain member');
reset role; reset request.jwt.claims;

-- Every SECURITY DEFINER function must pin search_path, or a caller can shadow
-- a referenced object and have it run as the owner.
select t.expect('SEC-23','all app SECURITY DEFINER functions pin search_path',
  not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.prosecdef
       and not exists (select 1 from unnest(coalesce(p.proconfig,'{}'))  c
                        where c like 'search_path=%')),
  'a SECURITY DEFINER function without search_path is a privilege-escalation path');

-- ── SEC-19: audit immutability, including TRUNCATE and the sequence ──────────
set role service_role;
select t.expect_ok('SEC-19','service_role CAN insert audit rows',
  $$insert into audit_logs (org_id, action) values
    ('aa000000-0000-4000-8000-00000000000a','test.insert')$$);
select t.expect_ok('SEC-19','service_role CAN select audit rows (B-2, deliberate)',
  $$select count(*) from audit_logs$$);
select t.expect_denied('SEC-19','service_role cannot UPDATE audit rows',
  $$update audit_logs set action = 'rewritten'$$);
select t.expect_denied('SEC-19','service_role cannot DELETE audit rows',
  $$delete from audit_logs$$);
select t.expect_denied('SEC-19','service_role cannot TRUNCATE audit_logs',
  $$truncate audit_logs$$);
select t.expect_denied('SEC-19','service_role cannot rewind the audit sequence',
  $$select setval('audit_logs_id_seq', 1)$$);
reset role;

-- ── B-1: posts_hash_guard overwrites whatever the writer supplies ───────────
set role service_role;
select t.expect_ok('B-1','insert a post with a deliberately WRONG content_hash',
  $$insert into posts (id, org_id, body, grapheme_count, codepoint_count, word_count,
                       bangla_ratio, content_hash, opening_hash)
    values ('aaaa0000-0000-4000-8000-00000000aaaa','aa000000-0000-4000-8000-00000000000a',
            'hash guard পরীক্ষা',18,18,3,0.7,'LIES','ALSO-LIES')$$);
select t.expect('B-1','the supplied content_hash was DISCARDED and recomputed',
  (select content_hash <> 'LIES' and length(content_hash) = 64
     from posts where id = 'aaaa0000-0000-4000-8000-00000000aaaa'),
  'trigger must overwrite the writer''s value with a sha256 hex digest');
select t.expect('B-1','the supplied opening_hash was DISCARDED and recomputed',
  (select opening_hash <> 'ALSO-LIES' and length(opening_hash) = 64
     from posts where id = 'aaaa0000-0000-4000-8000-00000000aaaa'),
  'opening_hash must also be derived');

-- Editing the body must move the hash with it, or duplicate prevention breaks
do $$
declare h_before text; h_after text;
begin
  select content_hash into h_before from posts
   where id = 'aaaa0000-0000-4000-8000-00000000aaaa';
  update posts set body = 'সম্পূর্ণ ভিন্ন লেখা'
   where id = 'aaaa0000-0000-4000-8000-00000000aaaa';
  select content_hash into h_after from posts
   where id = 'aaaa0000-0000-4000-8000-00000000aaaa';
  perform t.expect('B-1','editing the body changes content_hash',
                   h_before is distinct from h_after,
                   'a body edit that left the hash stale would silently defeat dedup');
end $$;

-- Whitespace- and NFC-equivalent bodies must collide
select t.expect_denied('B-1','a whitespace-equivalent body collides on content_hash',
  $$insert into posts (org_id, body, grapheme_count, codepoint_count, word_count, bangla_ratio)
    values ('aa000000-0000-4000-8000-00000000000a',
            '   সম্পূর্ণ    ভিন্ন   লেখা  ',20,20,3,0.9)$$);
reset role;

-- ── K21: request_sent_at is write-once ──────────────────────────────────────
set role service_role;
select t.expect_ok('K21','first marker write succeeds (coalesce keeps the first send)',
  $$update publish_jobs
       set request_sent_at = '2026-10-21 01:30:05+00', request_sent_attempt = 1
     where id = 'a6000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('K21','overwriting a non-null request_sent_at is refused',
  $$update publish_jobs set request_sent_at = now()
     where id = 'a6000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('K21','clearing request_sent_at is refused',
  $$update publish_jobs set request_sent_at = null
     where id = 'a6000000-0000-4000-8000-00000000000a'$$);
select t.expect_ok('K21','request_sent_attempt CAN advance (it is per-attempt)',
  $$update publish_jobs set request_sent_attempt = 2
     where id = 'a6000000-0000-4000-8000-00000000000a'$$);

-- ── K13: the attestation cap is a constraint, not a convention ──────────────
select t.expect_ok('K13','attestation_count may reach 1',
  $$update publish_jobs set attestation_count = 1
     where id = 'a6000000-0000-4000-8000-00000000000a'$$);
select t.expect_denied('K13','attestation_count cannot exceed 1 (max two requests per job)',
  $$update publish_jobs set attestation_count = 2
     where id = 'a6000000-0000-4000-8000-00000000000a'$$);
reset role;

-- ── EU/UK tier enforcement ──────────────────────────────────────────────────
set role service_role;
select t.expect_denied('EU','an unpaid credential cannot be added to an eu_uk org',
  $$with o as (
      insert into orgs (id, name, region, created_by)
      values ('ee000000-0000-4000-8000-00000000000e','Org EU','eu_uk',
              'a0000000-0000-4000-8000-000000000001') returning id)
    insert into provider_credentials (org_id, provider, model, tier, ciphertext, iv,
                                      masked_hint, created_by)
    select id,'gemini','m','unpaid','\x00'::bytea,
           '\x000102030405060708090a0b'::bytea,'x',
           'a0000000-0000-4000-8000-000000000001' from o$$);
select t.expect_denied('EU','region cannot change to eu_uk while an unpaid credential exists',
  $$update orgs set region = 'eu_uk'
     where id = 'aa000000-0000-4000-8000-00000000000a'$$);
reset role;

-- ── guard_last_owner ────────────────────────────────────────────────────────
set role service_role;
select t.expect_denied('OWNER','removing the last owner of an org is refused',
  $$delete from memberships
     where org_id = 'bb000000-0000-4000-8000-00000000000b'
       and user_id = 'b0000000-0000-4000-8000-000000000002'$$);
select t.expect_denied('OWNER','demoting the last owner is refused',
  $$update memberships set role = 'member'
     where org_id = 'bb000000-0000-4000-8000-00000000000b'
       and user_id = 'b0000000-0000-4000-8000-000000000002'$$);
select t.expect_ok('OWNER','CONTROL: removing a non-last member is allowed',
  $$delete from memberships
     where org_id = 'aa000000-0000-4000-8000-00000000000a'
       and user_id = 'c0000000-0000-4000-8000-000000000003'$$);
reset role;

-- ── credential auditing wrote a row with no secret material ─────────────────
select t.expect('AUDIT','credential changes produced audit rows',
  (select count(*) > 0 from audit_logs where action like 'provider_credentials.%'),
  'audit_credential_change must fire');
select t.expect('AUDIT','audit detail carries no ciphertext, iv or masked hint',
  not exists (
    select 1 from audit_logs
     where detail::text ~* '(ciphertext|token_iv|"iv"|masked)'),
  'audit rows must never contain secret material (R3)');
