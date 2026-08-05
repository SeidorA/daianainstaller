#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2329
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir "$TMP_DIR/mktemp"
export TMPDIR="$TMP_DIR/mktemp"
PORTAINER_URL=http://portainer.test
export PORTAINER_URL

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

# shellcheck source=/dev/null
awk '/^portainer_temp_cleanup\(\)/,/^ensure_network\(\)/ { if ($0 !~ /^ensure_network\(\)/) print }' \
  "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/portainer-functions.sh"
source "$TMP_DIR/portainer-functions.sh"

assert_temp_dir_empty() {
  local file
  for file in "$TMPDIR"/*; do
    [ ! -e "$file" ] || fail "Portainer temporary file remains: ${file##*/}"
  done
}

assert_mode_600() {
  local file="$1" mode
  mode="$(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file")"
  [ "$mode" = 600 ] || fail "temporary file is not mode 600: $mode"
}

curl() {
  local config="$2" content mode
  mode="$(stat -f '%Lp' "$config" 2>/dev/null || stat -c '%a' "$config")"
  [ "$mode" = 600 ] || fail "curl config is not mode 600: $mode"
  content="$(<"$config")"
  [ "${CURL_MODE:-}" = failure ] && {
    printf '{"password":"fixture-secret"}\n500\n'
    return 0
  }
  case "$content" in
    *'/api/stacks"'*|*'/api/stacks/create/'*)
      printf '{"password":"fixture-secret"}\n500\n'
      ;;
    *)
      printf '{"ok":true}\n200\n'
      ;;
  esac
}

response="$(portainer_request_json GET /api/health fixture-secret)" || fail "successful request failed"
[[ "$response" = '{"ok":true}' ]] || fail "successful response changed"
assert_temp_dir_empty
pass "request JSON success removes mode-600 temporary files"

CURL_MODE=failure
export CURL_MODE
if portainer_request_json POST /api/failure fixture-secret >"$TMP_DIR/failure.out" 2>"$TMP_DIR/failure.err"; then
  fail "HTTP failure was accepted"
fi
CURL_MODE=
! grep -q 'fixture-secret' "$TMP_DIR/failure.out" "$TMP_DIR/failure.err" \
  || fail "HTTP diagnostics exposed response secret"
grep -q 'failed (HTTP 500)' "$TMP_DIR/failure.err" || fail "HTTP diagnostic was lost"
assert_temp_dir_empty
pass "HTTP failure removes request and curl-config files with redacted diagnostics"

curl() { return 7; }
if portainer_request_json POST /api/transport fixture-secret >"$TMP_DIR/transport.out" 2>"$TMP_DIR/transport.err"; then
  fail "transport failure was accepted"
fi
! grep -q 'fixture-secret' "$TMP_DIR/transport.out" "$TMP_DIR/transport.err" \
  || fail "transport diagnostics exposed response secret"
grep -q 'failed (HTTP )' "$TMP_DIR/transport.err" || fail "transport diagnostic was lost"
assert_temp_dir_empty
pass "transport failure removes request and curl-config files with redacted diagnostics"

curl() {
  local config="$2" content data_file body
  content="$(<"$config")"
  case "$content" in
    *'/api/stacks"'*) printf '[]\n200\n' ;;
    *) printf '{"password":"fixture-secret"}\n500\n' ;;
  esac
}
render_compose() { printf 'services:\n  app:\n    image: fixture\n' > "$1"; }
portainer_stack_id() { printf ''; }
log() { :; }
PORTAINER_ENDPOINT_ID=1
export PORTAINER_ENDPOINT_ID
upsert_env="$TMP_DIR/upsert-env.json"
upsert_registry="$TMP_DIR/upsert-registry.json"
printf '%s' '[{"name":"SECRET","value":"fixture-secret"}]' > "$upsert_env"
printf '%s' '[]' > "$upsert_registry"
if portainer_upsert_stack daiana-app "$upsert_env" "$upsert_registry" docker-compose.yml \
  >"$TMP_DIR/upsert.out" 2>"$TMP_DIR/upsert.err"; then
  fail "Portainer upsert HTTP failure was accepted"
fi
! grep -q 'fixture-secret' "$TMP_DIR/upsert.out" "$TMP_DIR/upsert.err" \
  || fail "upsert diagnostics exposed secret"
grep -q 'failed (HTTP 500)' "$TMP_DIR/upsert.err" || fail "upsert diagnostic was lost"
assert_temp_dir_empty
pass "upsert failure removes stack, env, registry, body, and curl-config files"

rollback_stack="$TMP_DIR/rollback.yml"
rollback_env="$TMP_DIR/rollback-env.json"
rollback_registry="$TMP_DIR/rollback-registries.json"
printf 'services:\n  app:\n    image: rollback-fixture\n' > "$rollback_stack"
printf '%s' '[{"name":"SECRET","value":"fixture-secret"}]' > "$rollback_env"
printf '%s' '[]' > "$rollback_registry"
rollback_before_stack="$(<"$rollback_stack")"
rollback_before_env="$(<"$rollback_env")"
rollback_before_registry="$(<"$rollback_registry")"
portainer_stack_id() { printf '7'; }
if portainer_submit_stack_file daiana-app "$rollback_env" "$rollback_registry" "$rollback_stack" \
  >"$TMP_DIR/rollback.out" 2>"$TMP_DIR/rollback.err"; then
  fail "rollback submit HTTP failure was accepted"
fi
! grep -q 'fixture-secret' "$TMP_DIR/rollback.out" "$TMP_DIR/rollback.err" \
  || fail "rollback diagnostics exposed secret"
[ "$(<"$rollback_stack")" = "$rollback_before_stack" ] || fail "rollback changed caller stack input"
[ "$(<"$rollback_env")" = "$rollback_before_env" ] || fail "rollback changed caller Env input"
[ "$(<"$rollback_registry")" = "$rollback_before_registry" ] || fail "rollback changed caller registry input"
assert_temp_dir_empty
pass "rollback submit preserves caller-owned inputs"
ROLLBACK_ENV="$rollback_before_env"
ROLLBACK_REG="$rollback_before_registry"
curl() { printf '{}\n200\n'; }
portainer_rollback_stack daiana-app ROLLBACK_ENV ROLLBACK_REG "$rollback_stack" >/dev/null \
  || fail "rollback wrapper failed"
[ "$(<"$rollback_stack")" = "$rollback_before_stack" ] || fail "rollback wrapper changed compose input"
assert_temp_dir_empty
pass "rollback wrapper supplies protected Env, registry, and compose paths"

stack_file="$TMP_DIR/stack.yml"
env_file="$TMP_DIR/env.json"
registry_file="$TMP_DIR/registries.json"
curl() { printf '{"password":"fixture-secret"}\n500\n'; }
printf 'services:\n  app:\n    image: fixture\n' > "$stack_file"
printf '[{"name":"SECRET","value":"fixture-secret"}]' > "$env_file"
printf '[]' > "$registry_file"
portainer_stack_id() { printf '7'; }
if portainer_submit_stack_file daiana-app "$env_file" "$registry_file" "$stack_file" \
  >"$TMP_DIR/submit.out" 2>"$TMP_DIR/submit.err"; then
  fail "Portainer submit HTTP failure was accepted"
fi
! grep -q 'fixture-secret' "$TMP_DIR/submit.out" "$TMP_DIR/submit.err" \
  || fail "submit diagnostics exposed secret"
assert_temp_dir_empty
pass "submit failure removes its body file without deleting caller-owned inputs"

curl() { printf '{}\n200\n'; }
portainer_submit_stack_file daiana-app "$env_file" "$registry_file" "$stack_file" >/dev/null \
  || fail "successful Portainer submit failed"
assert_temp_dir_empty
pass "successful Portainer submit removes its body file"

portainer_request_form POST /form --form 'Name=fixture' >/dev/null \
  || fail "form request failed"
assert_temp_dir_empty
pass "form request cleans its mode-600 curl config"

curl() {
  local config="$2" content
  content="$(<"$config")"
  case "$content" in
    *'request = "GET"'*'/api/registries'*) printf '[]\n200\n' ;;
    *'/api/registries'*) printf '{"Id":9}\n201\n' ;;
    *) printf '{}\n200\n' ;;
  esac
}
DAIANA_REGISTRY_NAME=fixture-registry
DAIANA_REGISTRY_USERNAME=fixture-user
DAIANA_REGISTRY_PAT=fixture-secret
portainer_ensure_private_registry || fail "registry request failed"
assert_temp_dir_empty
pass "registry request path cleans protected files"

lookup_log="$TMP_DIR/lookup.log"
curl() {
  local config="$2" content
  content="$(<"$config")"
  builtin printf '%s\n' "$content" >> "$lookup_log"
   case "${LOOKUP_MODE:-404}" in
     404)
       case "$content" in
        *'request = "POST"'*)
          creation_response="${CREATION_RESPONSE:-}"
          [ -n "$creation_response" ] || creation_response='{"Id":17}'
          printf '%s\n201\n' "$creation_response"
          ;;
        *) printf '{"message":"not found"}\n404\n' ;;
      esac
      ;;
    500) printf '{"message":"server error"}\n500\n' ;;
    parse) printf 'not-json\n200\n' ;;
    unsafe) printf '[{"Name":"fixture-registry","Id":"../unsafe"}]\n200\n' ;;
    transport) return 7 ;;
  esac
}
if [ -n "$(portainer_registry_id fixture-registry)" ]; then
  fail "registry HTTP 404 was not treated as confirmed not-found"
fi
for lookup_mode in 500 transport parse unsafe; do
  LOOKUP_MODE="$lookup_mode"
  if portainer_registry_id fixture-registry >/dev/null 2>"$TMP_DIR/lookup-$lookup_mode.err"; then
    fail "registry $lookup_mode lookup unexpectedly succeeded"
  fi
done
pass "registry lookup distinguishes 404 from HTTP, transport, parse, and unsafe-ID failures"

DAIANA_REGISTRY_USERNAME=caller-user
DAIANA_REGISTRY_PAT=caller-pat
export DAIANA_REGISTRY_USERNAME DAIANA_REGISTRY_PAT
LOOKUP_MODE=404
if ! portainer_ensure_private_registry; then
  fail "registry creation after confirmed 404 failed"
fi
[ "$DAIANA_REGISTRY_USERNAME" = caller-user ] || fail "registry lookup overwrote caller username"
[ "$DAIANA_REGISTRY_PAT" = caller-pat ] || fail "registry lookup overwrote caller PAT"
pass "registry helper preserves caller credential variables"

command_substitution_response="{\"Id\":\"\$(touch $TMP_DIR/registry-command)\"}"
backtick_response="{\"Id\":\"\`touch $TMP_DIR/registry-backtick\`\"}"
for invalid_response in \
  '{"Id":"17"}' '{"Id":{}}' '{"Id":[]}' '{"Id":null}' \
  '{"nested":{"Id":17}}' '{"Id":0}' '{"Id":-1}' \
  '{"Id":9007199254740992}' '{"Id":1.0}' '{"Id":1e3}' \
  'not-json' '{"Id":17} {"id":18}' \
  "$command_substitution_response" "$backtick_response"; do
  CREATION_RESPONSE="$invalid_response"
  PORTAINER_DAIA_REGISTRIES_JSON=caller-registry
  if portainer_ensure_private_registry >/dev/null 2>"$TMP_DIR/invalid-response.err"; then
    fail "invalid registry creation response was accepted: $invalid_response"
  fi
  [ "$PORTAINER_DAIA_REGISTRIES_JSON" = caller-registry ] || fail "invalid registry response changed caller registries"
  [ ! -e "$TMP_DIR/registry-command" ] || fail "command substitution payload executed"
  [ ! -e "$TMP_DIR/registry-backtick" ] || fail "backtick payload executed"
done
CREATION_RESPONSE='{"Id":17}'
pass "registry creation validates one safe numeric ID and rejects untrusted shell payloads"

prompt_script="$TMP_DIR/prompted-registry.sh"
cat > "$prompt_script" <<'EOF'
set -euo pipefail
source "$1"
PORTAINER_URL=http://portainer.test
export PORTAINER_URL
DAIANA_REGISTRY_USERNAME=''
DAIANA_REGISTRY_PAT=''
DAIANA_REGISTRY_NAME=prompted-registry
PORTAINER_DAIA_REGISTRIES_JSON=caller-registry
PROMPT_LOG="$2"
prompt() { builtin printf '%s' 'registry-user-sentinel'; }
prompt_secret() { builtin printf '%s' 'registry-pat-sentinel'; }
curl() {
  local config="$2" content
  content="$(<"$config")"
  case "$content" in
    *'request = "GET"'*'/api/registries'*) builtin printf '[]\n200\n' ;;
    *'request = "POST"'*'/api/registries'*)
      data_file="$(awk -F'"' '/data-binary/ {print $2}' "$config")"
      data_file="${data_file#@}"
      body="$(<"$data_file")"
      case "$body" in
        *registry-user-sentinel*|*registry-pat-sentinel*)
          builtin printf '%s\n' "$body" >> "$PROMPT_LOG"
          builtin printf '{"Id":23}\n201\n'
          ;;
        *) return 21 ;;
      esac
      ;;
    *) return 22 ;;
  esac
}
docker_cmd() {
  builtin printf '%s\n' "$*" >> "$PROMPT_LOG"
  cat >> "$PROMPT_LOG"
}
log() { :; }
portainer_ensure_private_registry
docker_login_private_registry
[ -z "$DAIANA_REGISTRY_USERNAME" ]
[ -z "$DAIANA_REGISTRY_PAT" ]
EOF
if ! (TMPDIR="$TMP_DIR/mktemp" bash -x "$prompt_script" "$TMP_DIR/portainer-functions.sh" "$TMP_DIR/prompt.log") \
  >"$TMP_DIR/prompt.out" 2>"$TMP_DIR/prompt.err"; then
  fail "prompted registry credential flow failed"
fi
grep -q 'registry-user-sentinel' "$TMP_DIR/prompt.log" || fail "prompted username did not reach registry/login"
grep -q 'registry-pat-sentinel' "$TMP_DIR/prompt.log" || fail "prompted PAT did not reach registry/login"
! grep -q 'registry-user-sentinel\|registry-pat-sentinel' "$TMP_DIR/prompt.out" "$TMP_DIR/prompt.err" \
  || fail "prompted credential sentinel leaked under bash -x"
pass "prompted registry credentials reach creation and Docker login without mutating caller variables"

: > "$lookup_log"
LOOKUP_MODE=500
if portainer_ensure_private_registry >/dev/null 2>"$TMP_DIR/lookup-suppressed.err"; then
  fail "registry lookup HTTP failure was accepted"
fi
! grep -q 'request = "POST"' "$lookup_log" || fail "registry lookup error was followed by a POST"
pass "registry lookup errors suppress registry creation requests"

PORTAINER_ADMIN_USER=fixture-admin
PORTAINER_ADMIN_PASS=fixture-admin-pass
export PORTAINER_ADMIN_USER PORTAINER_ADMIN_PASS
curl() { printf '{}\n409\n'; }
if ! portainer_admin_init; then
  fail "Portainer admin-init HTTP 409 was not explicitly accepted"
fi
curl() { printf '{"error":"server"}\n500\n'; }
if portainer_admin_init; then
  fail "unexpected Portainer admin-init status was accepted"
fi
pass "Portainer admin-init returns status to its explicit 409 handler"

PORTAINER_TOKEN=caller-token
export PORTAINER_TOKEN
curl() { printf '{"error":"server"}\n500\n'; }
if portainer_token >/dev/null 2>"$TMP_DIR/token-http.err"; then
  fail "token HTTP failure was accepted"
fi
curl() { printf 'not-json\n200\n'; }
if portainer_token >/dev/null 2>"$TMP_DIR/token-parse.err"; then
  fail "malformed token response was accepted"
fi
curl() { printf '{}\n200\n'; }
if portainer_token >/dev/null 2>"$TMP_DIR/token-empty.err"; then
  fail "empty token response was accepted"
fi
[ "$PORTAINER_TOKEN" = caller-token ] || fail "token failure overwrote caller token"
pass "token HTTP, malformed, and empty responses fail closed"

printf '%s' '{"not":"an Env array"' > "$env_file"
if portainer_submit_stack_file daiana-app "$env_file" "$registry_file" "$stack_file" \
  >"$TMP_DIR/parse.out" 2>"$TMP_DIR/parse.err"; then
  fail "malformed Env parse was accepted"
fi
! grep -q 'fixture-secret' "$TMP_DIR/parse.out" "$TMP_DIR/parse.err" \
  || fail "parse diagnostics exposed secret"
assert_temp_dir_empty
pass "JSON parse failure cleans body and keeps diagnostics redacted"

conditional_script="$TMP_DIR/conditional-failures.sh"
cat > "$conditional_script" <<'EOF'
set -u
source "$1"
PORTAINER_URL=http://portainer.test
export PORTAINER_URL
REQUEST_LOG="$2"
export REQUEST_LOG
curl() { printf 'REQUESTED\n' >> "$REQUEST_LOG"; return 0; }

mktemp() { return 71; }
if portainer_request_json GET /mktemp conditional-secret; then
  exit 10
fi

unset -f mktemp
chmod() { return 72; }
if portainer_request_json GET /chmod conditional-secret; then
  exit 11
fi

unset -f chmod
printf() {
  case "$*" in
    *conditional-secret*) return 73 ;;
    *) builtin printf "$@" ;;
  esac
}
if portainer_request_json POST /write conditional-secret; then
  exit 12
fi

printf() {
  case "$1" in
    silent*) return 74 ;;
    *) builtin printf "$@" ;;
  esac
}
if portainer_request_json GET /config safe-config; then
  exit 13
fi
EOF
if ! (TMPDIR="$TMP_DIR/mktemp" bash "$conditional_script" "$TMP_DIR/portainer-functions.sh" "$TMP_DIR/request.log") \
  >"$TMP_DIR/conditional.out" 2>"$TMP_DIR/conditional.err"; then
  fail "conditional allocation/write failures were accepted"
fi
[ ! -e "$TMP_DIR/request.log" ] || fail "conditional failures still issued a request"
assert_temp_dir_empty
! grep -q 'conditional-secret' "$TMP_DIR/conditional.out" "$TMP_DIR/conditional.err" \
  || fail "conditional failure diagnostics exposed secret"
pass "conditional mktemp, chmod, payload, and config failures fail closed without requests"

ensure_failure_script="$TMP_DIR/ensure-failures.sh"
cat > "$ensure_failure_script" <<'EOF'
set -euo pipefail
source "$1"
mode="$2"
request_log="$3"
trap_log="$request_log.trap"
PORTAINER_URL=http://portainer.test
export PORTAINER_URL
DAIANA_REGISTRY_NAME=fixture-registry
DAIANA_REGISTRY_USERNAME=fixture-user
DAIANA_REGISTRY_PAT=fixture-secret
PORTAINER_DAIA_REGISTRIES_JSON=caller-registry
PORTAINER_TEMP_SCOPE_DEPTH=caller-depth
PORTAINER_TEMP_FILES=(caller-file)
PORTAINER_PREVIOUS_EXIT_TRAPS=(caller-exit-array)
PORTAINER_PREVIOUS_INT_TRAPS=(caller-int-array)
PORTAINER_PREVIOUS_TERM_TRAPS=(caller-term-array)
PORTAINER_PREVIOUS_HUP_TRAPS=(caller-hup-array)
trap 'builtin printf caller-exit >> "$trap_log"' EXIT
trap 'builtin printf caller-int >> "$trap_log"' INT
trap 'builtin printf caller-term >> "$trap_log"' TERM
trap 'builtin printf caller-hup >> "$trap_log"' HUP

portainer_registry_id() { return 0; }
die() { return 1; }
curl() {
  builtin printf '%s\n' requested >> "$request_log"
  builtin printf '{}\n500\n'
}
if [ "$mode" = allocation ]; then
  mktemp() { return 71; }
fi
if [ "$mode" = write ]; then
  printf() {
    case "$*" in
      *fixture-secret*) return 72 ;;
      *) builtin printf "$@" ;;
    esac
  }
fi
if [ "$mode" = jq ]; then
  jq() { return 73; }
fi
if [ "$mode" = request ]; then
  curl() {
    builtin printf '%s\n' requested >> "$request_log"
    builtin printf '{}\n500\n'
  }
fi

before_exit="$(trap -p EXIT)"
before_int="$(trap -p INT)"
before_term="$(trap -p TERM)"
before_hup="$(trap -p HUP)"
set -x
if portainer_ensure_private_registry; then
  result=0
else
  result=$?
fi
builtin printf 'result=%s\n' "$result" >&2
[ "$result" -ne 0 ] || exit 10
case "$-" in *x*) ;; *) exit 11 ;; esac
set +x
[ "${PORTAINER_DAIA_REGISTRIES_JSON}" = caller-registry ]
[ "${PORTAINER_TEMP_SCOPE_DEPTH}" = caller-depth ]
[ "${PORTAINER_TEMP_FILES[*]}" = caller-file ]
[ "${PORTAINER_PREVIOUS_EXIT_TRAPS[*]}" = caller-exit-array ]
[ "${PORTAINER_PREVIOUS_INT_TRAPS[*]}" = caller-int-array ]
[ "${PORTAINER_PREVIOUS_TERM_TRAPS[*]}" = caller-term-array ]
[ "${PORTAINER_PREVIOUS_HUP_TRAPS[*]}" = caller-hup-array ]
[ "$(trap -p EXIT)" = "$before_exit" ]
[ "$(trap -p INT)" = "$before_int" ]
[ "$(trap -p TERM)" = "$before_term" ]
[ "$(trap -p HUP)" = "$before_hup" ]
EOF
for failure_mode in allocation write jq request; do
  failure_log="$TMP_DIR/ensure-$failure_mode.log"
  if ! (TMPDIR="$TMP_DIR/mktemp" bash "$ensure_failure_script" "$TMP_DIR/portainer-functions.sh" \
    "$failure_mode" "$failure_log") >"$TMP_DIR/ensure-$failure_mode.out" 2>"$TMP_DIR/ensure-$failure_mode.err"; then
    fail "private registry $failure_mode cleanup/state assertions failed"
  fi
  assert_temp_dir_empty
  ! grep -q 'fixture-secret' "$TMP_DIR/ensure-$failure_mode.out" "$TMP_DIR/ensure-$failure_mode.err" \
    || fail "private registry $failure_mode diagnostics exposed secret"
  if [ "$failure_mode" != request ]; then
    [ ! -e "$failure_log" ] || fail "private registry $failure_mode failure issued a request"
  else
    grep -q requested "$failure_log" || fail "private registry request failure did not reach curl"
  fi
done
pass "private registry preparation/request failures restore caller state and clean temporary files"

partial_script="$TMP_DIR/partial-mktemp.sh"
cat > "$partial_script" <<'EOF'
set -euo pipefail
source "$1"
PORTAINER_URL=http://portainer.test
export PORTAINER_URL
state_file="$2"
request_log="$3"
: > "$state_file"
curl() { builtin printf 'REQUESTED\n' >> "$request_log"; return 0; }
mktemp() {
  count="$(<"$state_file")"
  count=$((count + 1))
  printf '%s' "$count" > "$state_file"
  if [ "$count" -eq 2 ]; then
    partial_path="$TMPDIR/partial-created"
    : > "$partial_path"
    printf '%s\n' "$partial_path"
    return 1
  fi
  command mktemp
}
render_compose() { printf 'services:\n' > "$1"; }
portainer_upsert_stack_from_vars app ENV REG compose.yml
EOF
if (cd "$TMP_DIR" && TMPDIR="$TMP_DIR/mktemp" ENV='[{"name":"SECRET","value":"fixture-secret"}]' REG='[]' \
  bash "$partial_script" "$TMP_DIR/portainer-functions.sh" "$TMP_DIR/partial-state" "$TMP_DIR/partial-requests") >"$TMP_DIR/partial.out" 2>"$TMP_DIR/partial.err"; then
  fail "partial mktemp failure was accepted"
fi
assert_temp_dir_empty
! grep -q 'fixture-secret' "$TMP_DIR/partial.out" "$TMP_DIR/partial.err" \
  || fail "partial allocation leaked secret"
[ ! -e "$TMP_DIR/partial-requests" ] || fail "partial allocation attempted a request"
pass "partial mktemp failure cleans all earlier files without a request"

chmod_script="$TMP_DIR/chmod-failure.sh"
cat > "$chmod_script" <<'EOF'
set -euo pipefail
source "$1"
PORTAINER_URL=http://portainer.test
export PORTAINER_URL
chmod() { return 1; }
portainer_request_json GET /chmod safe-fixture
EOF
if (TMPDIR="$TMPDIR/mktemp" bash "$chmod_script" "$TMP_DIR/portainer-functions.sh") \
  >"$TMP_DIR/chmod.out" 2>"$TMP_DIR/chmod.err"; then
  fail "chmod failure was accepted"
fi
assert_temp_dir_empty
! grep -q 'safe-fixture' "$TMP_DIR/chmod.out" "$TMP_DIR/chmod.err" \
  || fail "chmod failure diagnostics exposed data"
pass "chmod failure cleans the immediately registered file"

trap_script="$TMP_DIR/trap-status.sh"
cat > "$trap_script" <<'EOF'
set -euo pipefail
source "$1"
trap 'printf caller-exit >> "$2"' EXIT
trap 'printf caller-int >> "$2"' INT
trap 'printf caller-term >> "$2"' TERM
trap 'printf caller-hup >> "$2"' HUP
curl() { printf '{"ok":true}\n200\n'; }
portainer_request_json GET /trap fixture-secret >/dev/null
[[ "$(trap -p EXIT)" == *caller-exit* ]]
[[ "$(trap -p INT)" == *caller-int* ]]
EOF
trap_marker="$TMP_DIR/trap-marker"
if bash "$trap_script" "$TMP_DIR/portainer-functions.sh" "$trap_marker" >"$TMP_DIR/trap.out" 2>"$TMP_DIR/trap.err"; then :; else
  fail "caller trap/status restoration failed"
fi
assert_temp_dir_empty
pass "caller traps and successful status are restored"

xtrace_script="$TMP_DIR/xtrace.sh"
cat > "$xtrace_script" <<'EOF'
set -euo pipefail
source "$1"
PORTAINER_URL=http://portainer.test
export PORTAINER_URL
curl() { printf '{"password":"fixture-secret"}\n200\n'; }
portainer_request_json POST /xtrace safe-fixture >/dev/null
EOF
if (TMPDIR="$TMPDIR/mktemp" bash -x "$xtrace_script" "$TMP_DIR/portainer-functions.sh") \
  >"$TMP_DIR/xtrace.out" 2>"$TMP_DIR/xtrace.err"; then :; else
  fail "xtrace request failed"
fi
! grep -q 'fixture-secret' "$TMP_DIR/xtrace.out" "$TMP_DIR/xtrace.err" \
  || fail "xtrace exposed request secret"
pass "xtrace contains no request secret"

for signal in INT TERM HUP; do
  signal_script="$TMP_DIR/signal-$signal.sh"
  cat > "$signal_script" <<'EOF'
set -euo pipefail
source "$1"
PORTAINER_TEMP_FILES=()
PORTAINER_TEMP_SCOPE_DEPTH=-1
PORTAINER_PREVIOUS_EXIT_TRAPS=()
PORTAINER_PREVIOUS_INT_TRAPS=()
PORTAINER_PREVIOUS_TERM_TRAPS=()
PORTAINER_PREVIOUS_HUP_TRAPS=()
portainer_begin_temp_scope
portainer_temp_create signal_file
portainer_temp_trap SIGNAL
EOF
  sed "s/SIGNAL/$signal/g" "$signal_script" > "$signal_script.tmp"
  mv "$signal_script.tmp" "$signal_script"
  if (TMPDIR="$TMPDIR/mktemp" bash "$signal_script" "$TMP_DIR/portainer-functions.sh") >"$TMP_DIR/signal-$signal.out" 2>"$TMP_DIR/signal-$signal.err"; then
    fail "$signal cleanup unexpectedly succeeded"
  fi
  assert_temp_dir_empty
  ! grep -q 'fixture-secret' "$TMP_DIR/signal-$signal.out" "$TMP_DIR/signal-$signal.err" \
    || fail "$signal diagnostics exposed secret"
done
pass "signal cleanup covers INT, TERM, and HUP"

printf 'Portainer protected-temp cleanup tests passed\n'
