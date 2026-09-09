#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

grep -Fq 'ensure_secret STUDIO_PROVISIONING_SECRET 64' "$ROOT_DIR/install-daiana.sh" \
  || fail 'Studio provisioning secret is not part of the generated-secret contract'
grep -Fq 'ensure_secret TEAMS_INTERNAL_AUTH_SECRET 64' "$ROOT_DIR/install-daiana.sh" \
  || fail 'Teams internal auth secret is not part of the generated-secret contract'
studio_secret_line="$(awk '/^  ensure_secret STUDIO_PROVISIONING_SECRET 64$/ { print NR; exit }' "$ROOT_DIR/install-daiana.sh")"
teams_secret_line="$(awk '/^  ensure_secret TEAMS_INTERNAL_AUTH_SECRET 64$/ { print NR; exit }' "$ROOT_DIR/install-daiana.sh")"
stack_env_line="$(awk '/APP_STACK_ENV_JSON="\$\(stack_env_json/ { print NR; exit }' "$ROOT_DIR/install-daiana.sh")"
[[ -n "$studio_secret_line" && -n "$teams_secret_line" && -n "$stack_env_line" \
  && "$studio_secret_line" -lt "$stack_env_line" \
  && "$teams_secret_line" -lt "$stack_env_line" ]] \
  || fail 'Generated secrets are created after stack Env construction'

next_block="$(awk '/^  daiananext:$/,/^  daianapython:$/ { print }' "$ROOT_DIR/docker-compose.app.yml")"
python_block="$(awk '/^  daianapython:$/,/^  daianavanna:$/ { print }' "$ROOT_DIR/docker-compose.app.yml")"
teams_block="$(awk '/^  daianamsteams:$/,/^  daianawhatsapp:$/ { print }' "$ROOT_DIR/docker-compose.app.yml")"
studio_block="$(awk '/^  daianastudio:$/,/^  daianawebui:$/ { print }' "$ROOT_DIR/docker-compose.app.yml")"
[[ "$next_block" == *'STUDIO_PROVISIONING_SECRET: ${STUDIO_PROVISIONING_SECRET}'* ]] \
  || fail 'Next does not receive the Studio provisioning secret'
[[ "$studio_block" == *'DAIANA_STUDIO_PROVISIONING_SECRET: ${STUDIO_PROVISIONING_SECRET}'* ]] \
  || fail 'Studio does not receive the Studio provisioning secret'
[[ "$python_block" == *'TEAMS_INTERNAL_AUTH_SECRET: ${TEAMS_INTERNAL_AUTH_SECRET:-}'* ]] \
  || fail 'Python does not receive the Teams internal auth secret'
[[ "$teams_block" == *'TEAMS_INTERNAL_AUTH_SECRET: ${TEAMS_INTERNAL_AUTH_SECRET:-}'* ]] \
  || fail 'Teams does not receive the Teams internal auth secret'
pass 'Installer-generated secrets remain wired to their consumers'

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
  printf 'STUDIO_PROVISIONING_SECRET=\nTEAMS_INTERNAL_AUTH_SECRET=\n' > .env
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

  ensure_secret TEAMS_INTERNAL_AUTH_SECRET 64
  generated_teams_secret="$TEAMS_INTERNAL_AUTH_SECRET"
  [[ "${#generated_teams_secret}" -eq 64 ]] || fail 'Generated Teams internal auth secret is not 64 characters'
  persisted_teams_secret="$(awk -F= '$1 == "TEAMS_INTERNAL_AUTH_SECRET" { print substr($0, index($0, "=") + 1) }' .env)"
  [[ "$persisted_teams_secret" == "$generated_teams_secret" ]] || fail 'Generated Teams internal auth secret was not persisted'

  output="$({ ensure_secret STUDIO_PROVISIONING_SECRET 64; ensure_secret TEAMS_INTERNAL_AUTH_SECRET 64; } 2>&1)"
  [[ "$STUDIO_PROVISIONING_SECRET" == "$generated_secret" ]] || fail 'Existing Studio provisioning secret was overwritten'
  [[ "$TEAMS_INTERNAL_AUTH_SECRET" == "$generated_teams_secret" ]] || fail 'Existing Teams internal auth secret was overwritten'
  [[ "$output" != *"$generated_secret"* && "$output" != *"$generated_teams_secret"* ]] || fail 'Generated secret was printed'

  stack_env="$(stack_env_json "$ROOT_DIR/docker-compose.app.yml")"
  stack_value="$(jq -er '.[] | select(.name == "STUDIO_PROVISIONING_SECRET") | .value' <<<"$stack_env")"
  [[ "$stack_value" == "$generated_secret" ]] || fail 'Generated Studio provisioning secret is missing from stack Env'
  stack_teams_value="$(jq -er '.[] | select(.name == "TEAMS_INTERNAL_AUTH_SECRET") | .value' <<<"$stack_env")"
  [[ "$stack_teams_value" == "$generated_teams_secret" ]] || fail 'Generated Teams internal auth secret is missing from stack Env'
)
pass 'Generated secrets are generated, persisted, retained, and included in stack Env'

printf 'Installer generated-secret tests passed\n'
