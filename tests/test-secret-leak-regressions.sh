#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Secrets must cross Docker/curl boundaries through stdin or a mode-600 config,
# never through a process argument that can be read from ps/proc diagnostics.
if grep -RInE '(^|[[:space:]])-e[[:space:]]+PGPASSWORD=|\$\{TOKEN:\+-H|Bearer[[:space:]]+\$NPM_API_TOKEN' \
  "$ROOT_DIR/utils" >/dev/null; then
  printf 'Secret-bearing Docker/curl argv pattern detected in utils\n' >&2
  exit 1
fi

grep -q 'chmod 600 "\$tmp"' "$ROOT_DIR/utils/npm_ssl_bootstrap.sh"
grep -q 'header = "Authorization: Bearer %s"' "$ROOT_DIR/utils/npm_ssl_bootstrap.sh"
grep -q 'rm -f "\$NPM_AUTH_CONFIG_FILE"' "$ROOT_DIR/utils/npm_ssl_bootstrap.sh"
grep -q 'IFS= read -r PGPASSWORD' "$ROOT_DIR/utils/daiana-migrations.sh"
grep -q 'IFS= read -r PGPASSWORD' "$ROOT_DIR/utils/private-chat-harness.sh"
grep -q 'IFS= read -r PGPASSWORD' "$ROOT_DIR/install-daiana.sh"
grep -q 'IFS= read -r PGPASSWORD' "$ROOT_DIR/utils/upgrade-pg17.sh"
grep -q 'TOKEN="\$(login)"' "$ROOT_DIR/utils/npm_ssl_bootstrap.sh"
grep -q 'set +x' "$ROOT_DIR/apply-certs.sh"
grep -q 'set +x' "$ROOT_DIR/install-daiana.sh"
grep -q 'migration_xtrace_was_enabled' "$ROOT_DIR/utils/daiana-migrations.sh"
grep -q 'xtrace_was_enabled' "$ROOT_DIR/utils/private-chat-harness.sh"
grep -q 'password_xtrace_was_enabled' "$ROOT_DIR/utils/upgrade-pg17.sh"
grep -q 'portainer_request_json_file' "$ROOT_DIR/install-daiana.sh"
grep -q -- '--rawfile p' "$ROOT_DIR/install-daiana.sh"
grep -q 'failed (HTTP \$status)' "$ROOT_DIR/install-daiana.sh"
if grep -q 'Authorization: Bearer \$PORTAINER_TOKEN' "$ROOT_DIR/install-daiana.sh"; then
  printf 'Portainer token remains in curl argv/header construction\n' >&2
  exit 1
fi
grep -q 'value_file' "$ROOT_DIR/install-daiana.sh"
grep -q 'value_file' "$ROOT_DIR/apply-certs.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
awk '/^docker_login_private_registry\(\)/,/^}/ { print } /^prepull_daiana_images\(\)/,/^\)/ { print }' \
  "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/prepull-functions.sh"
cat > "$TMP_DIR/prepull-xtrace.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1"

LOG_FILE="$2"
TRACE_OUT="${TRACE_OUT:?}"
TRACE_ERR="${TRACE_ERR:?}"
APP_DEPLOY_COMPOSE_FILES=(fixture-compose.yml)
COMPOSE_CMD=(fixture_compose)

log() { :; }
docker_cmd() {
  printf 'docker %s\n' "$*" >> "$LOG_FILE"
  cat >/dev/null
}
fixture_compose() {
  printf 'pull %s\n' "$*" >> "$LOG_FILE"
  return "${COMPOSE_STATUS:-0}"
}

# This harness verifies the protected production call pattern: callers must
# disable xtrace before expanding credential-bearing arguments and invoking
# prepull_daiana_images.  It cannot, and does not claim to, hide arguments
# already emitted by a caller's xtrace before function entry.
run_protected_explicit_pull() {
  local status=0
  local caller_xtrace_was_enabled=0
  case "$-" in *x*) caller_xtrace_was_enabled=1; set +x ;; esac
  if prepull_daiana_images "$EXPLICIT_USERNAME" "$EXPLICIT_PAT"; then
    status=0
  else
    status=$?
  fi
  if (( caller_xtrace_was_enabled )); then set -x; fi
  return "$status"
}

# Existing default-env coverage: credentials are expanded from the environment
# only after prepull_daiana_images has disabled xtrace.
set -x
prepull_daiana_images
case "$-" in *x*) ;; *) exit 1 ;; esac
set +x

grep -q 'docker login docker.io --username prepull-unique-user-sentinel --password-stdin' "$LOG_FILE"
grep -q 'pull -f fixture-compose.yml pull' "$LOG_FILE"

# Explicit credentials with the caller initially not tracing.  Keep the
# sentinel checks outside xtrace so the assertions do not mention secrets in
# their own trace.
EXPLICIT_USERNAME='prepull-explicit-user-sentinel'
EXPLICIT_PAT='prepull-explicit-pat-sentinel'
COMPOSE_STATUS=0
if prepull_daiana_images "$EXPLICIT_USERNAME" "$EXPLICIT_PAT"; then
  explicit_status=0
else
  explicit_status=$?
fi
[ "$explicit_status" -eq 0 ]
case "$-" in *x*) exit 1 ;; esac
grep -q 'docker login docker.io --username prepull-explicit-user-sentinel --password-stdin' "$LOG_FILE"

# Explicit credentials with the caller initially tracing.  The wrapper mirrors
# the production callers, which suppress xtrace around the protected call and
# restore the caller state afterward.
set -x
if run_protected_explicit_pull; then
  protected_status=0
else
  protected_status=$?
fi
case "$-" in *x*) ;; *) exit 1 ;; esac
set +x
[ "$protected_status" -eq 0 ]

# A mocked compose failure must cross the function's subshell boundary
# unchanged, while the non-secret pull arguments remain intact.
COMPOSE_STATUS=37
if run_protected_explicit_pull; then
  failure_status=0
else
  failure_status=$?
fi
[ "$failure_status" -eq 37 ]
grep -q 'pull -f fixture-compose.yml pull' "$LOG_FILE"

# Do not let the xtrace assertions themselves create false positives.
if grep -q 'prepull-unique-user-sentinel\|prepull-unique-pat-sentinel\|prepull-explicit-user-sentinel\|prepull-explicit-pat-sentinel' \
  "$TRACE_OUT" "$TRACE_ERR"; then
  printf 'prepull_daiana_images leaked credentials under bash -x\n' >&2
  exit 1
fi
EOF
if ! DAIANA_REGISTRY_USERNAME='prepull-unique-user-sentinel' \
  DAIANA_REGISTRY_PAT='prepull-unique-pat-sentinel' \
  TRACE_OUT="$TMP_DIR/prepull.out" TRACE_ERR="$TMP_DIR/prepull.err" \
  bash -x "$TMP_DIR/prepull-xtrace.sh" "$TMP_DIR/prepull-functions.sh" "$TMP_DIR/prepull.log" \
  >"$TMP_DIR/prepull.out" 2>"$TMP_DIR/prepull.err"; then
  printf 'Direct prepull_daiana_images xtrace regression failed\n' >&2
  exit 1
fi
if grep -q 'prepull-unique-user-sentinel\|prepull-unique-pat-sentinel' \
  "$TMP_DIR/prepull.out" "$TMP_DIR/prepull.err"; then
  printf 'prepull_daiana_images leaked credentials under bash -x\n' >&2
  exit 1
fi

printf 'Secret argv regression scans passed\n'
