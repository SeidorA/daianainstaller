#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/docker" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x "$TMP_DIR/docker"
PATH="$TMP_DIR:$PATH"

export POSTGRES_PASSWORD="test-password"
export POSTGRES_DB="postgres"
LOG_OUTPUT=""
MOCK_SCENARIO="ready"

log() {
  LOG_OUTPUT="${LOG_OUTPUT}===> $*\n"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

sleep() { :; }

docker_cmd() {
  local query=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-Atqc" ]; then
      shift
      query="$1"
      break
    fi
    shift
  done

  case "$MOCK_SCENARIO:$query" in
    *to_regclass*)
      case "$MOCK_SCENARIO" in
        missing) printf 'auth.schema_migrations' ;;
        *) printf '' ;;
      esac
      ;;
    *"SELECT EXISTS"*)
      case "$MOCK_SCENARIO" in
        ready) printf 't' ;;
        latest_error) printf 'permission denied' >&2; return 1 ;;
        *) printf 'f' ;;
      esac
      ;;
    *"SELECT count"*)
      printf '68'
      ;;
    *)
      printf 'unexpected query: %s' "$query" >&2
      return 1
      ;;
  esac
}

# Load only the migration guard helpers from the installer. Sourcing the whole
# installer would execute the install workflow.
awk '/^psql_with_password\(\)/,/^run_psql_file\(\)/ { if ($0 !~ /^run_psql_file\(\)/) print }' "$ROOT_DIR/install-daiana.sh" >"$TMP_DIR/auth-guard.sh"
# shellcheck source=/dev/null
source "$TMP_DIR/auth-guard.sh"

assert_success() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s\n' "$name" >&2
    exit 1
  fi
}

assert_failure() {
  local name="$1"
  shift
  if "$@"; then
    printf 'FAIL: %s\n' "$name" >&2
    exit 1
  else
    printf 'PASS: %s\n' "$name"
  fi
}

MOCK_SCENARIO="ready"
LOG_OUTPUT=""
assert_success "auth guard passes when latest migration is present" wait_for_supabase_auth_migrations 1 0
[[ "$LOG_OUTPUT" == *"latest=20260302000000"* ]]

MOCK_SCENARIO="not_ready"
LOG_OUTPUT=""
assert_failure "auth guard times out when latest migration is absent" wait_for_supabase_auth_migrations 1 0
[[ "$LOG_OUTPUT" == *"waiting for migration 20260302000000"* ]]

MOCK_SCENARIO="missing"
LOG_OUTPUT=""
assert_failure "auth guard reports missing required auth objects" wait_for_supabase_auth_migrations 1 0
[[ "$LOG_OUTPUT" == *"Missing Auth objects: auth.schema_migrations"* ]]

MOCK_SCENARIO="latest_error"
LOG_OUTPUT=""
assert_failure "auth guard reports latest migration query errors" wait_for_supabase_auth_migrations 1 0
[[ "$LOG_OUTPUT" == *"Auth latest-migration query failed: permission denied"* ]]

truncate_query="$(schema_tables_for_truncate_query auth)"
[[ "$truncate_query" == *"tablename <> 'schema_migrations'"* ]]
printf 'PASS: auth schema_migrations is excluded from seed truncation\n'
