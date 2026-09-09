#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

compose_file="$ROOT_DIR/docker-compose.app.yml"
next_block="$(awk '/^  daiananext:$/,/^  daianapython:$/ { print }' "$compose_file")"
for variable in \
  NEXT_PUBLIC_API_PYTHON \
  NEXT_PUBLIC_API_STUDIO_BASE_URL \
  NEXT_PUBLIC_WEBUI_URL \
  NEXT_PUBLIC_APP_URL \
  NEXT_PUBLIC_HELP_CENTER; do
  [[ "$next_block" != *"$variable:"* ]] || fail "$variable is still wired into daiananext"
done
[[ "$next_block" == *'NEXT_PUBLIC_SUPABASE_URL: ${SUPABASE_PUBLIC_URL}'* ]] \
  || fail 'Supabase URL bootstrap wiring is missing from daiananext'
[[ "$next_block" == *'NEXT_PUBLIC_SUPABASE_ANON_KEY: ${ANON_KEY}'* ]] \
  || fail 'Supabase anon key bootstrap wiring is missing from daiananext'
[[ "$next_block" == *'PRIVATE_CHAT_PYTHON_ORIGIN: ${BACKEND_BASE_URL}'* ]] \
  || fail 'Internal Python proxy origin wiring is missing from daiananext'
[[ "$next_block" == *'STUDIO_PROVISIONING_URL: ${STUDIO_PROVISIONING_URL:-http://daianastudio:3000}'* ]] \
  || fail 'Internal Studio provisioning URL wiring is missing from daiananext'
[[ "$next_block" == *'DAIANA_SERVER_TELEMETRY_WEBHOOK_URL: ${DAIANA_SERVER_TELEMETRY_WEBHOOK_URL:-}'* ]] \
  || fail 'Optional telemetry webhook wiring changed'
pass 'daiananext receives bootstrap/internal values, not Vault-backed public URLs'

grep -Fq 'ensure_default STUDIO_PROVISIONING_URL "http://daianastudio:3000"' "$ROOT_DIR/install-daiana.sh" \
  || fail 'Installer default for Studio provisioning URL is missing'
grep -Fq 'ensure_default GOOGLE_MODEL "gemini-2.5-flash-lite"' "$ROOT_DIR/install-daiana.sh" \
  || fail 'Installer default for Google model is missing'
grep -Fq 'ensure_default GOOGLE_EMBEDDING_MODEL "gemini-embedding-001"' "$ROOT_DIR/install-daiana.sh" \
  || fail 'Installer default for Google embedding model is missing'
if grep -Eq 'ensure_(default|secret|derived) DAIANA_SERVER_TELEMETRY_WEBHOOK_URL' "$ROOT_DIR/install-daiana.sh"; then
  fail 'Installer generates or defaults the optional telemetry webhook URL'
fi

awk '/^  ensure_default\(\)/,/^  }$/ { print }' "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/ensure-default.sh"
(
  cd "$TMP_DIR"
  DRY_RUN=0
  changed=0
  log() { :; }
  persist_env_value() { :; }
  # shellcheck disable=SC1091
  source "$TMP_DIR/ensure-default.sh"

  STUDIO_PROVISIONING_URL=''
  GOOGLE_MODEL=''
  GOOGLE_EMBEDDING_MODEL=''
  ensure_default STUDIO_PROVISIONING_URL 'http://daianastudio:3000'
  ensure_default GOOGLE_MODEL 'gemini-2.5-flash-lite'
  ensure_default GOOGLE_EMBEDDING_MODEL 'gemini-embedding-001'
  [[ "$STUDIO_PROVISIONING_URL" == 'http://daianastudio:3000' ]] || fail 'Empty Studio URL did not receive its default'
  [[ "$GOOGLE_MODEL" == 'gemini-2.5-flash-lite' ]] || fail 'Empty Google model did not receive its default'
  [[ "$GOOGLE_EMBEDDING_MODEL" == 'gemini-embedding-001' ]] || fail 'Empty Google embedding model did not receive its default'

  STUDIO_PROVISIONING_URL='http://custom-studio:3000'
  ensure_default STUDIO_PROVISIONING_URL 'http://daianastudio:3000'
  [[ "$STUDIO_PROVISIONING_URL" == 'http://custom-studio:3000' ]] || fail 'Existing Studio URL was overwritten'
)
pass 'Empty installer values receive defaults without overwriting existing values'

grep -Fq 'NEXT_PUBLIC_HELP_CENTER` is deprecated and unused' "$ROOT_DIR/CONFIG.md" \
  || fail 'Deprecated Help Center ownership is not documented'
grep -Fq 'Vault is the runtime source of truth for public URL values' "$ROOT_DIR/CONFIG.md" \
  || fail 'Vault public URL ownership is not documented'
grep -Fq 'DAIANA_SERVER_TELEMETRY_WEBHOOK_URL` is optional and is never generated' "$ROOT_DIR/CONFIG.md" \
  || fail 'Optional telemetry ownership is not documented'
pass 'Configuration ownership and deprecated Help Center behavior are documented'

printf 'Installer configuration tests passed\n'
