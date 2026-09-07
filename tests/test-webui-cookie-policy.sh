#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2034,SC2329

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

compose_file="$ROOT_DIR/docker-compose.app.yml"
grep -Fq "WEBUI_SESSION_COOKIE_SAME_SITE: \${WEBUI_SESSION_COOKIE_SAME_SITE:-none}" "$compose_file" \
  || fail 'production session SameSite default is not none'
grep -Fq "WEBUI_SESSION_COOKIE_SECURE: \${WEBUI_SESSION_COOKIE_SECURE:-true}" "$compose_file" \
  || fail 'production session Secure default is not true'
grep -Fq "WEBUI_AUTH_COOKIE_SAME_SITE: \${WEBUI_AUTH_COOKIE_SAME_SITE:-none}" "$compose_file" \
  || fail 'production auth SameSite default is not none'
grep -Fq "WEBUI_AUTH_COOKIE_SECURE: \${WEBUI_AUTH_COOKIE_SECURE:-true}" "$compose_file" \
  || fail 'production auth Secure default is not true'
pass 'production WebUI cookie defaults remain secure'

awk '/^persist_env_value\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/functions.sh"
awk '/^extract_compose_vars\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/functions.sh"
awk '/^stack_env_json\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/functions.sh"
awk '/^if \[ "\$DAIANA_LOCAL_INSTALL" = "1" \]; then$/,/^fi$/ { print }' \
  "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/local-mode.sh"

(
  cd "$TMP_DIR"
  printf 'BASE_DOMAIN=example.com\n' > .env
  export DRY_RUN=0
  export DAIANA_LOCAL_INSTALL=1
  export BASE_DOMAIN='example.com'
  export WEBUI_ALLOW_INSECURE_LOCAL_ORIGIN='false'
  export WEBUI_SESSION_COOKIE_SAME_SITE='none'
  export WEBUI_SESSION_COOKIE_SECURE='true'
  export WEBUI_AUTH_COOKIE_SAME_SITE='none'
  export WEBUI_AUTH_COOKIE_SECURE='true'
  # shellcheck disable=SC2329
  detect_local_ipv4() { printf '10.20.30.40'; }
  # shellcheck disable=SC2329
  die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
  # shellcheck disable=SC2329
  log() { :; }
  # shellcheck disable=SC1091
  source "$TMP_DIR/functions.sh"
  # shellcheck disable=SC1091
  source "$TMP_DIR/local-mode.sh"

  [[ "$WEBUI_SESSION_COOKIE_SAME_SITE" == lax ]] || exit 1
  [[ "$WEBUI_SESSION_COOKIE_SECURE" == false ]] || exit 1
  [[ "$WEBUI_AUTH_COOKIE_SAME_SITE" == lax ]] || exit 1
  [[ "$WEBUI_AUTH_COOKIE_SECURE" == false ]] || exit 1
  stack_env="$(stack_env_json "$compose_file")"
  for var in WEBUI_SESSION_COOKIE_SAME_SITE WEBUI_SESSION_COOKIE_SECURE WEBUI_AUTH_COOKIE_SAME_SITE WEBUI_AUTH_COOKIE_SECURE; do
    grep -Fq "$var=${!var}" .env || exit 1
    stack_value="$(jq -er --arg name "$var" '.[] | select(.name == $name) | .value' <<<"$stack_env")"
    [[ "$stack_value" == "${!var}" ]] || exit 1
  done
)
pass 'local installation exports and persists HTTP-compatible WebUI cookie values'

printf 'WebUI cookie policy tests passed\n'
