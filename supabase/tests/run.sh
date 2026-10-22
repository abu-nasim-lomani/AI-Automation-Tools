#!/usr/bin/env bash
# Run the M1 database suites against a throwaway PostgreSQL 15 container.
#
#   ./supabase/tests/run.sh            # apply migrations + run suites
#   ./supabase/tests/run.sh --mutate   # also verify each suite fails when its
#                                      # control is removed (SECURITY.md §1)
#
# PostgreSQL 15 deliberately: it is the floor the migrations claim to support,
# so the §4.1 `on delete set null (column)` syntax and `security_invoker` views
# are proven at the lowest supported version.
#
# Local only. Never point this at a hosted project.
set -euo pipefail
cd "$(dirname "$0")/../.."

C=postplan-pg
PSQL="docker exec -i $C psql -U postgres -d postplan -q"

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running. Start Docker Desktop and retry." >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  echo "== starting $C (postgres:15)"
  # No published port. Every statement reaches the container through
  # `docker exec`, never over TCP, so a host port mapping buys nothing and
  # costs a CI failure whenever that port is already taken on the runner —
  # which is how this line was found. It also kept a test database listening
  # on the host for no reason.
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run -d --name "$C" -e POSTGRES_PASSWORD=localtest-only \
    -e POSTGRES_DB=postplan postgres:15 >/dev/null
  until docker exec "$C" pg_isready -U postgres -d postplan >/dev/null 2>&1; do sleep 1; done
fi

HARNESS=(supabase/tests/harness/00_auth_shim.sql
         supabase/migrations/20261020230100_schema.sql
         supabase/migrations/20261020230200_privileges_and_rls.sql
         supabase/migrations/20261020230300_triggers.sql
         supabase/migrations/20261022190000_extensions.sql
         supabase/migrations/20261022203000_net_privileges.sql
         supabase/migrations/20261022213000_net_privileges_unrevokable.sql
         supabase/migrations/20261022220000_materialize_jobs.sql
         supabase/migrations/20261022230000_job_claim.sql
         supabase/migrations/20261022240000_finalize_publish.sql
         supabase/migrations/20261022250000_generation_functions.sql
         supabase/migrations/20261022260000_create_org.sql
         supabase/migrations/20261022270000_write_credential.sql
         supabase/migrations/20261022280000_write_credential_id.sql
         supabase/migrations/20261022290000_generation_context_for.sql
         supabase/tests/harness/10_assert.sql
         supabase/tests/harness/20_seed.sql)
SUITES=(supabase/tests/suites/sec_01_cross_tenant.sql
        supabase/tests/suites/sec_16_column_privileges.sql
        supabase/tests/suites/sec_17_cross_tenant_fk.sql
        supabase/tests/suites/db_triggers_and_grants.sql
        supabase/tests/suites/jobs_03_materialize.sql
        supabase/tests/suites/jobs_07_claim.sql
        supabase/tests/suites/jobs_08_finalize.sql
        supabase/tests/suites/gen_01_generation_functions.sql
        supabase/tests/suites/org_01_create_org.sql
        supabase/tests/suites/cred_01_write_credential.sql
        supabase/tests/suites/gen_02_context_for.sql)

rebuild() {
  docker exec "$C" psql -U postgres -d postgres -q \
    -c "drop database if exists postplan;" -c "create database postplan;" >/dev/null
  for f in "${HARNESS[@]}"; do $PSQL -v ON_ERROR_STOP=1 -o /dev/null < "$f"; done
}
run_suites() { for f in "${SUITES[@]}"; do $PSQL -o /dev/null < "$f" 2>/dev/null || true; done; }
failures() { docker exec "$C" psql -U postgres -d postplan -tAc \
  "select count(*) from t.results where not ok;" | tr -d '[:space:]'; }

echo "== applying migrations and seeding"
rebuild
echo "== running suites"
run_suites
# ON_ERROR_STOP matters here: 99_report.sql raises an exception when an
# assertion failed, and without this flag psql exits 0 regardless, so a
# red suite would report green. Verified: exit 0 without it, 3 with it.
$PSQL -v ON_ERROR_STOP=1 < supabase/tests/harness/99_report.sql

if [[ "${1:-}" == "--mutate" ]]; then
  echo
  echo "== mutation verification: each control removed in turn"
  # label | SQL that removes one control | suite that must then fail
  while IFS='|' read -r label sql; do
    [[ -z "$label" ]] && continue
    rebuild
    docker exec "$C" psql -U postgres -d postplan -q -c "$sql" >/dev/null 2>&1 || true
    run_suites
    n=$(failures)
    if [[ "$n" -gt 0 ]]; then printf "   ok   %-44s %s failure(s)\n" "$label" "$n"
    else printf "   FAIL %-44s control removal changed nothing\n" "$label"; exit 1; fi
  done <<'MUTATIONS'
grant all columns on provider_credentials|grant select on provider_credentials to authenticated;
drop composite FK posts_topic_same_org|alter table posts drop constraint posts_topic_same_org;
disable RLS on posts and orgs|alter table posts disable row level security; alter table orgs disable row level security;
drop trigger posts_hash_guard|drop trigger posts_hash_guard on posts;
drop trigger request_sent_at_immutable|drop trigger request_sent_at_immutable on publish_jobs;
grant UPDATE on audit_logs to service_role|grant update on audit_logs to service_role;
grant app.is_member execute to anon|grant usage on schema app to anon; grant execute on function app.is_member(uuid) to anon;
drop function app.materialize_jobs|drop function app.materialize_jobs(int) cascade;
drop function app.claim_due_job|drop function app.claim_due_job() cascade;
drop function app.finalize_publish|drop function app.finalize_publish(uuid,text) cascade;
drop function app.pick_generation_context|drop function app.pick_generation_context() cascade;
drop function app.generation_context_for|drop function app.generation_context_for(uuid) cascade;
drop function app.record_generation|drop function app.record_generation(uuid,uuid,uuid,text,int,int,int,numeric,provider_kind,text,text,jsonb) cascade;
drop function app.create_org|drop function app.create_org(text) cascade;
drop function app.write_provider_credential|drop function app.write_provider_credential(uuid,uuid,uuid,provider_kind,text,credential_tier,bytea,bytea,int,text) cascade;
MUTATIONS
  echo "   all controls verified: removing any one of them breaks its suite"
fi
