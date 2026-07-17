#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$ROOT_DIR"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
log() { LOG_OUTPUT="${LOG_OUTPUT}${*}\n"; }
die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

mkdir -p "$TMP_DIR/migrations"
printf 'CREATE TABLE public.second_migration(id integer);\n' > "$TMP_DIR/migrations/20260717130000_second.sql"
printf 'CREATE TABLE public.first_migration(id integer);\n' > "$TMP_DIR/migrations/20260717120000_first.sql"
printf '#!/bin/sh\nexit 0\n' > "$TMP_DIR/docker"
chmod +x "$TMP_DIR/docker"
PATH="$TMP_DIR:$PATH"

export POSTGRES_PASSWORD=test-password
export POSTGRES_DB=postgres
export DAIANA_MIGRATIONS_DIR="$TMP_DIR/migrations"
CAPTURED_SQL="$TMP_DIR/captured.sql"
DOCKER_RESULT=0
DOCKER_CALLS=0
LOG_OUTPUT=""

docker_cmd() {
  DOCKER_CALLS=$((DOCKER_CALLS + 1))
  command cat > "$CAPTURED_SQL"
  return "$DOCKER_RESULT"
}

# shellcheck disable=SC1091
source "$ROOT_DIR/utils/daiana-migrations.sh"

run_daiana_migrations || fail "runner should emit a psql transaction"
sql="$(command cat "$CAPTURED_SQL")"
[[ "$sql" == *'BEGIN;'* ]] || fail "transaction begin missing"
[[ "$sql" == *'COMMIT;'* ]] || fail "transaction commit missing"
[[ "$sql" == *'pg_advisory_xact_lock(1480867157, 1296651378)'* ]] || fail "global advisory lock missing"
[[ "$sql" == *'daiana_installer_schema_migrations'* ]] || fail "history table missing"
[[ "$sql" == *'checksum drift for version'* ]] || fail "checksum drift guard missing"
[[ "$sql" == *'\if :daiana_exact_applied'* ]] || fail "exact checksum skip missing"
[[ "$sql" == *"INSERT INTO private.daiana_installer_schema_migrations"* ]] || fail "atomic history insert missing"
first_prefix="${sql%%CREATE TABLE public.first_migration*}"
[[ "$first_prefix" != *'CREATE TABLE public.second_migration'* ]] || fail "migrations are not lexically ordered"
pass "runner emits ordered lock/checksum/transaction contract"

DOCKER_RESULT=17
LOG_OUTPUT=""
if run_daiana_migrations; then
  fail "runner should propagate psql failure"
fi
[[ "$LOG_OUTPUT" == *'rolled back migration and history changes'* ]] || fail "failure log does not explain rollback"
pass "runner fails closed when psql fails"

FAIL_STOP_MARKER="$TMP_DIR/app-deploy-called"
if POSTGRES_PASSWORD=test-password POSTGRES_DB=postgres DAIANA_MIGRATIONS_DIR="$TMP_DIR/migrations" \
    FAIL_STOP_MARKER="$FAIL_STOP_MARKER" ROOT_DIR="$ROOT_DIR" bash -c '
      set -e
      log() { :; }
      die() { return 1; }
      docker_cmd() { command cat >/dev/null; return 23; }
      source "$ROOT_DIR/utils/daiana-migrations.sh"
      run_daiana_migrations
      : > "$FAIL_STOP_MARKER"
    '; then
  fail "migration failure should stop the lifecycle"
fi
[ ! -e "$FAIL_STOP_MARKER" ] || fail "app deployment continued after migration failure"
pass "migration failure prevents subsequent app deployment"

DOCKER_RESULT=0
DOCKER_CALLS=0
LOG_OUTPUT=""
run_daiana_migrations 1
[[ "$DOCKER_CALLS" -eq 0 ]] || fail "dry-run contacted Docker"
[[ "$LOG_OUTPUT" == *'20260717120000_first.sql'*'20260717130000_second.sql'* ]] || fail "dry-run order is unclear"
pass "dry-run is ordered and has no database side effects"

install_line="$(awk '/run_supabase_init_sql$/ { print NR; exit }' install-daiana.sh)"
migration_line="$(awk '/^run_daiana_migrations$/ { print NR; exit }' install-daiana.sh)"
deploy_line="$(awk '/^log "Deploying Daiana app stack via Portainer"/ { print NR; exit }' install-daiana.sh)"
[[ -n "$install_line" && -n "$migration_line" && -n "$deploy_line" ]] || fail "could not locate install orchestration"
[[ "$install_line" -lt "$migration_line" && "$migration_line" -lt "$deploy_line" ]] || fail "fresh install order is not seed -> migrate -> app"
[[ "$(grep -c '^run_daiana_migrations$' install-daiana.sh)" -eq 1 ]] || fail "update path does not share exactly one migration gate"
pass "fresh install and update migration gate precedes app deployment"

LIFECYCLE="$TMP_DIR/lifecycle.sh"
awk '/^log "Deploying NPM stack via Portainer"/,/^log "Waiting for NPM API"/ { if ($0 !~ /^log "Waiting for NPM API"/) print }' install-daiana.sh > "$LIFECYCLE"
UPDATE_MARKER="$TMP_DIR/update-app-stack-called"
if ACTION=update APP_STACK_NAME=daiana NPM_STACK_NAME=npm APP_STACK_ENV_JSON='[]' NPM_STACK_ENV_JSON='[]' \
    UPDATE_MARKER="$UPDATE_MARKER" LIFECYCLE="$LIFECYCLE" bash -c '
      set -e
      log() { :; }; die() { return 1; }; wait_for_supabase_ready() { return 0; }
      portainer_upsert_stack() { [ "$1" != "$APP_STACK_NAME" ] || : > "$UPDATE_MARKER"; }
      run_daiana_migrations() { return 23; }
      source "$LIFECYCLE"
    '; then
  fail "forced update migration failure should stop the lifecycle"
fi
[ ! -e "$UPDATE_MARKER" ] || fail "update replaced the existing app stack before migrations succeeded"
pass "update migration failure preserves the deployed combined app stack"

grep -q 'DAIANA_SHARED_CHAT_QUOTA_ENABLED: "true"' docker-compose.app.yml || fail "Studio quota flag missing"
# shellcheck disable=SC2016
grep -q 'SUPABASE_BASE_URL: ${SUPABASE_PUBLIC_URL}' docker-compose.app.yml || fail "Studio Supabase URL missing"
# shellcheck disable=SC2016
grep -q 'SUPABASE_SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}' docker-compose.app.yml || fail "service-role wiring missing"
# shellcheck disable=SC2016
[[ "$(grep -c 'SUPABASE_SERVICE_ROLE_KEY: ${SERVICE_ROLE_KEY}' docker-compose.app.yml)" -ge 3 ]] || fail "Next/Python/Studio service-role wiring incomplete"
pass "runtime quota configuration uses server-only credentials"

MIGRATION="volumes/db/daiana-migrations/20260717120000_add_shared_message_quota.sql"
[[ "$(grep -c '^BEGIN;$\|^COMMIT;$' "$MIGRATION")" -eq 0 ]] || fail "packaged migration owns transaction boundaries"
grep -q 'Canonical source baseline commit: 9806ee4799b95658bbded4ccd7da46877c56a51f' "$MIGRATION" || fail "canonical commit provenance missing"
grep -q 'Canonical source baseline tree: bd5949be0ae29658218245a3934955352a9c171b' "$MIGRATION" || fail "canonical tree provenance missing"
grep -q 'Canonical source content SHA-256: a39c1f4d8d2f7cfb7ff4122fd41fd8938352ec278a7a09a477dd196df871d85d' "$MIGRATION" || fail "canonical content provenance missing"
grep -q 'Approved installer adaptation is intentionally non-byte-identical' "$MIGRATION" || fail "non-byte-identical adaptation disclosure missing"
[[ "$(daiana_migration_sha256 "$MIGRATION")" = a006dd4648b127b2cd2629f1a60364d759c729c9469a2978deb754ae6837c689 ]] || fail "packaged adaptation hash is not approved"
grep -q 'REVOKE ALL ON public.tenant_message_quota_periods FROM PUBLIC, anon, authenticated, service_role' "$MIGRATION" || fail "table privileges are not hardened"
grep -q 'REVOKE ALL ON FUNCTION public.reserve_tenant_message_quota.*PUBLIC, anon, authenticated, service_role' "$MIGRATION" || fail "function privileges are not hardened"
grep -q 'REVOKE ALL ON FUNCTION public.finalize_tenant_message_quota_turn.*PUBLIC, anon, authenticated, service_role' "$MIGRATION" || fail "finalize privileges are not hardened"
grep -q 'GRANT EXECUTE ON FUNCTION public.finalize_tenant_message_quota_turn.*service_role' "$MIGRATION" || fail "finalize service-role execution is missing"
grep -q 'AND a.botpublic IS TRUE' "$MIGRATION" || fail "historical bootstrap is not public-only"
grep -q 'IF FOUND AND (v_existing."periodStartAt" <> v_start OR v_existing.status <> '\''released'\'')' "$MIGRATION" || fail "released retry reactivation is missing"
grep -q 'CREATE OR REPLACE FUNCTION public.finalize_tenant_message_quota_turn(p_request_id text, p_source text' "$MIGRATION" || fail "atomic finalize RPC is missing"
grep -q "tenant 1 / organization ca2a7ece-14c6-458c-9266-5c3d96e547f2" "$MIGRATION" || fail "fixed organization conflict guard missing"
grep -q 'cd469aed-4042-477b-b508-9de39d395056' "$MIGRATION" || fail "fixed workspace mapping missing"
grep -q "NOTIFY pgrst, 'reload schema'" "$MIGRATION" || fail "PostgREST reload missing"
pass "packaged migration has provenance, privilege hardening, mapping, and reload"
