#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v docker >/dev/null 2>&1 || { printf 'SKIP: docker is required\n'; exit 0; }
docker info >/dev/null 2>&1 || { printf 'SKIP: Docker daemon is unavailable\n'; exit 0; }

container="daiana-manual-mixed-state-pg15-$$"
work_dir="$(mktemp -d)"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; rm -rf "$work_dir"; }
trap cleanup EXIT INT TERM
docker run --rm -d --name "$container" -e POSTGRES_PASSWORD=test-password postgres:15-alpine >/dev/null
for _ in $(seq 1 30); do docker exec "$container" pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec "$container" pg_isready -U postgres >/dev/null 2>&1 || { printf 'FAIL: PostgreSQL 15 did not become ready\n' >&2; exit 1; }

# Structural-only fixture for the audited mixed manual state. It deliberately
# has no tenant, Studio, history, or migration-ledger data.
docker exec -i -e PGPASSWORD=test-password "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA private AUTHORIZATION postgres;
CREATE SCHEMA daianastudio;
CREATE SCHEMA daianawebui;
CREATE TABLE public.history (id bigint PRIMARY KEY, message text NOT NULL);
CREATE TABLE public.tenant_studio_organization_mappings (id integer PRIMARY KEY);
CREATE TABLE public.tenant_studio_workspace_mappings (id integer PRIMARY KEY);
CREATE TABLE public.tenant_message_quota_periods (id integer PRIMARY KEY);
CREATE TABLE public.tenant_message_quota_reservations (id integer PRIMARY KEY);
CREATE FUNCTION private.provision_known_studio_mapping() RETURNS text LANGUAGE sql AS $$ SELECT 'synthetic' $$;
SQL

printf 'SELECT 1;\n' > "$work_dir/20260901000000_validated_baseline.sql"
printf 'CREATE TABLE public.manual_mixed_state_ddl(id integer);\n' > "$work_dir/20260902000000_manual_mixed_state_ddl.sql"
cd "$ROOT_DIR"
log() { printf '===> %s\n' "$*" >&2; }
die() { printf 'FAIL: %s\n' "$*" >&2; return 1; }
docker_cmd() { command docker "$@"; }
# shellcheck disable=SC1091
source utils/daiana-migrations.sh

for profile in standard legacy-daianastudio; do
  if error="$(POSTGRES_PASSWORD=test-password POSTGRES_DB=postgres DAIANA_DB_CONTAINER="$container" DAIANA_MIGRATIONS_DIR="$work_dir" DAIANA_MIGRATION_PROFILE="$profile" run_daiana_migrations 2>&1)"; then
    printf 'FAIL: %s profile accepted the mixed manual state\n' "$profile" >&2
    exit 1
  fi
  [[ "$error" == *'manual-state interlock'*"refusing $profile before DDL"*'do not run either profile'* ]] || {
    printf 'FAIL: %s profile error was unclear: %s\n' "$profile" "$error" >&2
    exit 1
  }
done

result="$(docker exec -e PGPASSWORD=test-password "$container" psql -U postgres -d postgres -Atqc "
SELECT to_regclass('public.manual_mixed_state_ddl') IS NULL;
SELECT to_regclass('private.daiana_installer_schema_migrations') IS NULL;
SELECT to_regclass('private.daiana_legacy_daianastudio_schema_migrations') IS NULL;")"
[ "$(printf '%s\n' "$result" | grep -c '^t$')" -eq 3 ] || {
  printf 'FAIL: mixed manual state changed before interlock: %s\n' "$result" >&2
  exit 1
}

baseline_checksum="$(daiana_migration_sha256 "$work_dir/20260901000000_validated_baseline.sql")"
for profile in standard legacy-daianastudio; do
  case "$profile" in
    standard) ledger='private.daiana_installer_schema_migrations' ;;
    legacy-daianastudio) ledger='private.daiana_legacy_daianastudio_schema_migrations' ;;
  esac
  docker exec -e PGPASSWORD=test-password "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    CREATE TABLE $ledger (version text PRIMARY KEY, name text NOT NULL, checksum character(64) NOT NULL, applied_at timestamptz NOT NULL DEFAULT now(), installer_version text NOT NULL);
    INSERT INTO $ledger (version, name, checksum, installer_version) VALUES ('20260901000000', 'validated_baseline', '$baseline_checksum', 'test');" >/dev/null
  POSTGRES_PASSWORD=test-password POSTGRES_DB=postgres DAIANA_DB_CONTAINER="$container" DAIANA_MIGRATIONS_DIR="$work_dir" DAIANA_MIGRATION_PROFILE="$profile" run_daiana_migrations
  docker exec -e PGPASSWORD=test-password "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc "SELECT to_regclass('public.manual_mixed_state_ddl') IS NOT NULL;" | grep -qx t || {
    printf 'FAIL: %s profile blocked a validated same-profile ledger state\n' "$profile" >&2
    exit 1
  }
  docker exec -e PGPASSWORD=test-password "$container" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "DROP TABLE public.manual_mixed_state_ddl; DROP TABLE $ledger;" >/dev/null
done
printf 'PASS: PostgreSQL 15 mixed manual state rejects both profiles before DDL\n'
