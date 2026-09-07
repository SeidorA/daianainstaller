#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

NAMES=(
  NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_API_PYTHON NEXT_PUBLIC_API_TRAINING
  NEXT_PUBLIC_API_QDRANT NEXT_PUBLIC_API_MSTEAMS NEXT_PUBLIC_API_WHATSAPP
  NEXT_PUBLIC_API_STUDIO_BASE_URL NEXT_PUBLIC_WEBUI_URL NEXT_PUBLIC_APP_URL
)

test_daiana_host() {
  local domain="$1"
  if [[ "$domain" == *.nip.io || "$domain" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    printf 'daiana.%s' "$domain"
  else
    printf '%s' "$domain"
  fi
}

write_env() {
  local scheme="$1" file="$2" domain="${3:-example.test}" daiana_host
  daiana_host="$(test_daiana_host "$domain")"
  cat > "$file" <<ENV
BASE_DOMAIN=$domain
NPM_ADMIN_EMAIL=test@example.test
NPM_ADMIN_PASS=redacted-secret
STUDIO_BASE_URL=${scheme}://studio.$domain
SUPABASE_PUBLIC_URL=${scheme}://supa.$domain
API_EXTERNAL_URL=${scheme}://supa.$domain/auth/v1
SITE_URL=${scheme}://$daiana_host
WEBUI_BASE_URL=${scheme}://webui.$domain
BACKEND_BASE_URL=${scheme}://api.$domain
WS_BASE_URL=${scheme}://whatsapp.$domain
MS_BASE_URL=${scheme}://msteams.$domain
VANNA_BASE_URL=${scheme}://vanna.$domain
QDRANT_BASE_URL=${scheme}://qdrant.$domain
CORS_ALLOW_ORIGIN=${scheme}://$daiana_host
NEXT_PUBLIC_APP_URL=${scheme}://$daiana_host
INTERNAL_API_URL=http://daiana-python:5002
ENV
}

write_vault() {
  local scheme="$1" file="$2" domain="${3:-example.test}"
  local name host daiana_host
  daiana_host="$(test_daiana_host "$domain")"
  : > "$file"
  for name in "${NAMES[@]}"; do
    case "$name" in
      NEXT_PUBLIC_SUPABASE_URL) host=supa.$domain ;;
      NEXT_PUBLIC_API_PYTHON) host=api.$domain ;;
      NEXT_PUBLIC_API_TRAINING) host=vanna.$domain ;;
      NEXT_PUBLIC_API_QDRANT) host=qdrant.$domain ;;
      NEXT_PUBLIC_API_MSTEAMS) host=msteams.$domain ;;
      NEXT_PUBLIC_API_WHATSAPP) host=whatsapp.$domain ;;
      NEXT_PUBLIC_API_STUDIO_BASE_URL) host=studio.$domain ;;
      NEXT_PUBLIC_WEBUI_URL) host=webui.$domain ;;
      NEXT_PUBLIC_APP_URL) host="$daiana_host" ;;
    esac
    printf '%s\t%s://%s\n' "$name" "$scheme" "$host" >> "$file"
  done
}

mkdir -p "$TMP_DIR/utils" "$TMP_DIR/bin"
cp "$ROOT_DIR/apply-certs.sh" "$TMP_DIR/apply-certs.sh"
cp "$ROOT_DIR/utils/public-url-propagation.sh" "$TMP_DIR/utils/public-url-propagation.sh"
cp "$ROOT_DIR/utils/certificate-validation.sh" "$TMP_DIR/utils/certificate-validation.sh"
cat > "$TMP_DIR/utils/npm_ssl_bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certificate-validation.sh"

services=(api nginx port qdrant daiana studio supa whatsapp vanna webui msteams)
selected=()
for prefix in "${services[@]}"; do
  if [[ -z "${ONLY_PREFIX:-}" || "$ONLY_PREFIX" == "$prefix" ]]; then
    selected+=("$prefix")
  fi
done
[[ -n "${ONLY_PREFIX:-}" && ${#selected[@]} -eq 0 ]] && exit 31
[[ -f "${NPM_LOCAL_CERT_FILE/#~/$HOME}" ]] || exit 32
for prefix in "${selected[@]}"; do
  if [[ "$prefix" == daiana ]]; then
    if [[ "$BASE_DOMAIN" == *.nip.io || "$BASE_DOMAIN" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      domain="daiana.$BASE_DOMAIN"
    else
      domain="$BASE_DOMAIN"
    fi
  else
    domain="$prefix.$BASE_DOMAIN"
  fi
  if [[ "${TLS_MOCK_FAIL_PREFIX:-}" == "$prefix" ]]; then
    printf 'TLS_MOCK prefix=%s result=failed reason=handshake\n' "$prefix" >> "${TLS_MOCK_LOG:?}"
    exit 33
  fi
  certificate_hostname_matches "${NPM_LOCAL_CERT_FILE/#~/$HOME}" "$domain" || exit 34
  printf 'TLS_MOCK prefix=%s domain=%s san=%s handshake=secure\n' "$prefix" "$domain" \
    "${TLS_MOCK_CERT_SAN:?}" >> "${TLS_MOCK_LOG:?}"
done
printf 'TLS_MOCK_RESULT=SUCCESS\n' >> "${TLS_MOCK_LOG:?}"
exit 0
BOOTSTRAP
chmod +x "$TMP_DIR/utils/npm_ssl_bootstrap.sh"

cat > "$TMP_DIR/update-daiana.sh" <<'UPDATE'
#!/usr/bin/env bash
: > update-called
exit "${UPDATE_STATUS:-0}"
UPDATE
chmod +x "$TMP_DIR/update-daiana.sh"

cat > "$TMP_DIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
NAMES=(
  NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_API_PYTHON NEXT_PUBLIC_API_TRAINING
  NEXT_PUBLIC_API_QDRANT NEXT_PUBLIC_API_MSTEAMS NEXT_PUBLIC_API_WHATSAPP
  NEXT_PUBLIC_API_STUDIO_BASE_URL NEXT_PUBLIC_WEBUI_URL NEXT_PUBLIC_APP_URL
)
[[ "${1:-}" == compose && "${2:-}" == --project-name && "${3:-}" == daiana-app ]] || exit 90
[[ "${4:-}" == --project-directory && "${6:-}" == -f ]] || exit 91
[[ "${8:-}" == -f && "${10:-}" == exec && "${11:-}" == -T && "${12:-}" == db ]] || exit 92
[[ "${13:-}" == sh && "${14:-}" == -c ]] || exit 93
IFS= read -r _password
shift 15
sql=''
value_keys=()
while (($#)); do
  case "$1" in
    -v)
      shift 2
      ;;
    -Atqc)
      printf '%s\n' "$(<"${VAULT_DB_FILE:?}")"
      exit 0
      ;;
    -c) sql="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ "$sql" == *"vault_upsert_secret"* && "${VAULT_FAIL_MODE:-}" == forward ]]; then
  exit 42
fi
if [[ "$sql" == *"vault_upsert_secret"* && "$sql" != *"WITH expected"* ]]; then
  : > "$VAULT_DB_FILE"
  printf '%s\n' "$sql" | sed -nE "s/.*vault_upsert_secret\\('([^']*)', '([^']*)'.*/\\2\\t\\1/p" >> "$VAULT_DB_FILE"
  [[ "$(wc -l < "$VAULT_DB_FILE" | tr -d ' ')" == 9 ]] || exit 43
  exit 0
fi
if [[ "$sql" == *"WITH expected"* && "$sql" != *"vault_upsert_secret"* ]]; then
  [[ "${VAULT_REREAD_FAIL:-0}" == 1 ]] && exit 43
  while IFS=$'\t' read -r name expected; do
    [[ -n "$name" && -n "$expected" ]] || continue
    actual="$(awk -F '\t' -v key="$name" '$1 == key { print $2 }' "$VAULT_DB_FILE")"
    [[ "$actual" == "$expected" ]] || exit 43
  done < <(printf '%s\n' "$sql" | sed -nE "s/.*\\('([^']*)', '([^']*)'\\).*/\\1\\t\\2/p")
  exit 0
fi
if [[ "$sql" == *"vault_upsert_secret"* ]]; then
  : > "$VAULT_DB_FILE"
  printf '%s\n' "$sql" | sed -nE "s/.*vault_upsert_secret\\('([^']*)', '([^']*)'.*/\\2\\t\\1/p" >> "$VAULT_DB_FILE"
  [[ "$(wc -l < "$VAULT_DB_FILE" | tr -d ' ')" == 9 ]] || exit 92
  exit 0
fi
exit 92
DOCKER
chmod +x "$TMP_DIR/bin/docker"
cat > "$TMP_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
config=''
while (($#)); do
  case "$1" in
    --config) config="$2"; shift 2 ;;
    -w) shift 2 ;;
    *) shift ;;
  esac
done
request="$(awk -F '"' '$1 == "request = " { print $2 }' "$config")"
url="$(awk -F '"' '$1 == "url = " { print $2 }' "$config")"
data_file="$(awk -F '"' '$1 == "data-binary = " { print $2 }' "$config")"
data_file="${data_file#@}"
case "$request $url" in
  "POST http://127.0.0.1:9000/api/auth")
    printf '{"jwt":"controlled-refresh-token"}\n200'
    ;;
  "GET http://127.0.0.1:9000/api/endpoints")
    printf '[{"Id":1,"Name":"local-docker","URL":"unix:///var/run/docker.sock"}]\n200'
    ;;
  "GET http://127.0.0.1:9000/api/stacks")
    printf '[{"Id":7,"Name":"daiana-app"}]\n200'
    ;;
  "GET http://127.0.0.1:9000/api/stacks/7/file?endpointId=1")
    printf '{"StackFileContent":"services:\\n  app:\\n    image: example/daiana:existing\\n"}\n200'
    ;;
  "GET http://127.0.0.1:9000/api/stacks/7?endpointId=1")
    printf '{"Env":[{"name":"SITE_URL","value":"http://daiana.example.test"},{"name":"SUPABASE_PUBLIC_URL","value":"http://supa.example.test"},{"name":"IMAGE_TAG","value":"existing"}]}\n200'
    ;;
  "PUT http://127.0.0.1:9000/api/stacks/7?endpointId=1")
    cp "$data_file" "${PORTAINER_PUT_BODY:-/dev/null}"
    expected_site="https://$BASE_DOMAIN"
    if [[ "$BASE_DOMAIN" == *.nip.io || "$BASE_DOMAIN" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
      expected_site="https://daiana.$BASE_DOMAIN"
    fi
    expected_supa="https://supa.$BASE_DOMAIN"
    jq -e --arg site "$expected_site" --arg supa "$expected_supa" '.PullImage == false and .Prune == false and (.StackFileContent | test("image: example/daiana:existing")) and (.Env | any(.[]; .name == "SITE_URL" and .value == $site)) and (.Env | any(.[]; .name == "SUPABASE_PUBLIC_URL" and .value == $supa))' "$data_file" >/dev/null || { cat "$data_file" >&2; exit 92; }
    if [[ "${UPDATE_STATUS:-0}" != 0 ]]; then
      printf '{}\n500'
    else
      printf '{}\n200'
    fi
    ;;
  *)
    printf 'unexpected Portainer request: %s %s\n' "$request" "$url" >&2
    exit 91
    ;;
esac
CURL
chmod +x "$TMP_DIR/bin/curl"
OPENSSL_REAL="$(command -v openssl)"
export OPENSSL_REAL
cat > "$TMP_DIR/bin/openssl" <<'MOCK_OPENSSL'
#!/usr/bin/env bash
if [[ "${1:-}" == x509 && "${2:-}" == -help ]]; then
  printf '%s\n' ' -checkhost hostname'
  exit 0
fi
if [[ " $* " == *' -checkhost '* ]]; then
  exit 0
fi
exec "${OPENSSL_REAL:?}" "$@"
MOCK_OPENSSL
chmod +x "$TMP_DIR/bin/openssl"

assert_vault_exact() {
  local scheme="$1" file="$2" domain="${3:-example.test}" name host expected
  [[ "$(wc -l < "$file" | tr -d ' ')" == 9 ]] || exit 1
  for name in "${NAMES[@]}"; do
    case "$name" in
      NEXT_PUBLIC_SUPABASE_URL) host=supa ;;
      NEXT_PUBLIC_API_PYTHON) host=api ;;
      NEXT_PUBLIC_API_TRAINING) host=vanna ;;
      NEXT_PUBLIC_API_QDRANT) host=qdrant ;;
      NEXT_PUBLIC_API_MSTEAMS) host=msteams ;;
      NEXT_PUBLIC_API_WHATSAPP) host=whatsapp ;;
      NEXT_PUBLIC_API_STUDIO_BASE_URL) host=studio ;;
      NEXT_PUBLIC_WEBUI_URL) host=webui ;;
      NEXT_PUBLIC_APP_URL) host="$(test_daiana_host "$domain")" ;;
    esac
    if [[ "$name" == NEXT_PUBLIC_APP_URL ]]; then
      expected="${scheme}://${host}"
    else
      expected="${scheme}://${host}.${domain}"
    fi
    [[ "$(awk -F '\t' -v key="$name" '$1 == key { print $2 }' "$file")" == "$expected" ]] || exit 1
  done
}

create_test_certificate() {
  local cert_file="$1" key_file="$2" domain="${3:-example.test}" config="$TMP_DIR/cert.cnf" san host
  : > "$config"
  printf '%s\n' '[req]' 'prompt=no' 'distinguished_name=req_dn' 'x509_extensions=req_ext' '[req_dn]' "CN=api.$domain" '[req_ext]' 'subjectAltName=@alt_names' '[alt_names]' >> "$config"
  san=1
  for host in api nginx port qdrant daiana studio supa whatsapp vanna webui msteams; do
    if [[ "$host" == daiana ]]; then
      printf 'DNS.%s=%s\n' "$san" "$(test_daiana_host "$domain")" >> "$config"
    else
      printf 'DNS.%s=%s.%s\n' "$san" "$host" "$domain" >> "$config"
    fi
    san=$((san + 1))
  done
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" \
    -subj "/CN=api.$domain" -config "$config" >/dev/null 2>&1
}

run_success_case() {
  local scheme="$1" domain="${2:-example.test}" case_dir
  case_dir="$TMP_DIR/success-$scheme"
  [[ "$domain" == example.test ]] || case_dir="$TMP_DIR/success-${scheme}-nip"
  mkdir -p "$case_dir"
  write_env "$scheme" "$case_dir/.env" "$domain"
  write_vault "$scheme" "$case_dir/vault.db" "$domain"
  create_test_certificate "$case_dir/cert" "$case_dir/key" "$domain"
  cp "$TMP_DIR/apply-certs.sh" "$case_dir/apply-certs.sh"
  mkdir -p "$case_dir/utils"; cp "$TMP_DIR/utils/public-url-propagation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/certificate-validation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/npm_ssl_bootstrap.sh" "$case_dir/utils/"
  cp "$TMP_DIR/update-daiana.sh" "$case_dir/update-daiana.sh"
  (cd "$case_dir" && PATH="$TMP_DIR/bin:$PATH" VAULT_DB_FILE="$case_dir/vault.db" PORTAINER_PUT_BODY="$case_dir/portainer-put.json" UPDATE_STATUS=0 TLS_MOCK_LOG="$case_dir/tls.log" \
      TLS_MOCK_CERT_SAN='api nginx port qdrant daiana studio supa whatsapp vanna webui msteams' \
      BASE_DOMAIN="$domain" POSTGRES_PASSWORD=redacted-secret NPM_ADMIN_EMAIL=test@example.test NPM_ADMIN_PASS=redacted-secret TLS_MODE=local \
      NPM_LOCAL_CERT_FILE="$case_dir/cert" NPM_LOCAL_KEY_FILE="$case_dir/key" bash ./apply-certs.sh) >"$case_dir/output" 2>&1 || { cat "$case_dir/output" >&2; return 1; }
  assert_vault_exact https "$case_dir/vault.db" "$domain"
  grep -q "^SUPABASE_PUBLIC_URL=https://supa.$domain$" "$case_dir/.env"
  grep -q '^INTERNAL_API_URL=' "$case_dir/.env" && ! grep -q '^INTERNAL_API_URL=https://' "$case_dir/.env"
  grep -q 'handshake=secure' "$case_dir/tls.log"
  [[ ! -f "$case_dir/update-called" ]]
  jq -e '.PullImage == false and .Prune == false' "$case_dir/portainer-put.json" >/dev/null
}

run_case() {
  local scheme="$1" vault_mode="$2" update_status="$3" case_dir
  case_dir="$TMP_DIR/$scheme-$vault_mode-$update_status"
  mkdir -p "$case_dir"
  write_env "$scheme" "$case_dir/.env"
  write_vault "$scheme" "$case_dir/vault.db"
  create_test_certificate "$case_dir/cert" "$case_dir/key"
  cp "$TMP_DIR/apply-certs.sh" "$case_dir/apply-certs.sh"
  mkdir -p "$case_dir/utils"; cp "$TMP_DIR/utils/public-url-propagation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/certificate-validation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/npm_ssl_bootstrap.sh" "$case_dir/utils/"
  cp "$TMP_DIR/update-daiana.sh" "$case_dir/update-daiana.sh"
  if (cd "$case_dir" && PATH="$TMP_DIR/bin:$PATH" VAULT_DB_FILE="$case_dir/vault.db" VAULT_FAIL_MODE="$vault_mode" UPDATE_STATUS="$update_status" \
       BASE_DOMAIN=example.test POSTGRES_PASSWORD=redacted-secret NPM_ADMIN_EMAIL=test@example.test NPM_ADMIN_PASS=redacted-secret TLS_MODE=local \
       TLS_MOCK_LOG="$case_dir/tls.log" TLS_MOCK_CERT_SAN='api nginx port qdrant daiana studio supa whatsapp vanna webui msteams' \
      NPM_LOCAL_CERT_FILE="$case_dir/cert" NPM_LOCAL_KEY_FILE="$case_dir/key" bash ./apply-certs.sh) >/dev/null 2>&1; then
    return 1
  fi
  assert_vault_exact "$scheme" "$case_dir/vault.db"
  grep -q "^SUPABASE_PUBLIC_URL=${scheme}://supa.example.test$" "$case_dir/.env"
}

run_tls_failure_case() {
  local case_dir="$TMP_DIR/tls-failure"
  mkdir -p "$case_dir"
  write_env http "$case_dir/.env"
  write_vault http "$case_dir/vault.db"
  create_test_certificate "$case_dir/cert" "$case_dir/key"
  cp "$TMP_DIR/apply-certs.sh" "$case_dir/apply-certs.sh"
  mkdir -p "$case_dir/utils"; cp "$TMP_DIR/utils/public-url-propagation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/certificate-validation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/npm_ssl_bootstrap.sh" "$case_dir/utils/"
  cp "$TMP_DIR/update-daiana.sh" "$case_dir/update-daiana.sh"
  cp "$case_dir/.env" "$case_dir/.env.before"
  if (cd "$case_dir" && PATH="$TMP_DIR/bin:$PATH" VAULT_DB_FILE="$case_dir/vault.db" UPDATE_STATUS=0 TLS_MOCK_FAIL_PREFIX=studio \
      TLS_MOCK_LOG="$case_dir/tls.log" TLS_MOCK_CERT_SAN='api nginx port qdrant daiana studio supa whatsapp vanna webui msteams' \
      BASE_DOMAIN=example.test POSTGRES_PASSWORD=redacted-secret NPM_ADMIN_EMAIL=test@example.test NPM_ADMIN_PASS=redacted-secret TLS_MODE=local \
      NPM_LOCAL_CERT_FILE="$case_dir/cert" NPM_LOCAL_KEY_FILE="$case_dir/key" bash ./apply-certs.sh) >/dev/null 2>&1; then
    return 1
  fi
  cmp -s "$case_dir/.env.before" "$case_dir/.env"
  assert_vault_exact http "$case_dir/vault.db"
  grep -q 'prefix=studio result=failed' "$case_dir/tls.log"
  [[ ! -f "$case_dir/update-called" ]]
}

run_only_prefix_case() {
  local case_dir="$TMP_DIR/only-prefix"
  mkdir -p "$case_dir"
  write_env http "$case_dir/.env"
  write_vault http "$case_dir/vault.db"
  create_test_certificate "$case_dir/cert" "$case_dir/key"
  cp "$TMP_DIR/apply-certs.sh" "$case_dir/apply-certs.sh"
  mkdir -p "$case_dir/utils"; cp "$TMP_DIR/utils/public-url-propagation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/certificate-validation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/npm_ssl_bootstrap.sh" "$case_dir/utils/"
  cp "$TMP_DIR/update-daiana.sh" "$case_dir/update-daiana.sh"
  (cd "$case_dir" && PATH="$TMP_DIR/bin:$PATH" VAULT_DB_FILE="$case_dir/vault.db" ONLY_PREFIX=api \
      TLS_MOCK_LOG="$case_dir/tls.log" TLS_MOCK_CERT_SAN='api nginx port qdrant daiana studio supa whatsapp vanna webui msteams' \
      BASE_DOMAIN=example.test POSTGRES_PASSWORD=redacted-secret NPM_ADMIN_EMAIL=test@example.test NPM_ADMIN_PASS=redacted-secret TLS_MODE=local \
      NPM_LOCAL_CERT_FILE="$case_dir/cert" NPM_LOCAL_KEY_FILE="$case_dir/key" bash ./apply-certs.sh) >/dev/null 2>&1
  [[ "$(wc -l < "$case_dir/tls.log" | tr -d ' ')" == 2 ]]
  grep -q 'prefix=api ' "$case_dir/tls.log"
  if grep -q 'prefix=studio ' "$case_dir/tls.log"; then exit 1; fi
  grep -q '^SUPABASE_PUBLIC_URL=http://supa.example.test$' "$case_dir/.env"
  assert_vault_exact http "$case_dir/vault.db"
}

run_compensation_reread_failure_case() {
  local case_dir="$TMP_DIR/reread-failure"
  mkdir -p "$case_dir"
  write_env http "$case_dir/.env"
  write_vault http "$case_dir/vault.db"
  create_test_certificate "$case_dir/cert" "$case_dir/key"
  cp "$TMP_DIR/apply-certs.sh" "$case_dir/apply-certs.sh"
  mkdir -p "$case_dir/utils"; cp "$TMP_DIR/utils/public-url-propagation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/certificate-validation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/npm_ssl_bootstrap.sh" "$case_dir/utils/"
  cp "$TMP_DIR/update-daiana.sh" "$case_dir/update-daiana.sh"
  cp "$case_dir/.env" "$case_dir/.env.before"
  if (cd "$case_dir" && PATH="$TMP_DIR/bin:$PATH" VAULT_DB_FILE="$case_dir/vault.db" VAULT_REREAD_FAIL=1 UPDATE_STATUS=7 \
      TLS_MOCK_LOG="$case_dir/tls.log" TLS_MOCK_CERT_SAN='api nginx port qdrant daiana studio supa whatsapp vanna webui msteams' \
      BASE_DOMAIN=example.test POSTGRES_PASSWORD=redacted-secret NPM_ADMIN_EMAIL=test@example.test NPM_ADMIN_PASS=redacted-secret TLS_MODE=local \
      NPM_LOCAL_CERT_FILE="$case_dir/cert" NPM_LOCAL_KEY_FILE="$case_dir/key" bash ./apply-certs.sh) >"$case_dir/output" 2>&1; then
    return 1
  fi
  cmp -s "$case_dir/.env.before" "$case_dir/.env"
  assert_vault_exact http "$case_dir/vault.db"
  grep -q 'compensation was not fully verified' "$case_dir/output"
  if grep -q 'redacted-secret' "$case_dir/output"; then exit 1; fi
  compgen -G "$case_dir/.vault-public.rollback.*" >/dev/null
}

run_success_case http
run_success_case https
run_success_case https 192.168.0.19.nip.io
run_case http forward 0
run_case http none 7
run_case https none 7
run_tls_failure_case
run_only_prefix_case
run_compensation_reread_failure_case
printf 'apply-certs compensation orchestration tests passed\n'
