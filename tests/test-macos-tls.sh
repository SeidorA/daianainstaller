#!/usr/bin/env bash
set -euo pipefail

log() { printf '===> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
precondition_failure() { printf 'PRECONDITION_FAILURE: %s\n' "$*" >&2; exit 2; }

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"

load_dotenv() {
  local file="$1"
  local line key value
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
          value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
          value="${value:1:${#value}-2}"
        fi
        export "$key=$value"
        ;;
    esac
  done < "$file"
}

load_dotenv .env

BASE_DOMAIN="${BASE_DOMAIN:-}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-}"
NPM_ADMIN_PASS="${NPM_ADMIN_PASS:-}"
NPM_API_URL="${NPM_API_URL:-http://127.0.0.1:81}"
CERT_NAME="${NPM_LOCAL_CERT_NAME:-daiana-local-tls}"
[ -n "$BASE_DOMAIN" ] || die "BASE_DOMAIN is required"
[ -n "$NPM_ADMIN_EMAIL" ] || die "NPM_ADMIN_EMAIL is required"
[ -n "$NPM_ADMIN_PASS" ] || die "NPM_ADMIN_PASS is required"

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response status body
  local args=( -sS -X "$method" "$NPM_API_URL$path" -H 'Content-Type: application/json' )
  [ -n "${TOKEN:-}" ] && args+=( -H "Authorization: Bearer $TOKEN" )
  if [ -n "$data" ]; then
    response="$(printf '%s' "$data" | curl "${args[@]}" --data-binary @- -w '\n%{http_code}' || true)"
  else
    response="$(curl "${args[@]}" -w '\n%{http_code}' || true)"
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    printf 'ERROR: NPM %s %s failed (HTTP %s):\n%s\n' "$method" "$path" "$status" "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

login() {
  local payload
  payload="$(NPM_ADMIN_PASS="$NPM_ADMIN_PASS" jq -n --arg identity "$NPM_ADMIN_EMAIL" '{identity:$identity, secret:env.NPM_ADMIN_PASS}')"
  api POST /api/tokens "$payload" | jq -r '.token // empty'
}

find_cert_id() {
  api GET '/api/nginx/certificates?per_page=200' | jq -r --arg name "$CERT_NAME" '
    (if type == "object" and has("data") then .data else . end)
    | .[]?
    | select((.provider // "") == "other")
    | select((.nice_name // "") == $name)
    | .id
  ' | head -n1
}

find_proxy_host_id() {
  local domain="$1"
  api GET '/api/nginx/proxy-hosts?per_page=200' | jq -r --arg d "$domain" '
    (if type == "object" and has("data") then .data else . end)
    | .[]?
    | select((.domain_names // []) | index($d))
    | .id
  ' | head -n1
}

wait_for_https_ready() {
  local domain="$1"
  local max_tries="${2:-60}"
  local delay="${3:-2}"
  local i=1
  local code
  while [ "$i" -le "$max_tries" ]; do
    code="$(http_status "https://$domain" -k)"
    case "$code" in
      2*|3*)
        printf '%s' "$code"
        return 0
        ;;
      502|503|504|000)
        if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
          log "Waiting for $domain to become ready... ($i/$max_tries) [HTTP $code]"
        fi
        sleep "$delay"
        i=$((i + 1))
        ;;
      *)
        die "HTTPS check failed for $domain (HTTP $code)"
        ;;
    esac
  done
  die "HTTPS check failed for $domain (still not ready after ${max_tries} attempts)"
}

check_proxy_host() {
  local domain="$1"
  local host_id
  host_id="$(find_proxy_host_id "$domain")"
  [ -n "$host_id" ] || die "Proxy host not found: $domain"

  local info
  info="$(api GET "/api/nginx/proxy-hosts/$host_id")"
  local cert_id ssl_forced
  cert_id="$(jq -r '.certificate_id // empty' <<<"$info")"
  ssl_forced="$(jq -r '.ssl_forced // false' <<<"$info")"

  [ -n "$cert_id" ] || die "Proxy host $domain has no certificate assigned"
  [ "$ssl_forced" = "true" ] || precondition_failure "NPM proxy host $domain reports ssl_forced=$ssl_forced; restore the managed certificate/TLS state with bash apply-certs.sh, then rerun this smoke test"

  log "OK: $domain (cert_id=$cert_id, ssl_forced=$ssl_forced)"
}

TOKEN="$(login)"
[ -n "$TOKEN" ] || die "Unable to authenticate to NPM"

CERT_ID="$(find_cert_id)"
[ -n "$CERT_ID" ] || die "Custom certificate '$CERT_NAME' not found in NPM"

for domain in "nginx.$BASE_DOMAIN" "studio.$BASE_DOMAIN" "port.$BASE_DOMAIN"; do
  check_proxy_host "$domain"
done

log "MacOS TLS smoke test passed"
