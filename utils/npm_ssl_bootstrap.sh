#!/usr/bin/env bash
set -euo pipefail

ensure_command() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    local packages=()
    local pkg
    for pkg in "$@"; do
      if ! command -v "$pkg" >/dev/null 2>&1; then
        packages+=("$pkg")
      fi
    done

    if [[ ${#packages[@]} -gt 0 ]]; then
      echo "Faltan ${packages[*]}; intentando instalar automáticamente..."
      if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        if command -v sudo >/dev/null 2>&1; then
          sudo -n apt-get update && sudo -n apt-get install -y "${packages[@]}"
        else
          echo "Necesitás root o sudo para instalar: ${packages[*]}" >&2
          exit 1
        fi
      else
        apt-get update && apt-get install -y "${packages[@]}"
      fi
    fi
  fi

  command -v "$cmd" >/dev/null 2>&1 || { echo "Falta '$cmd'"; exit 1; }
}

ensure_command curl curl jq
ensure_command jq curl jq
ensure_command openssl openssl
ensure_command python3 python3

NPM_API_URL="${NPM_API_URL:-http://127.0.0.1:81}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:?Falta NPM_ADMIN_EMAIL}"
validate_npm_admin_pass() {
  local xtrace_was_enabled=0
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  if [[ -n "${NPM_ADMIN_PASS:-}" ]]; then
    validation_status=0
  else
    validation_status=1
  fi
  if (( xtrace_was_enabled )); then
    set -x
  fi
  if [[ "$validation_status" -ne 0 ]]; then
    echo "Falta NPM_ADMIN_PASS" >&2
    return 1
  fi
}
validate_npm_admin_pass
NPM_CONNECT_TIMEOUT="${NPM_CONNECT_TIMEOUT:-5}"
NPM_OPERATION_TIMEOUT="${NPM_OPERATION_TIMEOUT:-15}"
NPM_READY_ATTEMPTS="${NPM_READY_ATTEMPTS:-120}"
NPM_READY_DELAY="${NPM_READY_DELAY:-2}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$NPM_ADMIN_EMAIL}"
TLS_MODE="${TLS_MODE:-}"
USE_LOCAL_TLS_CERTS="${USE_LOCAL_TLS_CERTS:-0}"
ENSURE_PROXY_HOSTS="${ENSURE_PROXY_HOSTS:-1}"
NPM_LOCAL_CERT_NAME="${NPM_LOCAL_CERT_NAME:-daiana-local-tls}"
NPM_LOCAL_CERT_FILE="${NPM_LOCAL_CERT_FILE:-volumes/api/server.crt}"
NPM_LOCAL_KEY_FILE="${NPM_LOCAL_KEY_FILE:-volumes/api/server.key}"
NPM_CUSTOM_CERT_NAME="${NPM_CUSTOM_CERT_NAME:-daiana-custom-tls}"
NPM_CUSTOM_CERT_FILE="${NPM_CUSTOM_CERT_FILE:-}"
NPM_CUSTOM_KEY_FILE="${NPM_CUSTOM_KEY_FILE:-}"
ONLY_PREFIX="${ONLY_PREFIX:-}"
NPM_TLS_VERIFY_PATH="${NPM_TLS_VERIFY_PATH:-/}"
NPM_TLS_VERIFY_IP="${NPM_TLS_VERIFY_IP:-}"
MAX_SAFE_POSITIVE_INTEGER_ID=9007199254740991
ROLLBACK_DIR=""
ROLLBACK_RECORDS=""
ROLLBACK_SEQUENCE=0
ROLLBACK_INCOMPLETE=0
ROLLBACK_RETAIN_DIAGNOSTICS=0
TLS_VERIFY_ARGS=()
NPM_AUTH_CONFIG_FILE=""

# Dominio base para generarlos dinámicamente (ej: dnains.duckdns.org)
BASE_DOMAIN="${BASE_DOMAIN:-}"

SERVICES=(
  "api:daiana-python:5002"
  "nginx:npm:81"
  "port:portainer:9000"
  "qdrant:daiana-qdrant:6333"
  "daiana:daiana-next:3000"
  "studio:daiana-studio:3000"
  "supa:supabase-kong:8000"
  "whatsapp:daiana-whatsapp:3008"
  "vanna:daiana-vanna:5005"
  "webui:daiana-webui:8080"
  "msteams:daiana-msteams:3978"
)


redacted_failure() {
  local reason="$1"
  printf 'NPM_BOOTSTRAP_STATUS=FAILED\nNPM_BOOTSTRAP_REASON=%s\nNPM_BOOTSTRAP_CERTIFICATE_RESULT=not_verified\n' "$reason" >&2
  return 1
}

cleanup_npm_auth_config() {
  if [[ -n "$NPM_AUTH_CONFIG_FILE" ]]; then
    rm -f "$NPM_AUTH_CONFIG_FILE"
    NPM_AUTH_CONFIG_FILE=""
  fi
}

write_npm_auth_config() {
  local tmp xtrace_was_enabled=0 write_status
  [[ -n "${TOKEN:-}" ]] || return 1
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  if ! tmp="$(mktemp "${TMPDIR:-/tmp}/npm-auth.XXXXXX")"; then
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if ! printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" > "$tmp"; then
    rm -f "$tmp"
    if (( xtrace_was_enabled )); then
      set -x
    fi
    return 1
  fi
  NPM_AUTH_CONFIG_FILE="$tmp"
  write_status=$?
  if (( xtrace_was_enabled )); then
    set -x
  fi
  return "$write_status"
}

trap cleanup_npm_auth_config EXIT

wait_for_npm() {
  local response status curl_status i
  echo "Esperando NPM en $NPM_API_URL/api/ ..."
  for ((i = 1; i <= NPM_READY_ATTEMPTS; i++)); do
    if response="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" "$NPM_API_URL/api/" -w '\n%{http_code}')"; then
      curl_status=0
    else
      curl_status=$?
    fi
    status="${response##*$'\n'}"
    case "$status" in
      2*|3*)
        echo "NPM listo."
        return 0
        ;;
    esac
    if [[ "$curl_status" -ne 0 ]]; then
      status="unavailable"
      [[ "$i" == 1 || $((i % 10)) -eq 0 ]] && echo "NPM readiness connection failure (curl exit $curl_status; attempt $i/$NPM_READY_ATTEMPTS)." >&2
    elif [[ "$i" == 1 || $((i % 10)) -eq 0 ]]; then
      echo "NPM readiness HTTP failure (HTTP $status; attempt $i/$NPM_READY_ATTEMPTS)." >&2
    fi
    [[ "$i" -lt "$NPM_READY_ATTEMPTS" ]] && sleep "$NPM_READY_DELAY"
  done
  redacted_failure "npm_readiness_timeout"
}

npm_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response status body curl_status
  local -a auth_args=(--config "${NPM_AUTH_CONFIG_FILE:-/dev/null}")
  if [[ -n "$data" ]]; then
    if response="$(printf '%s' "$data" | curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" -X "$method" "$NPM_API_URL$path" \
      "${auth_args[@]}" -H "Content-Type: application/json" --data-binary @- -w '\n%{http_code}')"; then
      curl_status=0
    else
      curl_status=$?
    fi
  elif response="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" -X "$method" "$NPM_API_URL$path" \
    "${auth_args[@]}" -H "Content-Type: application/json" -w '\n%{http_code}')"; then
    curl_status=0
  else
    curl_status=$?
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$curl_status" -ne 0 ]]; then
    echo "NPM $method $path connection failure (curl exit $curl_status)." >&2
    return 1
  fi
  if [[ "$status" != 2* ]]; then
    echo "NPM $method $path failed (HTTP ${status:-unavailable}; response redacted)." >&2
    return 1
  fi
  printf '%s' "$body"
}

login() {
  local token payload_file response curl_status status body
  local xtrace_was_enabled=0 login_status=1
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  payload_file="$(mktemp "${TMPDIR:-/tmp}/npm-login.XXXXXX")" || {
    (( xtrace_was_enabled )) && set -x
    return 1
  }
  if ! chmod 600 "$payload_file"; then
    rm -f "$payload_file"
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if ! jq -n --arg identity "$NPM_ADMIN_EMAIL" --rawfile secret /dev/stdin \
    '{identity:$identity, secret:($secret|rtrimstr("\n"))}' \
    <<<"$NPM_ADMIN_PASS" > "$payload_file"; then
    rm -f "$payload_file"
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if response="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" \
    -X POST "$NPM_API_URL/api/tokens" -H 'Content-Type: application/json' \
    --data-binary "@$payload_file" -w '\n%{http_code}')"; then
    curl_status=0
  else
    curl_status=$?
  fi
  rm -f "$payload_file"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$curl_status" -ne 0 || "$status" != 2* ]]; then
    echo "No pude autenticar en NPM (revisa NPM_ADMIN_EMAIL/NPM_ADMIN_PASS)." >&2
  else
    token="$(printf '%s' "$body" | jq -r '.token')"
    if [[ -n "$token" && "$token" != "null" ]]; then
      printf '%s\n' "$token"
      login_status=0
    else
      echo "No pude autenticar en NPM (revisa NPM_ADMIN_EMAIL/NPM_ADMIN_PASS)." >&2
    fi
  fi
  if (( xtrace_was_enabled )); then
    set -x
  fi
  return "$login_status"
}

api_get() {
  npm_request GET "$1"
}

api_post() {
  npm_request POST "$1" "$2"
}

# Busca cert Let’s Encrypt existente que contenga el dominio en su lista
find_certificate_id_for_domain() {
  local domain="$1"
  local response
  response="$(api_get "/api/nginx/certificates?per_page=200")" || {
    echo "NPM certificate lookup failed for $domain (request failed; response redacted)." >&2
    return 1
  }
  CERTIFICATE_LOOKUP_RESPONSE="$response" CERTIFICATE_LOOKUP_VALUE="$domain" \
    MAX_SAFE_POSITIVE_INTEGER_ID="$MAX_SAFE_POSITIVE_INTEGER_ID" CERTIFICATE_LOOKUP_PROVIDER=letsencrypt \
    python3 - <<'PY'
import json
import os
import sys

class NumberToken:
    def __init__(self, token):
        self.token = token

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate object key")
        result[key] = value
    return result

def reject_float(token):
    raise ValueError("non-integer numeric token")

def reject_constant(token):
    raise ValueError("non-JSON numeric token")

def parse_response(text):
    decoder = json.JSONDecoder(
        object_pairs_hook=reject_duplicate_keys,
        parse_int=NumberToken,
        parse_float=reject_float,
        parse_constant=reject_constant,
    )
    start = len(text) - len(text.lstrip())
    value, end = decoder.raw_decode(text, start)
    if text[end:].strip():
        raise ValueError("multiple JSON values")
    if isinstance(value, dict) and "data" in value:
        value = value["data"]
    if not isinstance(value, list):
        raise ValueError("certificate response must be a list")
    return value

def safe_id(item, maximum):
    identifier = item.get("id") if isinstance(item, dict) else None
    if not isinstance(identifier, NumberToken):
        raise ValueError("certificate id is not an integer token")
    token = identifier.token
    if (not token or token[0] == "0" or not token.isascii() or
            not token.isdecimal() or int(token) <= 0 or int(token) > maximum):
        raise ValueError("certificate id is not canonical and safe")
    return token

try:
    entries = parse_response(os.environ["CERTIFICATE_LOOKUP_RESPONSE"])
    maximum = int(os.environ["MAX_SAFE_POSITIVE_INTEGER_ID"])
    wanted = os.environ["CERTIFICATE_LOOKUP_VALUE"]
    provider = os.environ["CERTIFICATE_LOOKUP_PROVIDER"]
    matches = []
    seen = set()
    for item in entries:
        identifier = safe_id(item, maximum)
        if identifier in seen:
            raise ValueError("duplicate certificate id")
        seen.add(identifier)
        domains = item.get("domain_names")
        if not isinstance(domains, list) or any(not isinstance(domain, str) for domain in domains):
            raise ValueError("certificate domain_names is malformed")
        if item.get("provider") == provider and wanted in domains:
            matches.append(identifier)
    if matches:
        print(matches[0], end="")
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    print("NPM certificate lookup response was malformed or contained an unsafe ID (response redacted).", file=sys.stderr)
    sys.exit(1)
PY
}

create_letsencrypt_certificate() {
  local domain="$1"
  # NPM crea 1 cert por set de dominios; aquí hacemos 1 dominio por cert (simple)
  local payload response
  payload="$(jq -n \
    --arg d "$domain" \
    '{
      provider: "letsencrypt",
      nice_name: $d,
      domain_names: [$d]
    }')"

  echo "Creando certificado Let's Encrypt para: $domain" >&2
  response="$(api_post "/api/nginx/certificates" "$payload")" || return 1
  extract_strict_positive_json_id "$response"
}

find_custom_certificate_id() {
  local name="$1"
  local response
  response="$(api_get "/api/nginx/certificates?per_page=200")" || {
    echo "NPM custom certificate lookup failed (request failed; response redacted)." >&2
    return 1
  }
  CERTIFICATE_LOOKUP_RESPONSE="$response" CERTIFICATE_LOOKUP_VALUE="$name" \
    MAX_SAFE_POSITIVE_INTEGER_ID="$MAX_SAFE_POSITIVE_INTEGER_ID" CERTIFICATE_LOOKUP_PROVIDER=other \
    python3 - <<'PY'
import json
import os
import sys

class NumberToken:
    def __init__(self, token):
        self.token = token

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate object key")
        result[key] = value
    return result

def reject_float(token):
    raise ValueError("non-integer numeric token")

def reject_constant(token):
    raise ValueError("non-JSON numeric token")

try:
    decoder = json.JSONDecoder(object_pairs_hook=reject_duplicate_keys,
                               parse_int=NumberToken, parse_float=reject_float,
                               parse_constant=reject_constant)
    text = os.environ["CERTIFICATE_LOOKUP_RESPONSE"]
    start = len(text) - len(text.lstrip())
    value, end = decoder.raw_decode(text, start)
    if text[end:].strip():
        raise ValueError("multiple JSON values")
    if isinstance(value, dict) and "data" in value:
        value = value["data"]
    if not isinstance(value, list):
        raise ValueError("certificate response must be a list")
    maximum = int(os.environ["MAX_SAFE_POSITIVE_INTEGER_ID"])
    wanted = os.environ["CERTIFICATE_LOOKUP_VALUE"]
    matches = []
    seen = set()
    for item in value:
        if not isinstance(item, dict) or not isinstance(item.get("id"), NumberToken):
            raise ValueError("certificate id is malformed")
        token = item["id"].token
        if (not token or token[0] == "0" or not token.isascii() or
                not token.isdecimal() or int(token) <= 0 or int(token) > maximum):
            raise ValueError("certificate id is not canonical and safe")
        if token in seen:
            raise ValueError("duplicate certificate id")
        seen.add(token)
        if "nice_name" not in item:
            raise ValueError("certificate nice_name is missing")
        nice_name = item["nice_name"]
        if nice_name is None:
            name = item.get("name")
        elif isinstance(nice_name, str):
            name = nice_name
        else:
            raise ValueError("certificate nice_name is malformed")
        if not isinstance(name, str):
            raise ValueError("certificate name is malformed")
        if item.get("provider") == "other" and name == wanted:
            matches.append(token)
    if matches:
        print(matches[0], end="")
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    print("NPM custom certificate lookup response was malformed or contained an unsafe ID (response redacted).", file=sys.stderr)
    sys.exit(1)
PY
}

create_custom_certificate_record() {
  local name="$1"
  local payload response
  payload="$(jq -n --arg n "$name" '{provider:"other", nice_name:$n}')"
  echo "Creando certificado custom en NPM: $name" >&2
  response="$(api_post "/api/nginx/certificates" "$payload")" || return 1
  extract_strict_positive_json_id "$response"
}

resolve_domain_for_prefix() {
  local prefix="$1"
  if [[ "$BASE_DOMAIN" == "${prefix}."* ]]; then
    printf '%s' "$BASE_DOMAIN"
  else
    printf '%s.%s' "$prefix" "$BASE_DOMAIN"
  fi
}

is_ipv4_address() {
  local address="$1" octet
  local -a octets
  [[ "$address" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$address"
  for octet in "${octets[@]}"; do
    (( octet <= 255 )) || return 1
  done
}

extract_nip_io_ip() {
  local host="$1" candidate
  if [[ "$host" =~ (^|\.)([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})\.nip\.io$ ]]; then
    candidate="${BASH_REMATCH[2]}"
    is_ipv4_address "$candidate" || return 1
    printf '%s' "$candidate"
    return 0
  fi
  return 1
}

derive_tls_verify_ip() {
  local domain="$1" encoded_ip="" explicit_ip="${NPM_TLS_VERIFY_IP:-}"

  if [[ "$BASE_DOMAIN" == *.nip.io ]]; then
    if ! encoded_ip="$(extract_nip_io_ip "$BASE_DOMAIN")"; then
      [[ -n "$explicit_ip" ]] || {
      echo "NPM TLS verification requires an unambiguous IPv4 address in BASE_DOMAIN (response redacted)." >&2
      return 1
      }
    fi
  elif [[ "$domain" == *.nip.io ]]; then
    if ! encoded_ip="$(extract_nip_io_ip "$domain")"; then
      [[ -n "$explicit_ip" ]] || {
      echo "NPM TLS verification requires an unambiguous IPv4 address in the nip.io host (response redacted)." >&2
      return 1
      }
    fi
  fi

  if [[ -n "$explicit_ip" ]]; then
    is_ipv4_address "$explicit_ip" || {
      echo "NPM TLS verification explicit IP is invalid (response redacted)." >&2
      return 1
    }
    if [[ -n "$encoded_ip" && "$explicit_ip" != "$encoded_ip" ]]; then
      echo "NPM TLS verification explicit IP conflicts with the nip.io address (response redacted)." >&2
      return 1
    fi
    printf '%s' "$explicit_ip"
  elif [[ -n "$encoded_ip" ]]; then
    printf '%s' "$encoded_ip"
  elif [[ "$domain" == *.nip.io ]]; then
    echo "NPM TLS verification could not derive the nip.io address (response redacted)." >&2
    return 1
  fi
}

build_tls_verify_args() {
  local domain="$1" tls_verify_ip ca_file
  tls_verify_ip="$(derive_tls_verify_ip "$domain")" || return 1
  TLS_VERIFY_ARGS=(--request GET --fail --silent --show-error --proto '=https' --tlsv1.2 --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" -o /dev/null)
  if [[ -n "$tls_verify_ip" ]]; then
    TLS_VERIFY_ARGS+=(--resolve "$domain:443:$tls_verify_ip")
  fi
  TLS_VERIFY_ARGS+=("https://$domain$NPM_TLS_VERIFY_PATH")
  if [[ "$TLS_MODE" == "local" || "$TLS_MODE" == "custom" ]]; then
    ca_file="${NPM_LOCAL_CERT_FILE/#~/$HOME}"
    if [[ ! -f "$ca_file" ]]; then
      echo "NPM certificate verification failed for $domain (explicit CA file missing; response redacted)." >&2
      return 1
    fi
    TLS_VERIFY_ARGS+=(--cacert "$ca_file")
  fi
}

sanitize_tls_suffix() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

local_cert_paths_for_prefix() {
  local prefix="$1"
  local cert_path key_path cert_dir key_dir cert_base key_base cert_ext key_ext suffix
  suffix="$(sanitize_tls_suffix "$prefix")"
  cert_path="${NPM_LOCAL_CERT_FILE/#~/$HOME}"
  key_path="${NPM_LOCAL_KEY_FILE/#~/$HOME}"
  cert_dir="$(dirname "$cert_path")"
  key_dir="$(dirname "$key_path")"
  cert_base="$(basename "$cert_path")"
  key_base="$(basename "$key_path")"
  cert_ext=""
  key_ext=""
  case "$cert_base" in
    *.*) cert_ext=".${cert_base##*.}"; cert_base="${cert_base%.*}" ;;
  esac
  case "$key_base" in
    *.*) key_ext=".${key_base##*.}"; key_base="${key_base%.*}" ;;
  esac
  printf '%s\n%s\n' "${cert_dir}/${cert_base}-${suffix}${cert_ext}" "${key_dir}/${key_base}-${suffix}${key_ext}"
}

configure_local_tls_for_prefix() {
  local prefix="$1"
  local suffix base_name cert_path key_path cert_stem key_stem
  suffix="$(sanitize_tls_suffix "$prefix")"
  cert_path="${NPM_LOCAL_CERT_FILE/#~/$HOME}"
  key_path="${NPM_LOCAL_KEY_FILE/#~/$HOME}"
  cert_stem="$(basename "$cert_path")"
  key_stem="$(basename "$key_path")"
  cert_stem="${cert_stem%.*}"
  key_stem="${key_stem%.*}"
  if [[ "$cert_stem" != *-"$suffix" || "$key_stem" != *-"$suffix" ]]; then
    cert_paths=()
    while IFS= read -r cert_file; do
      cert_paths[${#cert_paths[@]}]="$cert_file"
    done < <(local_cert_paths_for_prefix "$prefix")
    [ "${#cert_paths[@]}" -eq 2 ] || redacted_failure "local_certificate_paths_invalid"
    NPM_LOCAL_CERT_FILE="${cert_paths[0]}"
    NPM_LOCAL_KEY_FILE="${cert_paths[1]}"
  fi
  base_name="${NPM_LOCAL_CERT_NAME:-daiana-local-tls}"
  case "$base_name" in
    *-"$suffix") NPM_LOCAL_CERT_NAME="$base_name" ;;
    *) NPM_LOCAL_CERT_NAME="${base_name}-$suffix" ;;
  esac
}

ensure_local_certificate_files() {
  local domain="$1"
  local cert_path="${NPM_LOCAL_CERT_FILE/#~/$HOME}"
  local key_path="${NPM_LOCAL_KEY_FILE/#~/$HOME}"
  shift

  local requested_domain
  for requested_domain in "$domain" "$@"; do
    [[ -n "$requested_domain" ]] || redacted_failure "local_certificate_domain_missing"
  done

  if [[ -f "$cert_path" && -f "$key_path" ]]; then
    for requested_domain in "$domain" "$@"; do
      openssl x509 -in "$cert_path" -noout -checkhost "$requested_domain" >/dev/null 2>&1 || {
        echo "NPM local certificate SAN does not cover $requested_domain; refusing TLS mutation." >&2
        return 1
      }
    done
    return 0
  fi

  echo "Generando certificado local auto-firmado para $domain" >&2
  mkdir -p "$(dirname "$cert_path")"
  local config_file san_index
  config_file="$(mktemp "${TMPDIR:-/tmp}/npm-local-cert.XXXXXX")" || return 1
  {
    printf '%s\n' '[req]' 'prompt = no' 'distinguished_name = req_distinguished_name' 'x509_extensions = req_ext' '[req_distinguished_name]'
    printf 'CN = %s\n' "$domain"
    printf '%s\n' '[req_ext]' 'subjectAltName = @alt_names' '[alt_names]'
    san_index=1
    for requested_domain in "$domain" "$@"; do
      printf 'DNS.%s = %s\n' "$san_index" "$requested_domain"
      san_index=$((san_index + 1))
    done
  } > "$config_file"
  if ! openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$key_path" \
    -out "$cert_path" \
    -subj "/CN=$domain" -config "$config_file" >/dev/null 2>&1; then
    rm -f "$config_file"
    return 1
  fi
  rm -f "$config_file"
  chmod 640 "$key_path"
  chgrp 65533 "$key_path" 2>/dev/null || true
  for requested_domain in "$domain" "$@"; do
    openssl x509 -in "$cert_path" -noout -checkhost "$requested_domain" >/dev/null 2>&1 || {
      echo "Generated local certificate SAN does not cover $requested_domain; refusing TLS mutation." >&2
      return 1
    }
  done
}

tls_domain_for_service() {
  local prefix domain_var
  prefix="$1"
  domain_var="DOMAIN_$(printf '%s' "$prefix" | tr '[:lower:]' '[:upper:]')"
  if [[ -n "${!domain_var:-}" ]]; then
    printf '%s' "${!domain_var}"
  elif [[ "$BASE_DOMAIN" == "${prefix}."* ]]; then
    printf '%s' "$BASE_DOMAIN"
  else
    printf '%s.%s' "$prefix" "$BASE_DOMAIN"
  fi
}

collect_tls_domains() {
  local entry prefix domain
  TLS_DOMAINS=()
  for entry in "${SERVICES[@]}"; do
    IFS=':' read -r prefix _ _ <<<"$entry"
    if [[ -n "$ONLY_PREFIX" && "$ONLY_PREFIX" != "$prefix" ]]; then
      continue
    fi
    domain="$(tls_domain_for_service "$prefix")"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ && "$domain" == *.* ]] || {
      echo "TLS hostname derivation is incomplete or invalid for $prefix; refusing local certificate generation." >&2
      return 1
    }
    TLS_DOMAINS+=("$domain")
  done
  [[ ${#TLS_DOMAINS[@]} -gt 0 ]] || { echo "TLS hostname list is empty; refusing local certificate generation." >&2; return 1; }
}

upload_custom_certificate() {
  local cert_id="$1"
  local cert_file="$2"
  local key_file="$3"
  local cert_path="${cert_file/#~/$HOME}"
  local key_path="${key_file/#~/$HOME}"

  [[ -f "$cert_path" ]] || { echo "Falta certificado local: $cert_path" >&2; return 1; }
  [[ -f "$key_path" ]] || { echo "Falta clave local: $key_path" >&2; return 1; }

  echo "Subiendo certificado custom a NPM (id=$cert_id)" >&2
  local curl_status
  local -a auth_args=(--config "${NPM_AUTH_CONFIG_FILE:-/dev/null}")
  if response="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" -X POST "$NPM_API_URL/api/nginx/certificates/$cert_id/upload" \
    "${auth_args[@]}" \
    -F "certificate=@$cert_path" \
    -F "certificate_key=@$key_path" \
    -w '\n%{http_code}')"; then
    curl_status=0
  else
    curl_status=$?
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$curl_status" -ne 0 ]]; then
    echo "NPM certificate upload connection failure (curl exit $curl_status)." >&2
    return 1
  fi
  if [[ "$status" != 2* ]]; then
    echo "NPM certificate upload failed (HTTP ${status:-unavailable}; response redacted)." >&2
    return 1
  fi
}

ensure_custom_certificate() {
  local cert_id
  if ! cert_id="$(find_custom_certificate_id "$NPM_LOCAL_CERT_NAME")"; then
    echo "NPM custom certificate lookup failed closed; refusing to create a duplicate certificate." >&2
    return 1
  fi
  if [[ -z "$cert_id" || "$cert_id" == "null" ]]; then
    cert_id="$(create_custom_certificate_record "$NPM_LOCAL_CERT_NAME")"
  fi
  is_positive_integer_id "$cert_id" || { echo "NPM custom certificate application returned an invalid certificate ID; refusing to continue." >&2; return 1; }
  upload_custom_certificate "$cert_id" "$NPM_LOCAL_CERT_FILE" "$NPM_LOCAL_KEY_FILE" || return 1
  echo "$cert_id"
}

ensure_certificate() {
  local domain="$1"
  local cert_id=""
  if ! cert_id="$(find_certificate_id_for_domain "$domain")"; then
    echo "NPM certificate lookup failed closed for $domain; refusing to create a duplicate certificate." >&2
    return 1
  fi
  if [[ -n "$cert_id" && "$cert_id" != "null" ]]; then
    is_positive_integer_id "$cert_id" || { echo "NPM certificate lookup returned an invalid certificate ID for $domain; refusing to continue." >&2; return 1; }
    echo "Cert existente para $domain (id=$cert_id)" >&2
    echo "$cert_id"
    return 0
  fi

  if ! cert_id="$(create_letsencrypt_certificate "$domain")"; then
    echo "NPM certificate issuance failed for $domain; refusing to continue without TLS." >&2
    return 1
  fi
  if is_positive_integer_id "$cert_id"; then
    echo "Cert Let's Encrypt creado para $domain (id=$cert_id)" >&2
    echo "$cert_id"
    return 0
  fi

  if ! cert_id="$(find_certificate_id_for_domain "$domain")"; then
    echo "NPM certificate lookup failed closed for $domain after issuance; refusing to continue without TLS." >&2
    return 1
  fi
  if is_positive_integer_id "$cert_id"; then
    echo "Cert encontrado para $domain después de crear (id=$cert_id)" >&2
    echo "$cert_id"
    return 0
  fi

  echo "Certificate issuance did not return a usable certificate ID for $domain; refusing to continue without TLS." >&2
  return 1
}

certificate_expiry_epoch() {
  local expiry="$1"
  if [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$expiry" '+%s' 2>/dev/null || \
      date -u -d "$expiry" '+%s' 2>/dev/null
  elif [[ "$expiry" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    date -u -j -f '%Y-%m-%d %H:%M:%S' "$expiry" '+%s' 2>/dev/null || \
      date -u -d "$expiry UTC" '+%s' 2>/dev/null
  else
    return 1
  fi
}

verify_certificate_for_domain() {
  local cert_id="$1"
  local domain="$2"
  local certificate provider status expires_on expiry_epoch cert_path returned_id

  is_positive_integer_id "$cert_id" || return 1
  certificate="$(api_get "/api/nginx/certificates/$cert_id")" || return 1
  if ! returned_id="$(extract_strict_positive_json_id "$certificate")" || [[ "$returned_id" != "$cert_id" ]]; then
    echo "NPM certificate verification failed for $domain (returned certificate ID did not exactly match the requested ID; response redacted)." >&2
    return 1
  fi
  provider="$(jq -r '.provider // empty' <<<"$certificate")"
  status="$(jq -r '.status // empty' <<<"$certificate")"
  case "$provider" in
    letsencrypt)
      if [[ "$status" != "issued" ]]; then
        echo "NPM certificate verification failed for $domain (ACME status invalid; response redacted)." >&2
        return 1
      fi
      if ! jq -e --arg domain "$domain" '((.domain_names // []) | index($domain)) != null' <<<"$certificate" >/dev/null; then
        echo "NPM certificate verification failed for $domain (ACME hostname not listed; response redacted)." >&2
        return 1
      fi
      ;;
    other)
      cert_path="${NPM_LOCAL_CERT_FILE/#~/$HOME}"
      if [[ ! -f "$cert_path" ]] || ! openssl x509 -in "$cert_path" -noout >/dev/null 2>&1; then
        echo "NPM certificate verification failed for $domain (custom PEM invalid; response redacted)." >&2
        return 1
      fi
      if ! openssl x509 -in "$cert_path" -noout -checkend 0 >/dev/null 2>&1; then
        echo "NPM certificate verification failed for $domain (custom PEM expired; response redacted)." >&2
        return 1
      fi
      if ! openssl x509 -in "$cert_path" -noout -checkhost "$domain" >/dev/null 2>&1; then
        echo "NPM certificate verification failed for $domain (custom SAN/hostname mismatch; response redacted)." >&2
        return 1
      fi
      ;;
    *)
      echo "NPM certificate verification failed for $domain (unsupported provider; response redacted)." >&2
      return 1
      ;;
  esac
  expires_on="$(jq -r '.expires_on // empty' <<<"$certificate")"
  if [[ -z "$expires_on" ]] || ! expiry_epoch="$(certificate_expiry_epoch "$expires_on")" || [[ "$expiry_epoch" -le "$(date -u '+%s')" ]]; then
    echo "NPM certificate verification failed for $domain (expiry invalid; response redacted)." >&2
    return 1
  fi

  build_tls_verify_args "$domain" || return 1
  if ! curl "${TLS_VERIFY_ARGS[@]}"; then
    echo "NPM certificate verification failed for $domain (TLS handshake or hostname verification failed)." >&2
    return 1
  fi
}

# Busca proxy host existente por dominio
find_proxy_host_id_for_domain() {
  local domain="$1"
  local inventory_file matches match_count id

  inventory_file="$(capture_proxy_host_inventory "$((ROLLBACK_SEQUENCE + 1))")" || return 1
  matches="$(jq -r --arg d "$domain" '
    [ .[]
      | select((.domain_names // []) | index($d))
      | .id
    ]
    | if all(.[]; type == "number" and . > 0 and floor == .) then .[] else error end
  ' "$inventory_file")" || return 1
  match_count=0
  [[ -z "$matches" ]] || match_count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  if [[ "$match_count" -gt 1 ]]; then
    echo "NPM proxy host lookup found multiple hosts for $domain; refusing to mutate an ambiguous target." >&2
    return 1
  fi
  [[ "$match_count" -eq 0 ]] && return 0
  id="$matches"
  is_positive_integer_id "$id" || return 1
  printf '%s' "$id"
}

proxy_advanced_config() {
  local prefix="$1"

  case "$prefix" in
    daiana)
      cat <<'EOF'
large_client_header_buffers 4 16k;
proxy_connect_timeout 60s;
proxy_send_timeout 60s;
proxy_read_timeout 60s;
send_timeout 60s;
proxy_buffer_size 128k;
proxy_buffers 4 256k;
proxy_busy_buffers_size 256k;
client_max_body_size 10M;
EOF
      ;;
    supa)
      cat <<'EOF'
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port $server_port;
EOF
      ;;
  esac
}

proxy_host_payload() {
  local prefix="$1"
  local domain="$2"
  local upstream_host="$3"
  local upstream_port="$4"
  local cert_id="$5"

  local cert_json=0
  if [[ -n "$cert_id" && "$cert_id" != "null" ]]; then
    is_positive_integer_id "$cert_id" || return 1
    cert_json="$cert_id"
  fi

  local advanced_config
  advanced_config="$(proxy_advanced_config "$prefix")"

  jq -n \
    --arg d "$domain" \
    --arg host "$upstream_host" \
    --argjson port "$upstream_port" \
    --argjson cert "$cert_json" \
    --arg adv "$advanced_config" \
    '{
      domain_names: [$d],
      forward_scheme: "http",
      forward_host: $host,
      forward_port: $port,
      certificate_id: $cert,
      ssl_forced: ($cert != 0),
      hsts_enabled: ($cert != 0),
      hsts_subdomains: false,
      trust_forwarded_proto: true,
      http2_support: ($cert != 0),
      block_exploits: true,
      caching_enabled: false,
      allow_websocket_upgrade: true,
      access_list_id: 0,
      advanced_config: (if $adv == "" then null else $adv end),
      enabled: true,
      locations: []
    }'
}

create_proxy_host() {
  local prefix="$1"
  local domain="$2"
  local upstream_host="$3"
  local upstream_port="$4"
  local cert_id="$5"
  local payload before_file sequence raw status body curl_status id evidence_file
  local -a auth_args=(--config "${NPM_AUTH_CONFIG_FILE:-/dev/null}")

  payload="$(proxy_host_payload "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id")"
  echo "Creando Proxy Host: $domain -> http://$upstream_host:$upstream_port (cert=$cert_id)" >&2
  before_file="$6"
  sequence="$7"
  if raw="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" -X POST "$NPM_API_URL/api/nginx/proxy-hosts" \
    "${auth_args[@]}" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    -w '\n%{http_code}')"; then
    curl_status=0
  else
    curl_status=$?
  fi
  status="${raw##*$'\n'}"
  body="${raw%$'\n'*}"
  if [[ "$curl_status" -ne 0 || "$status" != 2* ]]; then
    ROLLBACK_RETAIN_DIAGNOSTICS=1
    : > "$ROLLBACK_DIR/retain-diagnostics"
    evidence_file="$ROLLBACK_DIR/create-failure-$sequence.txt"
    {
      printf 'curl_exit=%s\nhttp_status=%s\nraw_response_begin\n' "$curl_status" "${status:-unavailable}"
      printf '%s\n' "$raw"
      printf 'raw_response_end\n'
    } > "$evidence_file"
    chmod 600 "$evidence_file"
    if recover_created_proxy_host "$before_file" "$payload" "$sequence" >/dev/null; then
      echo "NPM proxy host creation returned HTTP/transport failure after a possible commit; unique new host was journaled for compensation (raw diagnostics retained)." >&2
    else
      echo "NPM proxy host creation returned HTTP/transport failure; complete inventory recovery did not prove a unique new host (raw diagnostics retained)." >&2
    fi
    return 1
  fi

  # Keep the raw successful response available: jq must not prevent recovery
  # when NPM reports creation but returns malformed or incomplete JSON.
  if ! id="$(extract_create_response_id "$body")"; then
    # A valid JSON value that fails strict extraction is an invalid response,
    # not an inventory-recovery case. Recovery remains limited to genuinely
    # malformed bodies so nested, duplicate, array, null, and multi-value
    # payloads cannot be converted into an apparently valid ID.
    if jq -e -s 'length >= 1' <<<"$body" >/dev/null 2>&1; then
      echo "NPM proxy host creation returned an invalid ID type or representation; refusing rollback deletion (response redacted). Manual cleanup may be required." >&2
      mark_rollback_incomplete
      return 1
    fi
    recover_created_proxy_host "$before_file" "$payload" "$sequence" >/dev/null
    return $?
  fi

  if ! validate_created_proxy_host_id "$before_file" "$payload" "$id" "$sequence"; then
    echo "NPM proxy host creation returned an untrusted ID; refusing rollback deletion (response redacted). Manual cleanup may be required." >&2
    mark_rollback_incomplete
    return 1
  fi
  register_created_proxy_host "$id"
  printf '%s' "$id"
}

update_proxy_host() {
  local prefix="$1"
  local domain="$2"
  local upstream_host="$3"
  local upstream_port="$4"
  local cert_id="$5"
  local id="$6"
  local payload response status body curl_status
  local -a auth_args=(--config "${NPM_AUTH_CONFIG_FILE:-/dev/null}")

  is_positive_integer_id "$id" || return 1

  payload="$(proxy_host_payload "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id")"
  echo "Actualizando Proxy Host: $domain (id=$id) -> http://$upstream_host:$upstream_port (cert=$cert_id)"
  if response="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" -X PUT "$NPM_API_URL/api/nginx/proxy-hosts/$id" \
    "${auth_args[@]}" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    -w '\n%{http_code}')"; then
    curl_status=0
  else
    curl_status=$?
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$curl_status" -ne 0 ]]; then
    echo "NPM proxy host application connection failure (curl exit $curl_status)." >&2
    return 1
  fi
  if [[ "$status" != 2* ]]; then
    echo "NPM proxy host application failed (HTTP ${status:-unavailable}; response redacted)." >&2
    return 1
  fi
}

init_proxy_rollback() {
  ROLLBACK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/npm-bootstrap-rollback.XXXXXX")"
  ROLLBACK_RECORDS="$ROLLBACK_DIR/records"
  ROLLBACK_INCOMPLETE=0
  ROLLBACK_RETAIN_DIAGNOSTICS=0
  : > "$ROLLBACK_RECORDS"
}

mark_rollback_incomplete() {
  ROLLBACK_INCOMPLETE=1
  [[ -z "$ROLLBACK_DIR" ]] || : > "$ROLLBACK_DIR/incomplete"
}

capture_proxy_host_inventory() {
  local sequence="$1"
  local inventory_file="$ROLLBACK_DIR/inventory-$sequence.json"
  local page=1 per_page=200 expected_pages total inventory data all_items envelope_file
  local -a pages=()

  inventory="$(api_get "/api/nginx/proxy-hosts?per_page=$per_page")" || return 1
  if jq -e -s 'length == 1 and (.[0] | type == "array")' <<<"$inventory" >/dev/null 2>&1; then
    normalize_proxy_host_list_inventory "$inventory" "$per_page" "$inventory_file" || return 1
    printf '%s' "$inventory_file"
    return 0
  fi

  while :; do
    if (( page == 1 )); then
      :
    else
      inventory="$(api_get "/api/nginx/proxy-hosts?page=$page&per_page=$per_page")" || return 1
    fi
    envelope_file="$ROLLBACK_DIR/envelope-$sequence-$page.json"
    normalize_proxy_host_envelope_inventory "$inventory" "$page" "$per_page" "$envelope_file" || return 1
    inventory="$(<"$envelope_file")"
    if ! jq -e --argjson expected_page "$page" --argjson expected_per_page "$per_page" --argjson max "$MAX_SAFE_POSITIVE_INTEGER_ID" '
      . as $response |
      type == "object" and
      (.data | type == "array") and
      (.page | type == "number" and floor == . and . > 0) and
      (.per_page | type == "number" and floor == . and . > 0) and
      (.total | type == "number" and floor == . and . >= 0) and
      (.page == $expected_page) and (.per_page == $expected_per_page) and
       ($response.data | all(.[]; type == "object" and (.id | type) == "number" and (.id | isfinite) and .id > 0 and ((.id | floor) == .id) and .id <= $max)) and
      ($response.data | length <= $response.per_page) and
      ($response.total >= ($response.page - 1) * $response.per_page + ($response.data | length))
     ' <<<"$inventory" >/dev/null; then
      return 1
    fi
    if (( page == 1 )); then
      total="$(jq -er '.total' <<<"$inventory")" || return 1
      per_page="$(jq -er '.per_page' <<<"$inventory")" || return 1
      expected_pages=$(( (total + per_page - 1) / per_page ))
      (( expected_pages < 1 )) && expected_pages=1
    elif ! jq -e --argjson expected_total "$total" --argjson expected_per_page "$per_page" '
      .total == $expected_total and .per_page == $expected_per_page
    ' <<<"$inventory" >/dev/null; then
      return 1
    fi
    if (( page > expected_pages )); then
      return 1
    fi
    data="$(jq -c '.data' <<<"$inventory")" || return 1
    local data_count expected_count
    data_count="$(jq -er 'length' <<<"$data")" || return 1
    if (( page < expected_pages )); then
      expected_count=$per_page
    else
      expected_count=$(( total - (page - 1) * per_page ))
    fi
    (( data_count == expected_count )) || return 1
    pages+=("$data")
    if (( page == expected_pages )); then
      all_items="$(printf '%s\n' "${pages[@]}" | jq -s 'add')" || return 1
       if ! jq -e --argjson expected_total "$total" --argjson max "$MAX_SAFE_POSITIVE_INTEGER_ID" '
        (length == $expected_total)
        and ([.[].id] | length == (unique | length))
        and all(.[]; type == "object" and (.id | type) == "number" and (.id | isfinite) and .id > 0 and ((.id | floor) == .id) and .id <= $max)
       ' <<<"$all_items" >/dev/null; then
        return 1
      fi
      break
    fi
    page=$((page + 1))
  done

  printf '%s\n' "${pages[@]}" | jq -s 'add | sort_by(.id)' > "$inventory_file" || return 1
  printf '%s' "$inventory_file"
}

normalize_proxy_host_envelope_inventory() {
  local response="$1"
  local expected_page="$2"
  local expected_per_page="$3"
  local output_file="$4"

  INVENTORY_RESPONSE="$response" MAX_SAFE_POSITIVE_INTEGER_ID="$MAX_SAFE_POSITIVE_INTEGER_ID" \
    EXPECTED_PAGE="$expected_page" EXPECTED_PER_PAGE="$expected_per_page" \
    python3 - "$output_file" <<'PY'
import json
import os
import sys

class IntegerToken:
    def __init__(self, token):
        self.token = token

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate object key")
        result[key] = value
    return result

def reject_float(token):
    raise ValueError("non-integer numeric token")

def reject_constant(token):
    raise ValueError("non-JSON numeric token")

def convert(value):
    if isinstance(value, IntegerToken):
        return int(value.token)
    if isinstance(value, list):
        return [convert(item) for item in value]
    if isinstance(value, dict):
        return {key: convert(item) for key, item in value.items()}
    return value

try:
    text = os.environ["INVENTORY_RESPONSE"]
    decoder = json.JSONDecoder(object_pairs_hook=reject_duplicate_keys,
                               parse_int=IntegerToken, parse_float=reject_float,
                               parse_constant=reject_constant)
    start = len(text) - len(text.lstrip())
    value, end = decoder.raw_decode(text, start)
    if text[end:].strip() or not isinstance(value, dict):
        raise ValueError("not one JSON envelope")
    maximum = int(os.environ["MAX_SAFE_POSITIVE_INTEGER_ID"])
    expected_page = int(os.environ["EXPECTED_PAGE"])
    expected_per_page = int(os.environ["EXPECTED_PER_PAGE"])
    for key in ("page", "per_page", "total"):
        token = value.get(key)
        if not isinstance(token, IntegerToken):
            raise ValueError("pagination metadata is not an integer token")
        if (not token.token or (key != "total" and token.token[0] == "0") or
                not token.token.isascii() or not token.token.isdecimal() or
                int(token.token) > maximum):
            raise ValueError(f"pagination metadata is not canonical for {key}: {token.token!r}")
    if value["page"].token != str(expected_page) or value["per_page"].token != str(expected_per_page):
        raise ValueError("pagination metadata changed")
    total = int(value["total"].token)
    if total < 0 or not isinstance(value.get("data"), list):
        raise ValueError("pagination envelope is malformed")
    if len(value["data"]) > expected_per_page:
        raise ValueError("page contains too many records")
    for item in value["data"]:
        if not isinstance(item, dict) or not isinstance(item.get("id"), IntegerToken):
            raise ValueError("proxy host id is not an integer token")
        token = item["id"].token
        if (not token or token[0] == "0" or not token.isascii() or not token.isdecimal() or
                int(token) <= 0 or int(token) > maximum):
            raise ValueError("proxy host id is not canonical and safe")
    with open(sys.argv[1], "w", encoding="utf-8") as output:
        json.dump(convert(value), output, separators=(",", ":"))
except (KeyError, TypeError, ValueError, json.JSONDecodeError, OSError) as error:
    print(f"proxy inventory envelope rejected ({type(error).__name__}: {error}; response redacted)", file=sys.stderr)
    sys.exit(1)
PY
}

normalize_proxy_host_list_inventory() {
  local response="$1"
  local per_page="$2"
  local output_file="$3"

  INVENTORY_RESPONSE="$response" MAX_SAFE_POSITIVE_INTEGER_ID="$MAX_SAFE_POSITIVE_INTEGER_ID" python3 - "$per_page" "$output_file" <<'PY'
import json
import sys
import os

per_page = int(sys.argv[1])
output_file = sys.argv[2]
max_safe_id = int(os.environ["MAX_SAFE_POSITIVE_INTEGER_ID"])

def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate object key")
        result[key] = value
    return result

text = os.environ["INVENTORY_RESPONSE"]
decoder = json.JSONDecoder(object_pairs_hook=reject_duplicate_keys)
try:
    start = len(text) - len(text.lstrip())
    value, end = decoder.raw_decode(text, start)
    if text[end:].strip() or not isinstance(value, list):
        raise ValueError("not one JSON array")
    if len(value) >= per_page:
        raise ValueError("array completeness is unproven")

    ids = []
    for item in value:
        if not isinstance(item, dict) or isinstance(item.get("id"), bool):
            raise ValueError("array item must have an integer id")
        identifier = item.get("id")
        if not isinstance(identifier, int) or identifier <= 0 or identifier > max_safe_id:
            raise ValueError("array item must have a positive integer id")
        ids.append(identifier)
    if len(ids) != len(set(ids)):
        raise ValueError("duplicate inventory id")

    with open(output_file, "w", encoding="utf-8") as output:
        json.dump(sorted(value, key=lambda item: item["id"]), output, separators=(",", ":"))
except (ValueError, TypeError, json.JSONDecodeError, OSError):
    sys.exit(1)
PY
}

is_positive_integer_id() {
  local id="${1:-}"
  [[ "$id" =~ ^[1-9][0-9]*$ ]] || return 1
  (( ${#id} < ${#MAX_SAFE_POSITIVE_INTEGER_ID} )) && return 0
  (( ${#id} > ${#MAX_SAFE_POSITIVE_INTEGER_ID} )) && return 1
  # Equal-length canonical decimal strings compare lexicographically here.
  # shellcheck disable=SC2071
  [[ "$id" < "$MAX_SAFE_POSITIVE_INTEGER_ID" || "$id" == "$MAX_SAFE_POSITIVE_INTEGER_ID" ]]
}

extract_strict_positive_json_id() {
  # Parse the complete JSON text structurally.  Python's decoder preserves the
  # original integer token, lets us reject duplicate object keys, and makes it
  # possible to reject a second JSON value without using a regex extractor.
  MAX_SAFE_POSITIVE_INTEGER_ID="$MAX_SAFE_POSITIVE_INTEGER_ID" python3 -c '
import json
import sys
import os

def duplicate_rejecting_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate object key")
        result[key] = value
    return result

def preserve_integer(token):
    return ("integer", token)

def preserve_non_integer(token):
    return ("non-integer", token)

def reject_constant(token):
    raise ValueError("non-JSON number")

def reject_nested_ids(value, depth=0):
    if isinstance(value, dict):
        if depth > 0 and "id" in value:
            raise ValueError("nested id key")
        for child in value.values():
            reject_nested_ids(child, depth + 1)
    elif isinstance(value, list):
        for child in value:
            reject_nested_ids(child, depth + 1)

text = sys.stdin.read()
start = 0
while start < len(text) and text[start] in " \t\r\n":
    start += 1
try:
    decoder = json.JSONDecoder(
        object_pairs_hook=duplicate_rejecting_object,
        parse_int=preserve_integer,
        parse_float=preserve_non_integer,
        parse_constant=reject_constant,
    )
    value, end = decoder.raw_decode(text, start)
    if any(character not in " \t\r\n" for character in text[end:]):
        raise ValueError("multiple JSON values or trailing data")
    if not isinstance(value, dict) or "id" not in value:
        raise ValueError("top-level object with id required")
    reject_nested_ids(value)
    id_value = value["id"]
    if (not isinstance(id_value, tuple) or len(id_value) != 2):
        raise ValueError("id must be an integer")
    kind, token = id_value
    if (kind != "integer" or not token or token[0] == "0"
            or any(character < "0" or character > "9" for character in token)
            or int(token) <= 0 or int(token) > int(os.environ["MAX_SAFE_POSITIVE_INTEGER_ID"])):
        raise ValueError("non-canonical positive integer")
    print(token, end="")
except (ValueError, TypeError, json.JSONDecodeError):
    sys.exit(1)
' <<<"$1"
}

recover_created_proxy_host() {
  local before_file="$1"
  local payload="$2"
  local sequence="$3"
  local after_file matches match_count id

  if ! after_file="$(capture_proxy_host_inventory "$sequence")"; then
    echo "NPM proxy host create succeeded without a usable ID; inventory reread failed (response redacted). Rollback incomplete; manual cleanup required." >&2
    mark_rollback_incomplete
    return 1
  fi

  matches="$(jq -r --argjson payload "$payload" --slurpfile before "$before_file" --argjson max "$MAX_SAFE_POSITIVE_INTEGER_ID" '
    ($before[0] | map(.id)) as $before_ids
    | ($payload | keys_unsorted) as $payload_keys
    | [ .[]
        | . as $candidate
         | select(($candidate.id | type) == "number" and ($candidate.id | isfinite) and $candidate.id > 0 and (($candidate.id | floor) == $candidate.id) and $candidate.id <= $max)
        | ($candidate.id) as $candidate_id
        | select(($before_ids | index($candidate_id)) == null)
        | select($candidate.domain_names == $payload.domain_names
          and $candidate.forward_scheme == $payload.forward_scheme
          and $candidate.forward_host == $payload.forward_host
          and $candidate.forward_port == $payload.forward_port)
        | select([ $payload_keys[] as $key
            | select($candidate[$key] != $payload[$key]) ] | length == 0)
      ]
    | .[] | .id
    ' "$after_file")" || {
    echo "NPM proxy host create succeeded without a usable ID; inventory comparison was invalid (response redacted). Rollback incomplete; manual cleanup required." >&2
    mark_rollback_incomplete
    return 1
  }
  match_count=0
  [[ -z "$matches" ]] || match_count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  if [[ "$match_count" != "1" ]]; then
    echo "NPM proxy host create succeeded without a usable ID; inventory comparison found $match_count unambiguous matches (response redacted). Rollback incomplete; manual cleanup required." >&2
    mark_rollback_incomplete
    return 1
  fi
  id="$matches"
  register_created_proxy_host "$id"
  printf '%s' "$id"
}

validate_created_proxy_host_id() {
  local before_file="$1"
  local payload="$2"
  local id="$3"
  local sequence="$4"
  local after_file candidate

  is_positive_integer_id "$id" || return 1
  if ! after_file="$(capture_proxy_host_inventory "$sequence")"; then
    return 1
  fi
  candidate="$(jq -e --argjson id "$id" --argjson payload "$payload" --slurpfile before "$before_file" --argjson max "$MAX_SAFE_POSITIVE_INTEGER_ID" '
    ($before[0] | map(.id)) as $before_ids
    | [ .[]
        | . as $candidate
         | select(($candidate.id | type) == "number" and ($candidate.id | isfinite) and $candidate.id > 0 and (($candidate.id | floor) == $candidate.id) and $candidate.id <= $max)
        | select($candidate.id == $id)
        | select(($before_ids | index($id)) == null)
        | select([ $payload | keys_unsorted[] as $key
            | select($candidate[$key] != $payload[$key]) ] | length == 0)
      ]
    | select(length == 1)
    | .[0].id
   ' "$after_file")" || return 1
  [[ "$candidate" == "$id" ]] && is_positive_integer_id "$candidate"
}

capture_proxy_host_state() {
  local id="$1"
  local sequence="$2"
  local state_file="$ROLLBACK_DIR/state-$sequence.json"
  local state

  is_positive_integer_id "$id" || return 1

  # A host may be selected more than once when domains or service prefixes
  # overlap. Keep the earliest snapshot: later snapshots are already mutated
  # state and would make rollback restore only an intermediate configuration.
  while IFS='|' read -r recorded_kind recorded_id _; do
    if [[ "$recorded_kind" == "existing" && "$recorded_id" == "$id" ]]; then
      return 0
    fi
  done < "$ROLLBACK_RECORDS"

  state="$(api_get "/api/nginx/proxy-hosts/$id")" || return 1
  if ! jq -e --argjson id "$id" 'type == "object" and .id == $id' <<<"$state" >/dev/null; then
    return 1
  fi
  printf '%s' "$state" > "$state_file"
  printf 'existing|%s|%s\n' "$id" "$state_file" >> "$ROLLBACK_RECORDS"
}

register_created_proxy_host() {
  local id="$1"
  is_positive_integer_id "$id" || return 1
  printf 'created|%s|\n' "$id" >> "$ROLLBACK_RECORDS"
}

extract_create_response_id() {
  local body="$1"
  extract_strict_positive_json_id "$body"
}

same_proxy_host_state() {
  local expected="$1"
  local actual="$2"
  proxy_host_mutable_payload "$expected" > "$ROLLBACK_DIR/expected.normalized" || return 1
  proxy_host_mutable_payload "$actual" > "$ROLLBACK_DIR/actual.normalized" || return 1
  cmp -s "$ROLLBACK_DIR/expected.normalized" "$ROLLBACK_DIR/actual.normalized"
}

# NPM GET responses contain immutable metadata and runtime-only fields that are
# rejected by PUT. Keep rollback and read-back comparison on the same mutable
# projection accepted by the existing proxy-host payload builder.
proxy_host_mutable_payload() {
  local state="$1"
  jq -e '
    . as $object
    | select(type == "object")
    | [
      "domain_names", "forward_scheme", "forward_host", "forward_port",
      "certificate_id", "ssl_forced", "hsts_enabled", "hsts_subdomains",
      "trust_forwarded_proto", "http2_support", "block_exploits",
      "caching_enabled", "allow_websocket_upgrade", "access_list_id",
      "advanced_config", "enabled", "locations"
      ] as $required
    | select($required | all(.[]; . as $key | $object | has($key)))
    | {
        domain_names, forward_scheme, forward_host, forward_port,
        certificate_id, ssl_forced, hsts_enabled, hsts_subdomains,
        trust_forwarded_proto, http2_support, block_exploits,
        caching_enabled, allow_websocket_upgrade, access_list_id,
        advanced_config, enabled, locations
      }
  ' <<<"$state"
}

restore_proxy_host() {
  local id="$1"
  local state_file="$2"
  local prior current payload

  is_positive_integer_id "$id" || return 1

  prior="$(<"$state_file")"
  payload="$(proxy_host_mutable_payload "$prior")" || return 1
  npm_request PUT "/api/nginx/proxy-hosts/$id" "$payload" >/dev/null || return 1
  current="$(api_get "/api/nginx/proxy-hosts/$id")" || return 1
  same_proxy_host_state "$prior" "$current"
}

remove_created_proxy_host() {
  local id="$1"
  local response status curl_status current
  local -a auth_args=(--config "${NPM_AUTH_CONFIG_FILE:-/dev/null}")

  is_positive_integer_id "$id" || return 1

  if response="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" \
    -X DELETE "$NPM_API_URL/api/nginx/proxy-hosts/$id" \
    "${auth_args[@]}" \
    -w '\n%{http_code}')"; then
    curl_status=0
  else
    curl_status=$?
  fi
  status="${response##*$'\n'}"
  if [[ "$curl_status" -ne 0 || "$status" != 2* ]]; then
    echo "NPM proxy host deletion failed (HTTP ${status:-unavailable}; response redacted)." >&2
    return 1
  fi

  # Only a confirmed NPM 404 proves the resource is absent. A transport
  # failure, malformed response, or any other status is rollback-incomplete.
  if current="$(curl -sS --connect-timeout "$NPM_CONNECT_TIMEOUT" --max-time "$NPM_OPERATION_TIMEOUT" \
    -H 'Accept: application/json' "$NPM_API_URL/api/nginx/proxy-hosts/$id" \
    "${auth_args[@]}" \
    -w '\n%{http_code}')"; then
    curl_status=0
  else
    curl_status=$?
  fi
  status="${current##*$'\n'}"
  if [[ "$curl_status" -ne 0 || "$status" != "404" ]]; then
    echo "NPM proxy host deletion could not confirm absence (HTTP ${status:-unavailable}; response redacted)." >&2
    return 1
  fi
  return 0
}

rollback_proxy_hosts() {
  local kind id state_file rollback_failed=0 i record
  local -a records=()
  [[ -n "$ROLLBACK_RECORDS" && -f "$ROLLBACK_RECORDS" ]] || return 0
  while IFS= read -r record; do
    records+=("$record")
  done < "$ROLLBACK_RECORDS"
  # Restore in reverse mutation order. Existing hosts are deduplicated at
  # capture time, so the first snapshot remains the restoration target.
  for ((i=${#records[@]} - 1; i >= 0; i--)); do
    IFS='|' read -r kind id state_file <<<"${records[i]}"
    if ! is_positive_integer_id "$id"; then
      rollback_failed=1
      continue
    fi
    case "$kind" in
      existing)
        if ! restore_proxy_host "$id" "$state_file"; then
          rollback_failed=1
        fi
        ;;
      created)
        if ! remove_created_proxy_host "$id"; then
          rollback_failed=1
        fi
        ;;
    esac
  done
  [[ "$rollback_failed" -eq 0 ]]
}

fail_after_proxy_mutation() {
  local reason="$1"
  local rollback_reason="$reason"
  local diagnostic_file has_create_failure_diagnostic=0
  local failure_status=1
  [[ "$reason" == proxy_host_application_failed ]] && ROLLBACK_RETAIN_DIAGNOSTICS=1
  if [[ -n "$ROLLBACK_DIR" ]]; then
    for diagnostic_file in "$ROLLBACK_DIR"/create-failure-*.txt; do
      if [[ -f "$diagnostic_file" ]]; then
        has_create_failure_diagnostic=1
        break
      fi
    done
  fi
  if [[ "$ROLLBACK_INCOMPLETE" -eq 1 || ( -n "$ROLLBACK_DIR" && -f "$ROLLBACK_DIR/incomplete" ) ]]; then
    ROLLBACK_INCOMPLETE=1
  fi
  if [[ -n "$ROLLBACK_DIR" && ( -f "$ROLLBACK_DIR/retain-diagnostics" || "$has_create_failure_diagnostic" -eq 1 ) ]]; then
    ROLLBACK_RETAIN_DIAGNOSTICS=1
  fi
  if [[ -s "$ROLLBACK_RECORDS" ]]; then
    if rollback_proxy_hosts; then
      if [[ "$ROLLBACK_INCOMPLETE" -eq 1 ]]; then
        rollback_reason="${reason}_rollback_incomplete_manual_cleanup_required"
      else
        rollback_reason="${reason}_proxy_hosts_restored"
      fi
    else
      mark_rollback_incomplete
      rollback_reason="${reason}_rollback_incomplete_manual_cleanup_required"
    fi
  elif [[ "$ROLLBACK_INCOMPLETE" -eq 1 ]]; then
    rollback_reason="${reason}_rollback_incomplete_manual_cleanup_required"
  fi
  # redacted_failure intentionally returns non-zero.  Under set -e it must be
  # called in a conditional context so cleanup and diagnostic retention still
  # run before this function returns failure.
  if redacted_failure "$rollback_reason"; then
    failure_status=0
  else
    failure_status=$?
  fi
  if [[ "$ROLLBACK_INCOMPLETE" -eq 1 ]]; then
    printf 'NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=%s\n' "$ROLLBACK_DIR" >&2
  else
    if [[ "$ROLLBACK_RETAIN_DIAGNOSTICS" -eq 1 ]]; then
      printf 'NPM_BOOTSTRAP_ROLLBACK_DIAGNOSTIC_DIR=%s\n' "$ROLLBACK_DIR" >&2
    else
      [[ -z "$ROLLBACK_DIR" ]] || rm -rf "$ROLLBACK_DIR"
    fi
  fi
  return "$failure_status"
}

fail_before_proxy_mutation() {
  local reason="$1"
  local failure_status=1
  if redacted_failure "${reason}_before_proxy_mutation"; then
    failure_status=0
  else
    failure_status=$?
  fi
  [[ -z "$ROLLBACK_DIR" ]] || rm -rf "$ROLLBACK_DIR"
  return "$failure_status"
}

ensure_proxy_host() {
  local prefix="$1"
  local domain="$2"
  local upstream_host="$3"
  local upstream_port="$4"
  local cert_id="$5"

  local id
  if ! id="$(find_proxy_host_id_for_domain "$domain")"; then
    echo "NPM proxy host inventory could not prove a safe target for $domain; refusing to mutate." >&2
    return 1
  fi
  if [[ -n "$id" && "$id" != "null" ]]; then
    ROLLBACK_SEQUENCE=$((ROLLBACK_SEQUENCE + 1))
    capture_proxy_host_state "$id" "$ROLLBACK_SEQUENCE" || return 1
    update_proxy_host "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id" "$id" || return 1
    return 0
  fi

  if [[ "$ENSURE_PROXY_HOSTS" == "1" ]]; then
    local payload before_file
    payload="$(proxy_host_payload "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id")"
    ROLLBACK_SEQUENCE=$((ROLLBACK_SEQUENCE + 1))
    before_file="$(capture_proxy_host_inventory "$ROLLBACK_SEQUENCE")" || return 1
    if ! id="$(create_proxy_host "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id" "$before_file" "$((ROLLBACK_SEQUENCE + 1))")"; then
      return 1
    fi
    return 0
  fi

  echo "No existe Proxy Host para $domain; instalá primero o corré el bootstrap de hosts." >&2
  return 1
}

main() {
  if [[ -z "$BASE_DOMAIN" ]]; then
    read -r -p "Ingresa el dominio base (ej: dnains.duckdns.org): " BASE_DOMAIN
  fi
  if [[ -z "$BASE_DOMAIN" ]]; then
    echo "Falta BASE_DOMAIN (ej: dnains.duckdns.org). Define BASE_DOMAIN."
    exit 1
  fi

  if ! wait_for_npm; then
    return 1
  fi
  local xtrace_was_enabled=0 login_status
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  if TOKEN="$(login)"; then
    login_status=0
  else
    login_status=$?
  fi
  if (( xtrace_was_enabled )); then
    set -x
  fi
  if [[ "$login_status" -ne 0 ]]; then
    redacted_failure "npm_login_failed"
    return 1
  fi
  if ! write_npm_auth_config; then
    redacted_failure "npm_auth_config_failed"
    return 1
  fi

  if [[ -z "$TLS_MODE" ]]; then
    if [[ "$USE_LOCAL_TLS_CERTS" == "1" ]]; then
      TLS_MODE="local"
    else
      TLS_MODE="letsencrypt"
    fi
  fi

  # Journal rollback before TLS issuance or upload so failures after an
  # earlier proxy mutation use the compensating path.
  init_proxy_rollback

  # Invariant: local/custom certificate record setup and upload complete before
  # the service loop can mutate any proxy host. Therefore an upload failure is
  # a pre-mutation failure with no proxy rollback; later failures compensate.
  CUSTOM_CERT_ID=""
  case "$TLS_MODE" in
    none)
      ;;
    local)
      if [[ -n "$ONLY_PREFIX" ]]; then
        configure_local_tls_for_prefix "$ONLY_PREFIX"
        if ! collect_tls_domains || ! ensure_local_certificate_files "${TLS_DOMAINS[@]}"; then
          fail_before_proxy_mutation "certificate_application_failed"
          return 1
        fi
      else
        if ! collect_tls_domains || ! ensure_local_certificate_files "${TLS_DOMAINS[@]}"; then
          fail_before_proxy_mutation "certificate_application_failed"
          return 1
        fi
      fi
      if ! CUSTOM_CERT_ID="$(ensure_custom_certificate)"; then
        fail_before_proxy_mutation "certificate_application_failed"
        return 1
      fi
      echo "Usando certificado local NPM id=$CUSTOM_CERT_ID" >&2
      ;;
    custom)
      NPM_LOCAL_CERT_NAME="$NPM_CUSTOM_CERT_NAME"
      NPM_LOCAL_CERT_FILE="$NPM_CUSTOM_CERT_FILE"
      NPM_LOCAL_KEY_FILE="$NPM_CUSTOM_KEY_FILE"
      if ! CUSTOM_CERT_ID="$(ensure_custom_certificate)"; then
        fail_before_proxy_mutation "certificate_application_failed"
        return 1
      fi
      echo "Usando certificado propio NPM id=$CUSTOM_CERT_ID" >&2
      ;;
    letsencrypt)
      ;;
    *)
      echo "TLS_MODE inválido: $TLS_MODE" >&2
      exit 1
      ;;
  esac

  matched=0
  for entry in "${SERVICES[@]}"; do
    IFS=":" read -r prefix default_host default_port <<<"$entry"
    if [[ -n "$ONLY_PREFIX" && "$prefix" != "$ONLY_PREFIX" ]]; then
      continue
    fi
    matched=1
    upper_prefix="$(echo "$prefix" | tr '[:lower:]' '[:upper:]')"
    up_host_var="HOST_${upper_prefix}"
    up_port_var="PORT_${upper_prefix}"
    domain_var="DOMAIN_${upper_prefix}"
    up_host="${!up_host_var:-$default_host}"
    up_port="${!up_port_var:-$default_port}"
    custom_domain="${!domain_var:-}"

    if [[ -n "$custom_domain" ]]; then
      domain="$custom_domain"
    else
      # Si BASE_DOMAIN ya incluye el prefijo, evita duplicarlo (ej: base=daiana.dnains.duckdns.org)
      if [[ "$BASE_DOMAIN" == "${prefix}."* ]]; then
        domain="$BASE_DOMAIN"
      else
        domain="${prefix}.${BASE_DOMAIN}"
      fi
    fi

    case "$TLS_MODE" in
      none)
        cert_id=""
        ;;
      letsencrypt)
        if ! cert_id="$(ensure_certificate "$domain")" || [[ -z "$cert_id" || "$cert_id" == "null" ]]; then
          fail_after_proxy_mutation "certificate_issuance_failed"
          return 1
        fi
        ;;
    local|custom)
      cert_id="$CUSTOM_CERT_ID"
        ;;
      *)
        cert_id=""
        ;;
    esac
    # Certificate metadata, PEM/SAN, expiry, and trusted TLS verification are
    # pre-mutation gates for the current host.  A later host can still fail
    # this gate after an earlier host has mutated, so preserve the existing
    # rollback journal whenever it already contains a prior mutation.
    if [[ "$TLS_MODE" != "none" ]] && ! verify_certificate_for_domain "$cert_id" "$domain"; then
      if [[ -s "$ROLLBACK_RECORDS" ]]; then
        fail_after_proxy_mutation "certificate_verification_failed"
      else
        fail_before_proxy_mutation "certificate_verification_failed"
      fi
      return 1
    fi
    if ! ensure_proxy_host "$prefix" "$domain" "$up_host" "$up_port" "$cert_id"; then
      fail_after_proxy_mutation "proxy_host_application_failed"
      return 1
    fi
  done

  if [[ -n "$ONLY_PREFIX" && "$matched" -eq 0 ]]; then
    echo "No se encontró ningún proxy host para ONLY_PREFIX=$ONLY_PREFIX" >&2
    exit 1
  fi

  [[ -z "$ROLLBACK_DIR" ]] || rm -rf "$ROLLBACK_DIR"

  case "$TLS_MODE" in
    none)
      if [[ -n "$ONLY_PREFIX" ]]; then
        echo "Listo: proxy host $ONLY_PREFIX actualizado sin TLS forzado."
      else
        echo "Listo: proxy hosts creados sin TLS."
      fi
      printf 'NPM_BOOTSTRAP_STATUS=SUCCESS\nNPM_BOOTSTRAP_TLS_MODE=none\nNPM_BOOTSTRAP_TLS_RESULT=not_requested\n'
      ;;
    *)
      if [[ -n "$ONLY_PREFIX" ]]; then
        echo "Listo: proxy host $ONLY_PREFIX actualizado con certificado."
      else
        echo "Listo: proxy hosts actualizados con certificados."
      fi
      printf 'NPM_BOOTSTRAP_STATUS=SUCCESS\nNPM_BOOTSTRAP_TLS_MODE=%s\nNPM_BOOTSTRAP_TLS_RESULT=applied\n' "$TLS_MODE"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
