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

write_env() {
  local scheme="$1" file="$2"
  cat > "$file" <<ENV
BASE_DOMAIN=example.test
NPM_ADMIN_EMAIL=test@example.test
NPM_ADMIN_PASS=redacted-secret
STUDIO_BASE_URL=${scheme}://studio.example.test
SUPABASE_PUBLIC_URL=${scheme}://supa.example.test
API_EXTERNAL_URL=${scheme}://supa.example.test/auth/v1
SITE_URL=${scheme}://daiana.example.test
WEBUI_BASE_URL=${scheme}://webui.example.test
BACKEND_BASE_URL=${scheme}://api.example.test
WS_BASE_URL=${scheme}://whatsapp.example.test
MS_BASE_URL=${scheme}://msteams.example.test
VANNA_BASE_URL=${scheme}://vanna.example.test
QDRANT_BASE_URL=${scheme}://qdrant.example.test
CORS_ALLOW_ORIGIN=${scheme}://daiana.example.test
NEXT_PUBLIC_APP_URL=${scheme}://daiana.example.test
INTERNAL_API_URL=http://daiana-python:5002
ENV
}

write_vault() {
  local scheme="$1" file="$2"
  local name host
  : > "$file"
  for name in "${NAMES[@]}"; do
    case "$name" in
      NEXT_PUBLIC_SUPABASE_URL) host=supa.example.test ;;
      NEXT_PUBLIC_API_PYTHON) host=api.example.test ;;
      NEXT_PUBLIC_API_TRAINING) host=vanna.example.test ;;
      NEXT_PUBLIC_API_QDRANT) host=qdrant.example.test ;;
      NEXT_PUBLIC_API_MSTEAMS) host=msteams.example.test ;;
      NEXT_PUBLIC_API_WHATSAPP) host=whatsapp.example.test ;;
      NEXT_PUBLIC_API_STUDIO_BASE_URL) host=studio.example.test ;;
      NEXT_PUBLIC_WEBUI_URL) host=webui.example.test ;;
      NEXT_PUBLIC_APP_URL) host=daiana.example.test ;;
    esac
    printf '%s\t%s://%s\n' "$name" "$scheme" "$host" >> "$file"
  done
}

mkdir -p "$TMP_DIR/utils" "$TMP_DIR/bin"
cp "$ROOT_DIR/apply-certs.sh" "$TMP_DIR/apply-certs.sh"
cp "$ROOT_DIR/utils/public-url-propagation.sh" "$TMP_DIR/utils/public-url-propagation.sh"
cat > "$TMP_DIR/utils/npm_ssl_bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail

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
  domain="$prefix.$BASE_DOMAIN"
  [[ "$prefix" == nginx || "$prefix" == port ]] && domain="$prefix.$BASE_DOMAIN"
  if [[ "${TLS_MOCK_FAIL_PREFIX:-}" == "$prefix" ]]; then
    printf 'TLS_MOCK prefix=%s result=failed reason=handshake\n' "$prefix" >> "${TLS_MOCK_LOG:?}"
    exit 33
  fi
  openssl x509 -in "${NPM_LOCAL_CERT_FILE/#~/$HOME}" -noout -checkhost "$domain" >/dev/null 2>&1 || exit 34
  printf 'TLS_MOCK prefix=%s domain=%s san=%s handshake=secure\n' "$prefix" "$domain" \
    "${TLS_MOCK_CERT_SAN:?}" >> "${TLS_MOCK_LOG:?}"
done
printf 'TLS_MOCK_RESULT=SUCCESS\n' >> "${TLS_MOCK_LOG:?}"
exit 0
BOOTSTRAP
chmod +x "$TMP_DIR/utils/npm_ssl_bootstrap.sh"

cat > "$TMP_DIR/update-daiana.sh" <<'UPDATE'
#!/usr/bin/env bash
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
[[ "${1:-}" == compose && "${2:-}" == exec && "${3:-}" == -T && "${4:-}" == db ]] || exit 90
[[ "${5:-}" == sh && "${6:-}" == -c ]] || exit 91
IFS= read -r _password
shift 7
sql=''
value_keys=()
value_values=()
set_value() {
  local key="$1" value="$2" i
  for i in "${!value_keys[@]}"; do
    if [[ "${value_keys[i]}" == "$key" ]]; then value_values[i]="$value"; return; fi
  done
  value_keys+=("$key")
  value_values+=("$value")
}
get_value() {
  local key="$1" i
  for i in "${!value_keys[@]}"; do
    if [[ "${value_keys[i]}" == "$key" ]]; then printf '%s' "${value_values[i]}"; return; fi
  done
}
while (($#)); do
  case "$1" in
    -v)
      assignment="$2"
      set_value "${assignment%%=*}" "${assignment#*=}"
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

if [[ "$sql" == *public_supabase_url* && "${VAULT_FAIL_MODE:-}" == forward ]]; then
  exit 42
fi
if [[ "$sql" == *restore_* ]]; then
  : > "$VAULT_DB_FILE"
  for i in {1..9}; do
    printf '%s\t%s\n' "${NAMES[$((i - 1))]}" "$(get_value "restore_$i")" >> "$VAULT_DB_FILE"
  done
  exit 0
fi
if [[ "$sql" == *verify_* ]]; then
  [[ "${VAULT_REREAD_FAIL:-0}" == 1 ]] && exit 43
  for i in {1..9}; do
    actual="$(awk -F '\t' -v key="${NAMES[$((i - 1))]}" '$1 == key { print $2 }' "$VAULT_DB_FILE")"
    [[ "$actual" == "$(get_value "verify_$i")" ]] || exit 43
  done
  exit 0
fi
if [[ "$sql" == *public_supabase_url* ]]; then
  : > "$VAULT_DB_FILE"
  names=(
    NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_API_PYTHON NEXT_PUBLIC_API_TRAINING
    NEXT_PUBLIC_API_QDRANT NEXT_PUBLIC_API_MSTEAMS NEXT_PUBLIC_API_WHATSAPP
    NEXT_PUBLIC_API_STUDIO_BASE_URL NEXT_PUBLIC_WEBUI_URL NEXT_PUBLIC_APP_URL
  )
  params=(public_supabase_url public_api_python public_api_training public_api_qdrant public_api_msteams public_api_whatsapp public_api_studio public_webui public_app)
  for i in {0..8}; do printf '%s\t%s\n' "${names[$i]}" "$(get_value "${params[$i]}")" >> "$VAULT_DB_FILE"; done
  exit 0
fi
exit 92
DOCKER
chmod +x "$TMP_DIR/bin/docker"

assert_vault_exact() {
  local scheme="$1" file="$2" name host expected
  [[ "$(wc -l < "$file" | tr -d ' ')" == 9 ]] || exit 1
  for name in "${NAMES[@]}"; do
    case "$name" in
      NEXT_PUBLIC_SUPABASE_URL) host=supa.example.test ;;
      NEXT_PUBLIC_API_PYTHON) host=api.example.test ;;
      NEXT_PUBLIC_API_TRAINING) host=vanna.example.test ;;
      NEXT_PUBLIC_API_QDRANT) host=qdrant.example.test ;;
      NEXT_PUBLIC_API_MSTEAMS) host=msteams.example.test ;;
      NEXT_PUBLIC_API_WHATSAPP) host=whatsapp.example.test ;;
      NEXT_PUBLIC_API_STUDIO_BASE_URL) host=studio.example.test ;;
      NEXT_PUBLIC_WEBUI_URL) host=webui.example.test ;;
      NEXT_PUBLIC_APP_URL) host=daiana.example.test ;;
    esac
    expected="${scheme}://${host}"
    [[ "$(awk -F '\t' -v key="$name" '$1 == key { print $2 }' "$file")" == "$expected" ]] || exit 1
  done
}

create_test_certificate() {
  local cert_file="$1" key_file="$2" config="$TMP_DIR/cert.cnf" san host
  : > "$config"
  printf '%s\n' '[req]' 'prompt=no' 'distinguished_name=req_dn' 'x509_extensions=req_ext' '[req_dn]' 'CN=api.example.test' '[req_ext]' 'subjectAltName=@alt_names' '[alt_names]' >> "$config"
  san=1
  for host in api nginx port qdrant daiana studio supa whatsapp vanna webui msteams; do
    printf 'DNS.%s=%s.example.test\n' "$san" "$host" >> "$config"
    san=$((san + 1))
  done
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "$key_file" -out "$cert_file" \
    -subj '/CN=api.example.test' -config "$config" >/dev/null 2>&1
}

run_success_case() {
  local scheme="$1" case_dir
  case_dir="$TMP_DIR/success-$scheme"
  mkdir -p "$case_dir"
  write_env "$scheme" "$case_dir/.env"
  write_vault "$scheme" "$case_dir/vault.db"
  create_test_certificate "$case_dir/cert" "$case_dir/key"
  cp "$TMP_DIR/apply-certs.sh" "$case_dir/apply-certs.sh"
  mkdir -p "$case_dir/utils"; cp "$TMP_DIR/utils/public-url-propagation.sh" "$case_dir/utils/"
  cp "$TMP_DIR/utils/npm_ssl_bootstrap.sh" "$case_dir/utils/"
  cp "$TMP_DIR/update-daiana.sh" "$case_dir/update-daiana.sh"
  (cd "$case_dir" && PATH="$TMP_DIR/bin:$PATH" VAULT_DB_FILE="$case_dir/vault.db" UPDATE_STATUS=0 TLS_MOCK_LOG="$case_dir/tls.log" \
      TLS_MOCK_CERT_SAN='api nginx port qdrant daiana studio supa whatsapp vanna webui msteams' \
      BASE_DOMAIN=example.test POSTGRES_PASSWORD=redacted-secret NPM_ADMIN_EMAIL=test@example.test NPM_ADMIN_PASS=redacted-secret TLS_MODE=local \
      NPM_LOCAL_CERT_FILE="$case_dir/cert" NPM_LOCAL_KEY_FILE="$case_dir/key" bash ./apply-certs.sh) >/dev/null 2>&1
  assert_vault_exact https "$case_dir/vault.db"
  grep -q '^SUPABASE_PUBLIC_URL=https://supa.example.test$' "$case_dir/.env"
  grep -q '^INTERNAL_API_URL=' "$case_dir/.env" && ! grep -q '^INTERNAL_API_URL=https://' "$case_dir/.env"
  grep -q 'handshake=secure' "$case_dir/tls.log"
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
run_case http forward 0
run_case http none 7
run_case https none 7
run_tls_failure_case
run_only_prefix_case
run_compensation_reread_failure_case
printf 'apply-certs compensation orchestration tests passed\n'
