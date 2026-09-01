#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

grep -q '^LOCAL_PROVISION_IMAGES=0$' "$ROOT_DIR/.env.example" \
  || fail "local provisioning setting does not default to 0"
grep -q 'docker-compose.local-provision.yml' "$ROOT_DIR/.env.example" \
  || fail "local provisioning setting is not documented"
grep -q 'pull_policy: never' "$ROOT_DIR/docker-compose.local-provision.yml" \
  || fail "local override does not disable pulls"

awk '/^configure_local_provision_compose\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/local-functions.sh"
awk '/^validate_local_provision_images\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/local-functions.sh"
source "$TMP_DIR/local-functions.sh"
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

ROOT_DIR="$ROOT_DIR"
LOCAL_PROVISION_IMAGES=1
DRY_RUN=0
APP_DEPLOY_COMPOSE_FILES=(docker-compose.yml docker-compose.app.yml)
LOG_OUTPUT=""
log() { LOG_OUTPUT="${LOG_OUTPUT}${*}\n"; }
configure_local_provision_compose
[[ "${APP_DEPLOY_COMPOSE_FILES[*]}" == *"docker-compose.local-provision.yml" ]] \
  || fail "local compose override was not selected"
pass "local mode selects the Daiana local compose override"

LOCAL_PROVISION_IMAGES=0
APP_DEPLOY_COMPOSE_FILES=(docker-compose.yml docker-compose.app.yml)
configure_local_provision_compose
[[ "${APP_DEPLOY_COMPOSE_FILES[*]}" == "docker-compose.yml docker-compose.app.yml" ]] \
  || fail "production mode changed the default compose selection"
docker_cmd() { return 99; }
validate_local_provision_images || fail "production mode unexpectedly performed local image validation"
pass "unset/zero local mode preserves production compose selection and skips local checks"

CHECKED_IMAGES=""
LOCAL_PROVISION_IMAGES=1
CHECKED_IMAGES_FILE="$TMP_DIR/checked-images"
docker_cmd() {
  [ "$3" = "daianastudio-local:account-provision" ] && return 1
  printf '%s\n' "$3" >> "$CHECKED_IMAGES_FILE"
}
if (validate_local_provision_images >"$TMP_DIR/check.out" 2>"$TMP_DIR/check.err"); then
  fail "missing local image was accepted"
fi
grep -q 'daiana-local:studio-provision' "$CHECKED_IMAGES_FILE" || fail "first local image was not checked"
grep -q 'daianastudio-local:account-provision' "$TMP_DIR/check.err" \
  || fail "missing image message was not actionable"
pass "local mode validates both required image tags and fails clearly"

grep -q 'skipping private registry setup and Daiana image pre-pull' "$ROOT_DIR/install-daiana.sh" \
  || fail "local mode does not skip registry setup and pre-pull"
grep -q 'portainer_upsert_stack_from_vars.*EMPTY_REGISTRIES_VAR.*APP_DEPLOY_COMPOSE_FILES' "$ROOT_DIR/install-daiana.sh" \
  || fail "local deployment still sends private registry configuration"
grep -q 'private Daiana image registry when needed (production mode only)' "$ROOT_DIR/install-daiana.sh" \
  || fail "dry-run production registry behavior is not documented"
grep -q 'local provisioning image checks:' "$ROOT_DIR/install-daiana.sh" \
  || fail "dry-run local image checks are not shown"
pass "local skip-pull behavior, production gating, and dry-run reporting are present"

printf 'Local provisioning installer tests passed\n'
