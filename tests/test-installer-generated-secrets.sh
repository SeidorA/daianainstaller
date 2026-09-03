#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

grep -Fq 'ensure_secret STUDIO_PROVISIONING_SECRET 64' "$ROOT_DIR/install-daiana.sh" \
  || fail 'Studio provisioning secret is not part of the generated-secret contract'
secret_line="$(awk '/^  ensure_secret STUDIO_PROVISIONING_SECRET 64$/ { print NR; exit }' "$ROOT_DIR/install-daiana.sh")"
stack_env_line="$(awk '/APP_STACK_ENV_JSON="\$\(stack_env_json/ { print NR; exit }' "$ROOT_DIR/install-daiana.sh")"
[[ -n "$secret_line" && -n "$stack_env_line" && "$secret_line" -lt "$stack_env_line" ]] \
  || fail 'Studio provisioning secret is generated after stack Env construction'

next_block="$(awk '/^  daiananext:$/,/^  daianapython:$/ { print }' "$ROOT_DIR/docker-compose.app.yml")"
studio_block="$(awk '/^  daianastudio:$/,/^  daianawebui:$/ { print }' "$ROOT_DIR/docker-compose.app.yml")"
[[ "$next_block" == *'STUDIO_PROVISIONING_SECRET: ${STUDIO_PROVISIONING_SECRET}'* ]] \
  || fail 'Next does not receive the Studio provisioning secret'
[[ "$studio_block" == *'DAIANA_STUDIO_PROVISIONING_SECRET: ${STUDIO_PROVISIONING_SECRET}'* ]] \
  || fail 'Studio does not receive the Studio provisioning secret'
pass 'Studio provisioning secret is wired to both Next and Studio'

awk '/^generate_secret\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/functions.sh"
awk '/^persist_env_value\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/functions.sh"
awk '
  /^ensure_secret\(\)/ { in_function=1 }
  in_function {
    end_function = ($0 ~ /^  }$/)
    sub(/^  /, "")
    print
    if (end_function) exit
  }
' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/functions.sh"
awk '/^extract_compose_vars\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/functions.sh"
awk '/^stack_env_json\(\)/,/^}/ { print }' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/functions.sh"

(
  cd "$TMP_DIR"
  printf 'STUDIO_PROVISIONING_SECRET=\n' > .env
  changed=0
  DRY_RUN=0
  log() { :; }
  # shellcheck disable=SC1091
  source "$TMP_DIR/functions.sh"

  ensure_secret STUDIO_PROVISIONING_SECRET 64
  generated_secret="$STUDIO_PROVISIONING_SECRET"
  [[ "${#generated_secret}" -eq 64 ]] || fail 'Generated Studio provisioning secret is not 64 characters'
  persisted_secret="$(awk -F= '$1 == "STUDIO_PROVISIONING_SECRET" { print substr($0, index($0, "=") + 1) }' .env)"
  [[ "$persisted_secret" == "$generated_secret" ]] || fail 'Generated Studio provisioning secret was not persisted'

  output="$({ ensure_secret STUDIO_PROVISIONING_SECRET 64; } 2>&1)"
  [[ "$STUDIO_PROVISIONING_SECRET" == "$generated_secret" ]] || fail 'Existing Studio provisioning secret was overwritten'
  [[ "$output" != *"$generated_secret"* ]] || fail 'Studio provisioning secret was printed'

  stack_env="$(stack_env_json "$ROOT_DIR/docker-compose.app.yml")"
  stack_value="$(jq -er '.[] | select(.name == "STUDIO_PROVISIONING_SECRET") | .value' <<<"$stack_env")"
  [[ "$stack_value" == "$generated_secret" ]] || fail 'Generated Studio provisioning secret is missing from stack Env'
)
pass 'Studio provisioning secret is generated, persisted, retained, and included in stack Env'

printf 'Installer generated-secret tests passed\n'
