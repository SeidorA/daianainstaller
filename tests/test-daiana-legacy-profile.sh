#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
cd "$ROOT_DIR"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
log() { LOG_OUTPUT="${LOG_OUTPUT}${*}\n"; }
die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

mkdir -p "$TMP_DIR/migrations"
printf 'SELECT 1;\n' > "$TMP_DIR/migrations/20260717120000_add_shared_message_quota.sql"
printf 'SELECT 4;\n' > "$TMP_DIR/migrations/20260805120000_backfill_tenant_secrets.sql"
printf 'SELECT 2;\n' > "$TMP_DIR/migrations/20260812100000_add_studio_mapping_catalog.sql"
printf 'SELECT 3;\n' > "$TMP_DIR/migrations/20260814150000_support_manual_studio_schema.sql"
printf 'SELECT 5;\n' > "$TMP_DIR/migrations/20260824160000_harden_replay_quota_rpc_acl.sql"

export POSTGRES_PASSWORD=test-password POSTGRES_DB=postgres
export DAIANA_MIGRATIONS_DIR="$TMP_DIR/migrations"
CAPTURED_SQL="$TMP_DIR/captured.sql"
LOG_OUTPUT=""
docker_cmd() { command cat > "$CAPTURED_SQL"; }
# shellcheck disable=SC1091
source "$ROOT_DIR/utils/daiana-migrations.sh"

DAIANA_MIGRATION_PROFILE=standard run_daiana_migrations
standard_sql="$(command cat "$CAPTURED_SQL")"
[[ "$standard_sql" == *'20260812100000_add_studio_mapping_catalog.sql'* ]] || fail "standard profile omitted a canonical migration"
[[ "$standard_sql" == *'SELECT 4;'* ]] || fail "standard profile omitted tenant secret backfill"
[[ "$standard_sql" == *'private.daiana_installer_schema_migrations'* ]] || fail "standard ledger changed"
[[ "$standard_sql" == *'private.daiana_legacy_daianastudio_schema_migrations'*'refusing standard before DDL'* ]] || fail "standard profile interlock contract is missing"

DAIANA_MIGRATION_PROFILE=legacy-daianastudio run_daiana_migrations
legacy_sql="$(command cat "$CAPTURED_SQL")"
[[ "$legacy_sql" != *'SELECT 2;'* ]] || fail "legacy profile included static studio catalog migration"
[[ "$legacy_sql" != *'SELECT 4;'* ]] || fail "legacy profile included tenant secret backfill"
[[ "$legacy_sql" == *'SELECT 1;'* && "$legacy_sql" == *'SELECT 3;'* && "$legacy_sql" == *'SELECT 5;'* ]] || fail "legacy profile omitted required quota, catalog, or ACL correction migration"
[[ "$legacy_sql" == *'private.daiana_legacy_daianastudio_schema_migrations'* ]] || fail "legacy ledger is not isolated"
[[ "$legacy_sql" == *'private.daiana_installer_schema_migrations'*'refusing legacy-daianastudio before DDL'* ]] || fail "legacy profile interlock contract is missing"
[[ "$legacy_sql" == *'daiana_manual_mixed_footprint'*'do not run either profile'* ]] || fail "manual mixed-state interlock contract is missing"
[[ "$legacy_sql" != *'ALTER SCHEMA daianastudio RENAME'* ]] || fail "legacy profile renamed the Studio schema"
printf 'PASS: standard and legacy profiles have isolated, checksum-safe migration contracts\n'
