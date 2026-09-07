#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT_DIR/utils/certificate-validation.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/utils"
touch "$TMP_DIR/.env"
cp "$ROOT_DIR/apply-certs.sh" "$TMP_DIR/apply-certs.sh"
cp "$ROOT_DIR/utils/certificate-validation.sh" "$TMP_DIR/utils/certificate-validation.sh"
cat > "$TMP_DIR/utils/public-url-propagation.sh" <<'URLS'
daiana_host_for_domain() {
  local domain="$1"
  if [[ "$domain" == *.nip.io || "$domain" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    printf 'daiana.%s' "$domain"
  else
    printf '%s' "$domain"
  fi
}
portainer_refresh_stack_env() { :; }
stage_public_env_update() { cp "$1" "${1}.stage"; printf '%s\n' "${1}.stage"; }
vault_snapshot_public_url_entries() { : > "$1"; }
vault_snapshot_public_url_scheme() { printf 'http\n'; }
vault_upsert_public_url_entries() { return 0; }
vault_restore_public_url_entries() { return 0; }
vault_verify_public_url_entries() { return 0; }
URLS
cat > "$TMP_DIR/update-daiana.sh" <<'UPDATE'
#!/usr/bin/env bash
exit 0
UPDATE
chmod +x "$TMP_DIR/update-daiana.sh"
cat > "$TMP_DIR/utils/npm_ssl_bootstrap.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/certificate-validation.sh"
# This is only the NPM process boundary mock. Certificate generation and all
# SAN assertions use the shared certificate validation helper.
[[ "${TLS_SAN_TEST_NPM_BOUNDARY:-}" == yes ]] || exit 97
for host in api nginx port qdrant daiana studio supa whatsapp vanna webui msteams; do
  if [[ "$host" == daiana ]]; then
    domain="$BASE_DOMAIN"
  else
    domain="$host.$BASE_DOMAIN"
  fi
  certificate_hostname_matches "${NPM_LOCAL_CERT_FILE/#~/$HOME}" "$domain"
done
printf 'NPM_BOOTSTRAP_STATUS=SUCCESS\n'
BOOTSTRAP
chmod +x "$TMP_DIR/utils/npm_ssl_bootstrap.sh"

TLS_SAN_TEST_NPM_BOUNDARY=yes BASE_DOMAIN=example.test TLS_MODE=local NPM_ADMIN_EMAIL=test@example.test \
  NPM_ADMIN_PASS=redacted NPM_LOCAL_CERT_FILE="$TMP_DIR/all.crt" \
  NPM_LOCAL_KEY_FILE="$TMP_DIR/all.key" bash "$TMP_DIR/apply-certs.sh" --dry-run >/dev/null

# Run the real certificate-generation path without invoking NPM or runtime.
TLS_SAN_TEST_NPM_BOUNDARY=yes BASE_DOMAIN=example.test TLS_MODE=local NPM_ADMIN_EMAIL=test@example.test \
  NPM_ADMIN_PASS=redacted NPM_LOCAL_CERT_FILE="$TMP_DIR/all.crt" \
  NPM_LOCAL_KEY_FILE="$TMP_DIR/all.key" bash "$TMP_DIR/apply-certs.sh" >/dev/null
for host in api nginx port qdrant daiana studio supa whatsapp vanna webui msteams; do
  if [[ "$host" == daiana ]]; then
    domain=example.test
  else
    domain="$host.example.test"
  fi
  certificate_hostname_matches "$TMP_DIR/all.crt" "$domain"
done

# A real SAN mismatch must fail before the child bootstrap can mutate hosts.
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$TMP_DIR/wrong.key" \
  -out "$TMP_DIR/wrong.crt" -subj '/CN=wrong.example.test' >/dev/null 2>&1
if BASE_DOMAIN=example.test TLS_MODE=local NPM_ADMIN_EMAIL=test@example.test \
  NPM_ADMIN_PASS=redacted NPM_LOCAL_CERT_FILE="$TMP_DIR/wrong.crt" \
  NPM_LOCAL_KEY_FILE="$TMP_DIR/wrong.key" bash "$TMP_DIR/apply-certs.sh" >/dev/null 2>&1; then
  printf 'SAN mismatch was accepted\n' >&2
  exit 1
fi

printf 'real multi-host SAN generation and mismatch tests passed\n'
