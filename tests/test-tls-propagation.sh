#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

source "$ROOT_DIR/utils/public-url-propagation.sh"
export ROOT_DIR
[[ "$(sql_string_literal "https://example.test/a'b")" == "'https://example.test/a''b'" ]]

# Rollback PUTs use the projection, never GET metadata or runtime fields.
# shellcheck disable=SC1091
NPM_ADMIN_EMAIL=test@example.test NPM_ADMIN_PASS=redacted-secret \
  source "$ROOT_DIR/utils/npm_ssl_bootstrap.sh"
state='{"id":7,"created_on":"now","modified_on":"later","domain_names":["api.example.test"],"forward_scheme":"http","forward_host":"api","forward_port":5002,"certificate_id":2,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":true,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[],"runtime_only":"reject"}'
projected="$(proxy_host_mutable_payload "$state")"
for forbidden_key in id created_on modified_on runtime_only; do
  if jq -e --arg key "$forbidden_key" 'has($key)' <<<"$projected" >/dev/null; then exit 1; fi
done
for accepted_key in certificate_id access_list_id; do
  jq -e --arg key "$accepted_key" 'has($key)' <<<"$projected" >/dev/null
done
[[ "$(jq 'keys | length' <<<"$projected")" == 17 ]]
if proxy_host_mutable_payload '{"id":7}' >/dev/null 2>&1; then
  printf 'Projection must fail closed when mutable fields are missing\n' >&2
  exit 1
fi

# Public classification excludes internal URLs and rewrites nip.io only after
# the caller has established complete TLS success.
public_url_key SUPABASE_PUBLIC_URL
public_url_key API_EXTERNAL_URL
if public_url_key POSTGRES_URL; then exit 1; fi
if public_url_key NPM_API_URL; then exit 1; fi
BASE_DOMAIN=192.168.0.19.nip.io
[[ "$(public_url_scheme)" == http ]]
[[ "$(public_url_value_for_key SITE_URL)" == http://daiana.192.168.0.19.nip.io ]]
[[ "$(public_url_value_for_key SITE_URL https)" == https://daiana.192.168.0.19.nip.io ]]

cat > "$TMP_DIR/.env" <<'ENV'
SUPABASE_PUBLIC_URL=http://supa.192.168.0.19.nip.io
API_EXTERNAL_URL=http://supa.192.168.0.19.nip.io/auth/v1
SITE_URL=http://daiana.192.168.0.19.nip.io
BACKEND_BASE_URL=http://api.192.168.0.19.nip.io
STUDIO_BASE_URL=http://studio.192.168.0.19.nip.io
WEBUI_BASE_URL=http://webui.192.168.0.19.nip.io
WS_BASE_URL=http://whatsapp.192.168.0.19.nip.io
MS_BASE_URL=http://msteams.192.168.0.19.nip.io
VANNA_BASE_URL=http://vanna.192.168.0.19.nip.io
QDRANT_BASE_URL=http://qdrant.192.168.0.19.nip.io
CORS_ALLOW_ORIGIN=http://daiana.192.168.0.19.nip.io
NEXT_PUBLIC_APP_URL=http://daiana.192.168.0.19.nip.io
INTERNAL_API_URL=http://daiana-python:5002
ENV
export STUDIO_BASE_URL=https://studio.192.168.0.19.nip.io
export SUPABASE_PUBLIC_URL=https://supa.192.168.0.19.nip.io
export API_EXTERNAL_URL=https://supa.192.168.0.19.nip.io/auth/v1
export SITE_URL=https://daiana.192.168.0.19.nip.io
export WEBUI_BASE_URL=https://webui.192.168.0.19.nip.io
export BACKEND_BASE_URL=https://api.192.168.0.19.nip.io
export WS_BASE_URL=https://whatsapp.192.168.0.19.nip.io
export MS_BASE_URL=https://msteams.192.168.0.19.nip.io
export VANNA_BASE_URL=https://vanna.192.168.0.19.nip.io
export QDRANT_BASE_URL=https://qdrant.192.168.0.19.nip.io
export CORS_ALLOW_ORIGIN=https://daiana.192.168.0.19.nip.io
export NEXT_PUBLIC_APP_URL=https://daiana.192.168.0.19.nip.io
rewrite_public_urls_in_env "$TMP_DIR/.env"
grep -q '^SUPABASE_PUBLIC_URL=http://' "$TMP_DIR/.env"
grep -q '^API_EXTERNAL_URL=http://' "$TMP_DIR/.env"
grep -q '^BACKEND_BASE_URL=http://' "$TMP_DIR/.env"
grep -q '^INTERNAL_API_URL=http://daiana-python:5002$' "$TMP_DIR/.env"

# Public assignments are atomic inputs: comments are harmless, but duplicate,
# conflicting, and malformed occurrences are never resolved by first/last wins.
cp "$TMP_DIR/.env" "$TMP_DIR/.env.duplicates"
printf '# SITE_URL=https://comment.example.test\nSITE_URL=https://daiana.192.168.0.19.nip.io\n' >> "$TMP_DIR/.env.duplicates"
if validate_public_env_file "$TMP_DIR/.env.duplicates"; then exit 1; fi
cp "$TMP_DIR/.env" "$TMP_DIR/.env.conflict"
printf 'SITE_URL=https://other.example.test\n' >> "$TMP_DIR/.env.conflict"
if validate_public_source_env_file "$TMP_DIR/.env.conflict"; then exit 1; fi
cp "$TMP_DIR/.env" "$TMP_DIR/.env.malformed"
printf 'SITE_URL\n' >> "$TMP_DIR/.env.malformed"
if validate_public_source_env_file "$TMP_DIR/.env.malformed"; then exit 1; fi

# Vault uses the existing upsert function and receives only HTTPS public
# values; the mock emits no secret values and the assertion checks key/scheme
# behavior from the redacted command record.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/docker" <<'MOCK'
#!/usr/bin/env bash
for expected in compose --project-name daiana-app --project-directory "$ROOT_DIR" \
  -f "$ROOT_DIR/docker-compose.yml" -f "$ROOT_DIR/docker-compose.app.yml" exec -T db sh -c; do
  [[ "${1:-}" == "$expected" ]] || {
    printf 'Vault SQL must target the daiana-app Compose db service with explicit project files\n' >&2
    exit 97
  }
  shift
done
IFS= read -r _password || exit 99
sql=''
shift 2
while (($#)); do
  case "$1" in
    -v)
      assignment="${2:-}"
      parameter="${assignment%%=*}"
      value="${assignment#*=}"
      [[ "$parameter=$value" == ON_ERROR_STOP=1 ]] || exit 110
      shift 2
      ;;
    -c)
      sql="${2:-}"
      shift 2
      ;;
    *) shift ;;
  esac
done
[[ -n "$sql" ]] || exit 100
printf '%s\n' "$sql" > "${VAULT_MOCK_LOG:?}"
[[ "$sql" != *'$('* ]] || exit 102
[[ "$sql" == *"WITH expected(name, value) AS (VALUES"* ]] || exit 103
[[ "$sql" == *"actual(name, value) AS"* ]] || exit 104
[[ "$sql" == *"count(*) FROM actual) <> 9"* ]] || exit 105
[[ "$sql" == *"count(*) FROM expected e JOIN actual a USING (name, value)) <> 9"* ]] || exit 106
[[ "$sql" == *"DO \$\$"* ]] || exit 112
[[ "$sql" == *"RAISE EXCEPTION"* ]] || exit 113
[[ "$sql" != *"ELSE 1 / 0"* ]] || exit 114
[[ "$sql" == *"http://supa.192.168.0.19.nip.io"* ]] || exit 115
[[ "$sql" != *":'public_"* ]] || exit 118
[[ "$sql" == BEGIN\;* ]] || exit 116
[[ "$sql" == *COMMIT\; ]] || exit 117
[[ "$sql" == *"SELECT public.vault_upsert_secret"* ]] || exit 108
[[ "${sql//SELECT public.vault_upsert_secret/}" != "$sql" ]] || exit 109
MOCK
chmod +x "$TMP_DIR/bin/docker"
cat > "$TMP_DIR/bin/psql" <<'PSQL'
#!/usr/bin/env bash
set -euo pipefail
sql=''
while (($#)); do
  case "$1" in
    -c) sql="${2:-}"; shift 2 ;;
    -v) shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$sql" ]]; then
  [[ "$sql" != *':test'* ]] && exit 0
  exit 2
fi
IFS= read -r sql
[[ "$sql" == 'select :test' ]]
PSQL
chmod +x "$TMP_DIR/bin/psql"
export PATH="$TMP_DIR/bin:$PATH" VAULT_MOCK_LOG="$TMP_DIR/vault.args"
# Regression fixture: psql expands variables from stdin, but not in -c SQL.
if psql -v test=ok -c 'select :test'; then exit 1; fi
printf '%s\n' 'select :test' | psql -v test=ok
BASE_DOMAIN=192.168.0.19.nip.io
export SUPABASE_PUBLIC_URL=http://supa.192.168.0.19.nip.io
export BACKEND_BASE_URL=http://api.192.168.0.19.nip.io
export VANNA_BASE_URL=http://vanna.192.168.0.19.nip.io
export QDRANT_BASE_URL=http://qdrant.192.168.0.19.nip.io
export MS_BASE_URL=http://msteams.192.168.0.19.nip.io
export WS_BASE_URL=http://whatsapp.192.168.0.19.nip.io
export STUDIO_BASE_URL=http://studio.192.168.0.19.nip.io
export WEBUI_BASE_URL=http://webui.192.168.0.19.nip.io
export NEXT_PUBLIC_APP_URL=http://daiana.192.168.0.19.nip.io
POSTGRES_PASSWORD=redacted-secret
unset DAIANA_COMPOSE_PROJECT_NAME
vault_output="$(vault_upsert_public_url_entries "$TMP_DIR/.env" http 2>&1)"
[[ -z "$vault_output" ]]
grep -q 'NEXT_PUBLIC_SUPABASE_URL' "$TMP_DIR/vault.args"
grep -q "'http://supa.192.168.0.19.nip.io'" "$TMP_DIR/vault.args"
if grep -q "public_supabase_url" "$TMP_DIR/vault.args"; then exit 1; fi
if grep -q 'supabase-db' "$TMP_DIR/vault.args"; then exit 1; fi
if grep -q 'https://supa.192.168.0.19.nip.io' "$TMP_DIR/vault.args"; then exit 1; fi
if grep -q 'redacted-secret' "$TMP_DIR/vault.args"; then exit 1; fi
if grep -q 'redacted-secret' <<<"$vault_output"; then exit 1; fi
if grep -q 'PGPASSWORD.*POSTGRES_PASSWORD' "$ROOT_DIR/utils/public-url-propagation.sh"; then
  printf 'Vault password must not be constructed in docker argv\n' >&2
  exit 1
fi

# The installer-managed Compose project is fixed by repository convention; a
# mismatched environment value must fail before Docker or Vault is reached.
export DAIANA_COMPOSE_PROJECT_NAME=unsafe-project
if vault_upsert_public_url_entries "$TMP_DIR/.env" http; then
  printf 'Unsafe Compose project override must fail closed\n' >&2
  exit 1
fi
unset DAIANA_COMPOSE_PROJECT_NAME

# Ambiguous derivation fails before any rewrite; failed/partial TLS callers are
# represented by the apply-certs guard and must not invoke this helper.
BASE_DOMAIN='bad domain'
cp "$TMP_DIR/.env" "$TMP_DIR/.env.before-invalid"
VAULT_INVOCATIONS=0
vault_psql_with_password() {
  VAULT_INVOCATIONS=$((VAULT_INVOCATIONS + 1))
  return 99
}
if validate_public_url_set; then
  printf 'Invalid BASE_DOMAIN must fail public URL validation\n' >&2
  exit 1
fi
if rewrite_public_urls_in_env "$TMP_DIR/.env"; then
  printf 'Ambiguous public URL derivation must fail closed\n' >&2
  exit 1
fi
if vault_upsert_public_url_entries "$TMP_DIR/.env" http; then
  printf 'Invalid BASE_DOMAIN must not reach Vault\n' >&2
  exit 1
fi
[[ "$VAULT_INVOCATIONS" == 0 ]]
cmp -s "$TMP_DIR/.env.before-invalid" "$TMP_DIR/.env"

BASE_DOMAIN=192.168.0.19.nip.io
export SITE_URL=https://conflicting.example.test
if validate_public_url_set; then
  printf 'Conflicting derived public URL must fail closed\n' >&2
  exit 1
fi
if vault_upsert_public_url_entries "$TMP_DIR/.env" http; then
  printf 'Conflicting public URL must not reach Vault\n' >&2
  exit 1
fi
[[ "$VAULT_INVOCATIONS" == 0 ]]
cmp -s "$TMP_DIR/.env.before-invalid" "$TMP_DIR/.env"

export SITE_URL=https://daiana.192.168.0.19.nip.io
unset QDRANT_BASE_URL
if validate_public_url_set; then
  printf 'Missing derived public URL must fail closed\n' >&2
  exit 1
fi
if vault_upsert_public_url_entries "$TMP_DIR/.env" http; then
  printf 'Missing public URL must not reach Vault\n' >&2
  exit 1
fi
[[ "$VAULT_INVOCATIONS" == 0 ]]
cmp -s "$TMP_DIR/.env.before-invalid" "$TMP_DIR/.env"

sed 's#^API_EXTERNAL_URL=.*#API_EXTERNAL_URL=https://supa.192.168.0.19.nip.io/invalid path#' \
  "$TMP_DIR/.env.before-invalid" > "$TMP_DIR/.env.invalid-path"
mv "$TMP_DIR/.env.invalid-path" "$TMP_DIR/.env"
if vault_upsert_public_url_entries "$TMP_DIR/.env" http; then
  printf 'Invalid URL path must not reach Vault\n' >&2
  exit 1
fi
[[ "$VAULT_INVOCATIONS" == 0 ]]
cp "$TMP_DIR/.env.before-invalid" "$TMP_DIR/.env"

# Exercise snapshot -> restore -> reread/verify with a disposable in-process
# Vault/psql mock.  The mock persists only nine redacted key/value rows.
MOCK_DB_FILE="$TMP_DIR/vault.db"
cat > "$MOCK_DB_FILE" <<'HTTP_STATE'
NEXT_PUBLIC_SUPABASE_URL	http://supa.192.168.0.19.nip.io
NEXT_PUBLIC_API_PYTHON	http://api.192.168.0.19.nip.io
NEXT_PUBLIC_API_TRAINING	http://vanna.192.168.0.19.nip.io
NEXT_PUBLIC_API_QDRANT	http://qdrant.192.168.0.19.nip.io
NEXT_PUBLIC_API_MSTEAMS	http://msteams.192.168.0.19.nip.io
NEXT_PUBLIC_API_WHATSAPP	http://whatsapp.192.168.0.19.nip.io
NEXT_PUBLIC_API_STUDIO_BASE_URL	http://studio.192.168.0.19.nip.io
NEXT_PUBLIC_WEBUI_URL	http://webui.192.168.0.19.nip.io
NEXT_PUBLIC_APP_URL	http://daiana.192.168.0.19.nip.io
HTTP_STATE

vault_psql_with_password() {
  local sql='' assignment parameter value name parsed_value
  while (($#)); do
    case "$1" in
      -Atqc) printf '%s\n' "$(<"$MOCK_DB_FILE")"; return 0 ;;
      -c) sql="$2"; shift 2 ;;
      -v)
        assignment="$2"; parameter="${assignment%%=*}"; value="${assignment#*=}"
        [[ "$parameter=$value" == ON_ERROR_STOP=1 ]] || return 1
        shift 2 ;;
      *) shift ;;
    esac
  done
  [[ "$sql" == BEGIN\;* && "$sql" == *$'\n'COMMIT\; ]]
  [[ "$sql" == *'DO $$'* && "$sql" == *'RAISE EXCEPTION'* ]]
  if [[ "$sql" == *"vault_upsert_secret"* ]]; then
    : > "$MOCK_DB_FILE"
    while IFS=$'\t' read -r name parsed_value; do
      [[ -n "$name" && -n "$parsed_value" ]] || continue
      printf '%s\t%s\n' "$name" "$parsed_value" >> "$MOCK_DB_FILE"
    done < <(printf '%s\n' "$sql" | sed -nE "s/.*vault_upsert_secret\\('([^']*)', '([^']*)'.*/\\2\\t\\1/p")
  else
    local actual expected
    while IFS=$'\t' read -r name expected; do
      [[ -n "$name" && -n "$expected" ]] || continue
      actual="$(awk -F '\t' -v key="$name" '$1 == key { print $2 }' "$MOCK_DB_FILE")"
      [[ -n "$actual" && "$actual" == "$expected" ]] || return 1
    done < <(printf '%s\n' "$sql" | sed -nE "s/.*\\('([^']*)', '([^']*)'\\).*/\\1\\t\\2/p")
  fi
}

snapshot_http="$TMP_DIR/vault-http.snapshot"
vault_snapshot_public_url_entries "$snapshot_http"
vault_restore_public_url_entries "$snapshot_http"
vault_verify_public_url_entries "$snapshot_http" http

sed 's#http://supa.192.168.0.19.nip.io#http://supa.other.example.test#' \
  "$snapshot_http" > "$TMP_DIR/vault-other-domain.snapshot"
if vault_snapshot_public_url_scheme "$TMP_DIR/vault-other-domain.snapshot"; then exit 1; fi
sed 's#http://api.192.168.0.19.nip.io#https://api.192.168.0.19.nip.io#' \
  "$snapshot_http" > "$TMP_DIR/vault-mixed.snapshot"
if vault_snapshot_public_url_scheme "$TMP_DIR/vault-mixed.snapshot"; then exit 1; fi

sed 's#http://#https://#' "$snapshot_http" > "$TMP_DIR/vault-https.snapshot"
vault_restore_public_url_entries "$TMP_DIR/vault-https.snapshot"
vault_verify_public_url_entries "$TMP_DIR/vault-https.snapshot" https
if vault_verify_public_url_entries "$TMP_DIR/vault-https.snapshot" http; then
  printf 'HTTPS state must not verify as HTTP\n' >&2
  exit 1
fi
if vault_verify_public_url_entries "$snapshot_http" https; then
  printf 'HTTP state must not verify as HTTPS\n' >&2
  exit 1
fi
if vault_verify_public_url_entries "$TMP_DIR/vault-https.snapshot"; then
  printf 'Verification must require an explicit scheme\n' >&2
  exit 1
fi
cp "$MOCK_DB_FILE" "$TMP_DIR/vault-before-mismatch"
sed 's#NEXT_PUBLIC_APP_URL\thttps://daiana#NEXT_PUBLIC_APP_URL\thttps://wrong#' \
  "$MOCK_DB_FILE" > "$TMP_DIR/vault-mismatch.db"
mv "$TMP_DIR/vault-mismatch.db" "$MOCK_DB_FILE"
if vault_verify_public_url_entries "$TMP_DIR/vault-https.snapshot" https; then
  printf 'Mismatched Vault state must fail verification\n' >&2
  exit 1
fi
cp "$TMP_DIR/vault-before-mismatch" "$MOCK_DB_FILE"
sed '$d' "$TMP_DIR/vault-https.snapshot" > "$TMP_DIR/vault-missing.snapshot"
if vault_restore_public_url_entries "$TMP_DIR/vault-missing.snapshot"; then
  printf 'Missing snapshot entry must fail restoration\n' >&2
  exit 1
fi

# Compensation restores the pre-TLS HTTP snapshot after a failed forward
# update, and refuses to claim success when its reread does not match.
cp "$TMP_DIR/vault-https.snapshot" "$MOCK_DB_FILE"
vault_restore_public_url_entries "$snapshot_http"
vault_verify_public_url_entries "$snapshot_http" http
cmp -s "$snapshot_http" "$MOCK_DB_FILE"

grep -q 'ONLY_PREFIX:-.*TLS_MODE.*none' "$ROOT_DIR/apply-certs.sh"
grep -q 'vault_upsert_public_url_entries' "$ROOT_DIR/apply-certs.sh"
grep -q 'vault_verify_public_url_entries' "$ROOT_DIR/apply-certs.sh"
grep -q 'NEXT_PUBLIC_SUPABASE_URL' "$ROOT_DIR/utils/public-url-propagation.sh"
printf 'TLS propagation tests passed (Vault values redacted)\n'
