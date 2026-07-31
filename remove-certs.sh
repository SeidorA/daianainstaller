#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
  printf 'ERROR: run this script with bash, not sh.\n' >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/utils/public-url-propagation.sh"

CONFIRMED=0
CERTIFICATE_ID=""
ALL_MANAGED=0
EXPECT_CERTIFICATE_ID=0
for arg in "$@"; do
  if [[ "$EXPECT_CERTIFICATE_ID" == 1 ]]; then
    CERTIFICATE_ID="$arg"
    EXPECT_CERTIFICATE_ID=0
    continue
  fi
  case "$arg" in
    --confirm) CONFIRMED=1 ;;
    --certificate-id=*) CERTIFICATE_ID="${arg#*=}" ;;
    --certificate-id) EXPECT_CERTIFICATE_ID=1 ;;
    --all-managed) ALL_MANAGED=1 ;;
    --help|-h)
      printf 'Usage: bash remove-certs.sh --confirm [--certificate-id ID|--all-managed]\n'
      exit 0
      ;;
    *) printf 'ERROR: unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done
[[ "$EXPECT_CERTIFICATE_ID" == 0 ]] || { printf 'ERROR: --certificate-id requires a value\n' >&2; exit 1; }
[[ "$CONFIRMED" == 1 ]] || { printf 'ERROR: certificate removal requires explicit --confirm\n' >&2; exit 1; }
[[ "$ALL_MANAGED" == 0 || -z "$CERTIFICATE_ID" ]] || { printf 'ERROR: choose --certificate-id or --all-managed, not both\n' >&2; exit 1; }

load_dotenv() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|'#'*) continue ;; export\ *) line="${line#export }" ;; esac
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; value="${line#*=}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then value="${value:1:${#value}-2}"; fi
    if [[ "$value" == \'*\' && "$value" == *\' ]]; then value="${value:1:${#value}-2}"; fi
    printf -v "$key" '%s' "$value"; export "${key?}"
  done < "$file"
}
load_dotenv .env

BASE_DOMAIN="${BASE_DOMAIN:-}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-}"
NPM_ADMIN_PASS="${NPM_ADMIN_PASS:-}"
[[ -n "$BASE_DOMAIN" && -n "$NPM_ADMIN_EMAIL" && -n "$NPM_ADMIN_PASS" ]] || {
  printf 'ERROR: BASE_DOMAIN, NPM_ADMIN_EMAIL, and NPM_ADMIN_PASS are required\n' >&2; exit 1;
}

# The bootstrap provides the authenticated, bounded NPM request primitives but
# does not execute its apply lifecycle when sourced.
# shellcheck disable=SC1091
source "$ROOT_DIR/utils/npm_ssl_bootstrap.sh"

authenticate_npm() {
  wait_for_npm || return 1
  # write_npm_auth_config consumes this global when it creates the curl config.
  # shellcheck disable=SC2034
  TOKEN="$(login)" || return 1
  write_npm_auth_config || return 1
}

managed_domains() {
  local entry prefix domain_var
  for entry in "${SERVICES[@]}"; do
    IFS=: read -r prefix _default_host _default_port <<<"$entry"
    domain_var="DOMAIN_$(printf '%s' "$prefix" | tr '[:lower:]' '[:upper:]')"
    if [[ -n "${!domain_var:-}" ]]; then
      printf '%s\n' "${!domain_var}"
    elif [[ "$BASE_DOMAIN" == "${prefix}."* ]]; then
      printf '%s\n' "$BASE_DOMAIN"
    else
      printf '%s.%s\n' "$prefix" "$BASE_DOMAIN"
    fi
  done
}

inventory_json() {
  local response="$1"
  jq -e 'if type == "object" and (.data | type) == "array" then .data elif type == "array" then . else error end' <<<"$response"
}

validate_certificate_record() {
  local record="$1"
  jq -e --argjson max "$MAX_SAFE_POSITIVE_INTEGER_ID" '
    type == "object" and
    (.id | type == "number" and isfinite and floor == . and . > 0 and . <= $max) and
    (.provider == "letsencrypt" or .provider == "other") and
    (.nice_name | type == "string" and test("^[A-Za-z0-9._ -]+$") and length > 0) and
    (.domain_names | type == "array" and length > 0 and all(.[]; type == "string" and test("^[A-Za-z0-9.-]+\\.[A-Za-z0-9.-]+$")))
  ' <<<"$record" >/dev/null
}

detach_managed_hosts() {
  local inventory inventory_file host id domain payload current managed=0 cert_id
  local -a domains=()
  while IFS= read -r domain; do domains+=("$domain"); done < <(managed_domains)
  inventory_file="$(capture_proxy_host_inventory 1)" || return 1
  inventory="$(<"$inventory_file")"
  while IFS= read -r host; do
    id="$(jq -er '.id | tostring' <<<"$host")" || return 1
    is_positive_integer_id "$id" || return 1
    domain="$(jq -er '.domain_names | if length == 1 then .[0] else error end' <<<"$host")" || return 1
    if printf '%s\n' "${domains[@]}" | grep -F -x -q -- "$domain"; then
      managed=1
      cert_id="$(jq -er '.certificate_id | tostring' <<<"$host")" || return 1
      [[ "$cert_id" == 0 || "$cert_id" =~ ^[1-9][0-9]*$ ]] || return 1
      printf '%s' "$host" > "$ROLLBACK_DIR/host-$id.json"
      if [[ "$cert_id" != 0 ]]; then
        if ! printf '%s\n' "${DETACHED_CERT_IDS[*]-}" | grep -F -x -q -- "$cert_id"; then
          DETACHED_CERT_IDS[${#DETACHED_CERT_IDS[@]}]="$cert_id"
        fi
      fi
      payload="$(proxy_host_mutable_payload "$host" | jq -c '.certificate_id=0 | .ssl_forced=false | .hsts_enabled=false | .hsts_subdomains=false | .http2_support=false')" || return 1
      npm_request PUT "/api/nginx/proxy-hosts/$id" "$payload" >/dev/null || return 1
      current="$(api_get "/api/nginx/proxy-hosts/$id")" || return 1
      jq -e '.certificate_id == 0 and .ssl_forced == false and .hsts_enabled == false and .hsts_subdomains == false and .http2_support == false' <<<"$current" >/dev/null || return 1
    fi
  done < <(jq -c '.[]' <<<"$inventory")
  [[ "$managed" == 1 ]] || { printf 'ERROR: no managed proxy hosts were found\n' >&2; return 1; }
}

restore_detached_hosts() {
  local id state_file
  for state_file in "$ROLLBACK_DIR"/host-*.json; do
    [[ -f "$state_file" ]] || continue
    id="${state_file##*/host-}"; id="${id%.json}"
    npm_request PUT "/api/nginx/proxy-hosts/$id" "$(proxy_host_mutable_payload "$(<"$state_file")")" >/dev/null || return 1
  done
}

refresh_http_projection() {
  local stage backup vault_snapshot vault_scheme scheme compensation_failed=0
  scheme="$(public_url_scheme)" || return 1
  stage="$(stage_public_env_update .env "$scheme")" || return 1
  backup="$(mktemp .env.remove.rollback.XXXXXX)" || { rm -f "$stage"; return 1; }
  cp -p .env "$backup" || { rm -f "$stage" "$backup"; return 1; }
  vault_snapshot="$(mktemp .vault-public.remove.rollback.XXXXXX)" || { rm -f "$stage" "$backup"; return 1; }
  vault_snapshot_public_url_entries "$vault_snapshot" || { rm -f "$stage" "$backup" "$vault_snapshot"; return 1; }
  vault_scheme="$(vault_snapshot_public_url_scheme "$vault_snapshot")" || { rm -f "$stage" "$backup" "$vault_snapshot"; return 1; }
  mv "$stage" .env || return 1
  load_dotenv .env
  if ! vault_upsert_public_url_entries .env; then
    vault_restore_public_url_entries "$vault_snapshot" || compensation_failed=1
    vault_verify_public_url_entries "$vault_snapshot" "$vault_scheme" || compensation_failed=1
    if ! mv "$backup" .env; then compensation_failed=1; else load_dotenv .env; fi
    if [[ "$compensation_failed" == 1 ]]; then
      PUBLIC_ENV_BACKUP="$backup"
      PUBLIC_VAULT_SNAPSHOT="$vault_snapshot"
      return 1
    fi
    rm -f "$vault_snapshot"
    return 1
  fi
  PUBLIC_ENV_BACKUP="$backup"
  PUBLIC_VAULT_SNAPSHOT="$vault_snapshot"
}

compensate_public_projection() {
  local failed=0
  if [[ -n "${PUBLIC_ENV_BACKUP:-}" && -f "$PUBLIC_ENV_BACKUP" ]]; then
    mv "$PUBLIC_ENV_BACKUP" .env || failed=1
  fi
  if [[ -n "${PUBLIC_VAULT_SNAPSHOT:-}" && -f "$PUBLIC_VAULT_SNAPSHOT" ]]; then
    vault_restore_public_url_entries "$PUBLIC_VAULT_SNAPSHOT" || failed=1
    vault_verify_public_url_entries "$PUBLIC_VAULT_SNAPSHOT" "$(vault_snapshot_public_url_scheme "$PUBLIC_VAULT_SNAPSHOT")" || failed=1
  fi
  load_dotenv .env
  return "$failed"
}

delete_certificate_record() {
  local id="$1" record response status
  is_positive_integer_id "$id" || return 1
  record="$(api_get "/api/nginx/certificates/$id")" || return 1
  validate_certificate_record "$record" || { printf 'ERROR: certificate metadata validation failed for id %s\n' "$id" >&2; return 1; }
  [[ "$(jq -er '.id | tostring' <<<"$record")" == "$id" ]] || return 1
  response="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" -X DELETE "$NPM_API_URL/api/nginx/certificates/$id" --config "${NPM_AUTH_CONFIG_FILE:-/dev/null}" -w '\n%{http_code}')" || return 1
  status="${response##*$'\n'}"
  [[ "$status" == 2* ]] || { printf 'ERROR: certificate deletion failed for id %s\n' "$id" >&2; return 1; }
  response="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" "$NPM_API_URL/api/nginx/certificates/$id" --config "${NPM_AUTH_CONFIG_FILE:-/dev/null}" -w '\n%{http_code}')" || return 1
  status="${response##*$'\n'}"
  [[ "$status" == 404 ]] || { printf 'ERROR: certificate deletion could not confirm exact 404 for id %s\n' "$id" >&2; return 1; }
}

cleanup_certificates() {
  local inventory inventory_file record id cert_id
  [[ "$ALL_MANAGED" == 1 || -n "$CERTIFICATE_ID" ]] || return 0
  inventory_file="$(capture_proxy_host_inventory 2)" || return 1
  inventory="$(<"$inventory_file")"
  while IFS= read -r record; do
    cert_id="$(jq -er '.certificate_id | tostring' <<<"$record")" || return 1
    if [[ "$cert_id" != 0 ]] && { [[ -n "$CERTIFICATE_ID" && "$cert_id" == "$CERTIFICATE_ID" ]] || [[ "$ALL_MANAGED" == 1 && -n "$(printf '%s\n' "${DETACHED_CERT_IDS[*]-}" | grep -F -x -- "$cert_id" || true)" ]]; }; then
      printf 'ERROR: refusing to delete certificate %s while a proxy host references it\n' "$cert_id" >&2
      return 1
    fi
  done < <(jq -c '.[]' <<<"$inventory")
  if [[ -n "$CERTIFICATE_ID" ]]; then
    delete_certificate_record "$CERTIFICATE_ID"
  else
    for id in "${DETACHED_CERT_IDS[@]}"; do delete_certificate_record "$id"; done
  fi
}

ROLLBACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/remove-certs.XXXXXX")"
DETACHED_CERT_IDS=()
authenticate_npm
detach_managed_hosts || { restore_detached_hosts || true; exit 1; }

refresh_http_projection || { restore_detached_hosts || true; exit 1; }
if ! bash update-daiana.sh --update; then
  printf 'ERROR: app stack refresh failed; compensating public URL projection\n' >&2
  compensate_public_projection || printf 'ERROR: public URL compensation was not fully verified\n' >&2
  exit 1
fi
cleanup_certificates
rm -f "$PUBLIC_ENV_BACKUP" "$PUBLIC_VAULT_SNAPSHOT"
printf 'Certificate removal completed; managed proxy hosts and application stacks now use the HTTP projection.\n'
