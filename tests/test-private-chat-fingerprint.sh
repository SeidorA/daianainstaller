#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ORIGINAL_PATH="$PATH"

awk '$0 ~ /^case / && $0 ~ /preflight/ { exit } { print }' \
  "$ROOT_DIR/utils/private-chat-harness.sh" > "$TMP_DIR/functions.sh"
cat > "$TMP_DIR/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${4:-}" == *Config.Env* ]]; then
  printf '%s' "${FP_ENV:?}"
elif [[ "${4:-}" == *Config.Labels* ]]; then
  printf '%s' "${FP_LABELS:?}"
elif [[ "${4:-}" == *Mounts* ]]; then
  printf '%s\n' '|[]|default'
else
  printf '%s\n' 'local/image|/work|[]|[]|'
fi
DOCKER
chmod +x "$TMP_DIR/docker"

# shellcheck source=/dev/null
source "$TMP_DIR/functions.sh"
export PATH="$TMP_DIR:$PATH"

# shellcheck disable=SC2089,SC2090
FP_ENV='["A=line1\\nline2=equals","B=stable"]'
# shellcheck disable=SC2090
# shellcheck disable=SC2090
# shellcheck disable=SC2090
# shellcheck disable=SC2090
export FP_ENV
FP_LABELS='{"com.docker.compose.config-hash":"hash-a","com.docker.compose.replace":"container-a","com.example.owner":"harness"}'
export FP_LABELS
first="$(safe_config_fingerprint app)"
second="$(safe_config_fingerprint app)"
[[ "$first" == "$second" ]] || { printf 'fingerprint is not deterministic\n' >&2; exit 1; }

FP_LABELS='{"com.docker.compose.config-hash":"hash-b","com.docker.compose.replace":"container-b","com.example.owner":"harness"}'
export FP_LABELS
lifecycle_changed="$(safe_config_fingerprint app)"
[[ "$lifecycle_changed" == "$first" ]] || { printf 'Compose lifecycle label mutation changed the fingerprint\n' >&2; exit 1; }

FP_LABELS='{"com.docker.compose.config-hash":"hash-b","com.docker.compose.replace":"container-b","com.example.owner":"changed"}'
export FP_LABELS
application_changed="$(safe_config_fingerprint app)"
[[ "$application_changed" != "$first" ]] || { printf 'application label mutation was ignored\n' >&2; exit 1; }

# shellcheck disable=SC2089,SC2090
FP_ENV='["A=bc"]'
# shellcheck disable=SC2090
# shellcheck disable=SC2090
export FP_ENV
collision_a="$(safe_config_fingerprint app)"
# shellcheck disable=SC2089,SC2090
FP_ENV='["AB=c"]'
# shellcheck disable=SC2090
export FP_ENV
collision_b="$(safe_config_fingerprint app)"
[[ "$collision_a" != "$collision_b" ]] || { printf 'length-delimited collision was accepted\n' >&2; exit 1; }

# shellcheck disable=SC2089,SC2090
FP_ENV='["KEY","KEY="]'
# shellcheck disable=SC2090
export FP_ENV
key_without_equals="$(safe_config_fingerprint app)"
# shellcheck disable=SC2089,SC2090
FP_ENV='["KEY="]'
# shellcheck disable=SC2090
export FP_ENV
key_with_empty_value="$(safe_config_fingerprint app)"
[[ "$key_without_equals" != "$key_with_empty_value" ]] || { printf 'KEY and KEY= were conflated\n' >&2; exit 1; }

TMP_ENV_DIR="$TMP_DIR/fingerprint-tmp"
mkdir -p "$TMP_ENV_DIR"
export TMPDIR="$TMP_ENV_DIR"
FP_ENV='not-json'
export FP_ENV
if safe_config_fingerprint app >/dev/null 2>&1; then
  printf 'parser failure was accepted\n' >&2
  exit 1
fi
if compgen -G "$TMP_ENV_DIR/private-chat-fingerprint.*" >/dev/null; then
  printf 'parser failure leaked a raw fingerprint temp directory\n' >&2
  exit 1
fi

cat > "$TMP_DIR/python3" <<'PYTHON'
#!/usr/bin/env bash
exit 1
PYTHON
chmod +x "$TMP_DIR/python3"
PATH="$TMP_DIR:$PATH" FP_ENV='["KEY=value"]' safe_config_fingerprint app >/dev/null 2>&1 && {
  printf 'hash/parser command failure was accepted\n' >&2
  exit 1
}
if compgen -G "$TMP_ENV_DIR/private-chat-fingerprint.*" >/dev/null; then
  printf 'hash/parser failure leaked a raw fingerprint temp directory\n' >&2
  exit 1
fi
rm -f "$TMP_DIR/python3"
PATH="$TMP_DIR:$ORIGINAL_PATH"
unset TMPDIR

sentinel='private-chat-fingerprint-xtrace-sentinel'
FP_ENV="[\"A=$sentinel\"]" bash -x -c 'source "$1"; safe_config_fingerprint app' bash "$TMP_DIR/functions.sh" \
  >"$TMP_DIR/output" 2>"$TMP_DIR/trace"
if grep -Fq "$sentinel" "$TMP_DIR/output" "$TMP_DIR/trace"; then
  printf 'environment value leaked under bash -x\n' >&2
  exit 1
fi

# URL and Vault values are preserved only through key names and a value-hiding
# fingerprint; neither value may be emitted in a receipt or diagnostic.
# shellcheck disable=SC2089,SC2090
FP_ENV='["SITE_URL=https://site.example.test","SUPABASE_URL=http://kong:8000","SUPABASE_PUBLIC_URL=https://public.example.test","API_EXTERNAL_URL=https://api.example.test","SERVICE_BASE_URL=https://service.example.test","WS_BASE_URL=wss://ws.example.test","CORS_ALLOW_ORIGIN=https://site.example.test","DATABASE_URL=postgresql://user:password@db/app","NPM_API_URL=http://npm:81","UPSTREAM_URL=http://upstream:9000","INTERNAL_API_URL=http://internal.example.test","PUBLIC_URL=https://public-url.example.test","AUTH_URL=https://auth.example.test","REDIRECT_URL=https://redirect.example.test","VAULT_ENC_KEY=vault-secret-sentinel","OTHER=value"]'
# shellcheck disable=SC2090
export FP_ENV
protected_keys="$(protected_config_keys app)"
[[ "$protected_keys" == $'API_EXTERNAL_URL\nAUTH_URL\nCORS_ALLOW_ORIGIN\nDATABASE_URL\nINTERNAL_API_URL\nNPM_API_URL\nPUBLIC_URL\nREDIRECT_URL\nSERVICE_BASE_URL\nSITE_URL\nSUPABASE_PUBLIC_URL\nSUPABASE_URL\nUPSTREAM_URL\nVAULT_ENC_KEY\nWS_BASE_URL' ]] || {
  printf 'public/internal URL and Vault key selection changed\n' >&2
  exit 1
}
protected_fingerprint="$(protected_config_fingerprint app)"
[[ "$protected_fingerprint" =~ ^[a-f0-9]{64}$ ]] || {
  printf 'protected configuration fingerprint is not a SHA-256 value\n' >&2
  exit 1
}
if printf '%s\n' "$protected_keys" "$protected_fingerprint" | grep -Fq 'vault-secret-sentinel'; then
  printf 'protected configuration value leaked\n' >&2
  exit 1
fi
# shellcheck disable=SC2089,SC2090
FP_ENV='["SITE_URL=https://changed.example.test","SUPABASE_URL=http://kong:8000","SUPABASE_PUBLIC_URL=https://public.example.test","API_EXTERNAL_URL=https://api.example.test","SERVICE_BASE_URL=https://service.example.test","WS_BASE_URL=wss://ws.example.test","CORS_ALLOW_ORIGIN=https://site.example.test","DATABASE_URL=postgresql://user:password@db/app","NPM_API_URL=http://npm:81","UPSTREAM_URL=http://upstream:9000","INTERNAL_API_URL=http://internal.example.test","PUBLIC_URL=https://public-url.example.test","AUTH_URL=https://auth.example.test","REDIRECT_URL=https://redirect.example.test","VAULT_ENC_KEY=vault-secret-sentinel","OTHER=value"]'
# shellcheck disable=SC2090
export FP_ENV
changed_fingerprint="$(protected_config_fingerprint app)"
[[ "$changed_fingerprint" != "$protected_fingerprint" ]] || {
  printf 'non-empty URL mutation did not change the protected fingerprint\n' >&2
  exit 1
}

for mutation_key in PUBLIC_URL AUTH_URL REDIRECT_URL; do
  FP_ENV="$(printf '%s' '["SITE_URL=https://site.example.test","PUBLIC_URL=https://public-url.example.test","AUTH_URL=https://auth.example.test","REDIRECT_URL=https://redirect.example.test"]')"
  export FP_ENV
  before_mutation="$(protected_config_fingerprint app)"
  FP_ENV="$(printf '%s' '["SITE_URL=https://site.example.test","PUBLIC_URL=https://public-url.example.test","AUTH_URL=https://auth.example.test","REDIRECT_URL=https://redirect.example.test"]')"
  case "$mutation_key" in
    PUBLIC_URL) FP_ENV="$(printf '%s' '["SITE_URL=https://site.example.test","PUBLIC_URL=https://changed-public.example.test","AUTH_URL=https://auth.example.test","REDIRECT_URL=https://redirect.example.test"]')" ;;
    AUTH_URL) FP_ENV="$(printf '%s' '["SITE_URL=https://site.example.test","PUBLIC_URL=https://public-url.example.test","AUTH_URL=https://changed-auth.example.test","REDIRECT_URL=https://redirect.example.test"]')" ;;
    REDIRECT_URL) FP_ENV="$(printf '%s' '["SITE_URL=https://site.example.test","PUBLIC_URL=https://public-url.example.test","AUTH_URL=https://auth.example.test","REDIRECT_URL=https://changed-redirect.example.test"]')" ;;
  esac
  export FP_ENV
  [[ "$(protected_config_fingerprint app)" != "$before_mutation" ]] || { printf '%s mutation was not fingerprinted\n' "$mutation_key" >&2; exit 1; }
done

printf 'private-chat lossless fingerprint tests passed\n'
