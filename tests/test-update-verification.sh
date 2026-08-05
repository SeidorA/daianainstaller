#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
log() { LOG_OUTPUT="${LOG_OUTPUT}${*}\n"; }

# shellcheck source=utils/update-verification.sh
source "$ROOT_DIR/utils/update-verification.sh"

# These fixtures are consumed by the sourced verifier.
# shellcheck disable=SC2034
SITE_URL="https://next.example.test"
# shellcheck disable=SC2034
BACKEND_BASE_URL="https://python.example.test"
# shellcheck disable=SC2034
STUDIO_BASE_URL="https://studio.example.test"
# shellcheck disable=SC2034
MS_BASE_URL="https://msteams.example.test"
# shellcheck disable=SC2034
BUNDLE_MSTEAMS_IMAGE="registry.example.com/msteams@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# shellcheck disable=SC2034
DAIANA_POST_DEPLOY_MAX_TRIES=3
# shellcheck disable=SC2034
DAIANA_POST_DEPLOY_RETRY_DELAY=0
WAIT_CALLS=""
FAIL_LABEL=""
LOG_OUTPUT=""

wait_for_http() {
  WAIT_CALLS="${WAIT_CALLS}${1}|${2}|${3}|${4}|${5}|${6}\n"
  [ "$2" != "$FAIL_LABEL" ]
}

snapshot="$TMP_DIR/20260726-181500"
mkdir -p "$snapshot"
printf '%s\n' '{"id":"20260726-181500","type":"image-orchestration-rollback"}' > "$snapshot/metadata.json"
# shellcheck disable=SC2034
LAST_UPDATE_SNAPSHOT_DIR="$snapshot"

verify_update_services || fail "healthy services were rejected"
[[ "$(printf '%b' "$WAIT_CALLS" | wc -l | tr -d ' ')" -eq 4 ]] || fail "not all four services were checked"
[[ "$WAIT_CALLS" == *"https://next.example.test/|Daiana Next readiness|3|0|1|0"* ]] || fail "Next readiness endpoint or retry bound is wrong"
[[ "$WAIT_CALLS" == *"https://python.example.test/api/v1/health|Daiana Python readiness|3|0|0|0"* ]] || fail "Python health endpoint is wrong"
[[ "$WAIT_CALLS" == *"https://msteams.example.test/health|Daiana Teams readiness|3|0|0|0"* ]] || fail "Teams health endpoint is wrong"
[[ "$WAIT_CALLS" == *"https://studio.example.test/api/v1/ping|Daiana Studio readiness|3|0|0|0"* ]] || fail "Studio ping endpoint is wrong"
pass "post-deployment verification requires Next, Python, Teams, and Studio readiness"

WAIT_CALLS=""
BUNDLE_MSTEAMS_IMAGE=""
verify_update_services || fail "legacy three-service readiness was rejected"
[[ "$(printf '%b' "$WAIT_CALLS" | wc -l | tr -d ' ')" -eq 3 ]] || fail "legacy bundle unexpectedly added Teams readiness"
pass "legacy three-image updates retain three-service readiness compatibility"
BUNDLE_MSTEAMS_IMAGE="registry.example.com/msteams@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

WAIT_CALLS=""
LOG_OUTPUT=""
FAIL_LABEL="Daiana Python readiness"
if verify_update_services; then fail "failed Python health check was accepted"; fi
[[ "$WAIT_CALLS" != *"Daiana Studio readiness"* ]] || fail "verification continued after failure"
recovery_command="bash update-daiana.sh --rollback 20260726-181500"
[[ "$LOG_OUTPUT" == *"$recovery_command"* ]] || fail "failure log omitted exact recovery command"
jq -e \
  --arg command "$recovery_command" \
  '.recovery.status == "post-deploy-verification-failed" and
   .recovery.service == "Daiana Python" and
   .recovery.endpoint == "https://python.example.test/api/v1/health" and
   .recovery.rollback_command == $command and
   (.recovery.note | contains("does not reverse migrations"))' \
  "$snapshot/metadata.json" >/dev/null || fail "recovery metadata is incomplete"
pass "timeout fails closed with persisted non-automatic recovery guidance"

submit_line="$(grep -n '^portainer_upsert_stack_from_vars .*APP_DEPLOY_COMPOSE_FILES' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
verify_line="$(grep -n '^  verify_update_services' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
success_line="$(grep -n '^Update complete\.$' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
[[ -n "$submit_line" && -n "$verify_line" && -n "$success_line" ]] || fail "could not locate update verification lifecycle"
[[ "$submit_line" -lt "$verify_line" && "$verify_line" -lt "$success_line" ]] \
  || fail "verification is not after stack update and before success"
pass "update success is ordered after the post-deployment gate"

awk '/^wait_for_http\(\)/,/^}/' "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/wait-for-http.sh"
# shellcheck source=/dev/null
source "$TMP_DIR/wait-for-http.sh"
CURL_CALLS_FILE="$TMP_DIR/curl-calls"
: > "$CURL_CALLS_FILE"
curl() {
  printf 'call\n' >> "$CURL_CALLS_FILE"
  printf 'not ready\n503\n'
}
sleep() { :; }
LOG_OUTPUT=""
if wait_for_http "https://python.example.test/api/v1/health" "Daiana Python readiness" 3 0 1 0; then
  fail "bounded health timeout unexpectedly succeeded"
fi
[[ "$(wc -l < "$CURL_CALLS_FILE" | tr -d ' ')" -eq 3 ]] || fail "health timeout did not honor the retry bound"
[[ "$LOG_OUTPUT" != *"not ready"* ]] || fail "health response body leaked into verification logs"
pass "health timeout performs bounded retries without logging response bodies"
