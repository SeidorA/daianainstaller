#!/usr/bin/env bash
set -euo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  printf 'ERROR: run this script with bash, not sh. Use: bash ./apply-certs.sh [--dry-run]\n' >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source "$ROOT_DIR/utils/public-url-propagation.sh"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done

log() { printf '===> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

resolve_domain_for_prefix() {
  local prefix="$1"
  if [[ "$BASE_DOMAIN" == "${prefix}."* ]]; then
    printf '%s' "$BASE_DOMAIN"
  else
    printf '%s.%s' "$prefix" "$BASE_DOMAIN"
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

ensure_local_certificate_files() {
  local domain="$1"
  local cert_path="${NPM_LOCAL_CERT_FILE/#~/$HOME}"
  local key_path="${NPM_LOCAL_KEY_FILE/#~/$HOME}"
  shift
  local requested_domain config_file san_index

  for requested_domain in "$domain" "$@"; do
    [[ "$requested_domain" =~ ^[A-Za-z0-9.-]+$ && "$requested_domain" == *.* ]] \
      || die "TLS hostname/SAN derivation is incomplete or invalid: $requested_domain"
  done

  if [ -f "$cert_path" ] && [ -f "$key_path" ]; then
    for requested_domain in "$domain" "$@"; do
      openssl x509 -in "$cert_path" -noout -checkhost "$requested_domain" >/dev/null 2>&1 \
        || die "local certificate SAN does not cover $requested_domain"
    done
    return 0
  fi

  command -v openssl >/dev/null 2>&1 || die "openssl is required to generate local certificates"
  log "Generating local self-signed certificate for $domain"
  mkdir -p "$(dirname "$cert_path")"
  config_file="$(mktemp "${TMPDIR:-/tmp}/daiana-local-cert.XXXXXX")" || die "could not create certificate configuration"
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
    die "could not generate local certificate"
  fi
  rm -f "$config_file"
  chmod 640 "$key_path"
  chgrp 65533 "$key_path" 2>/dev/null || true
  for requested_domain in "$domain" "$@"; do
    openssl x509 -in "$cert_path" -noout -checkhost "$requested_domain" >/dev/null 2>&1 \
      || die "generated local certificate SAN does not cover $requested_domain"
  done
}

collect_local_tls_domains() {
  local prefix domain_var domain
  LOCAL_TLS_DOMAINS=()
  for prefix in api nginx port qdrant daiana studio supa whatsapp vanna webui msteams; do
    if [[ -n "${ONLY_PREFIX:-}" && "$ONLY_PREFIX" != "$prefix" ]]; then
      continue
    fi
    domain_var="DOMAIN_$(printf '%s' "$prefix" | tr '[:lower:]' '[:upper:]')"
    if [[ -n "${!domain_var:-}" ]]; then
      domain="${!domain_var}"
    elif [[ "$BASE_DOMAIN" == "${prefix}."* ]]; then
      domain="$BASE_DOMAIN"
    else
      domain="${prefix}.${BASE_DOMAIN}"
    fi
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ && "$domain" == *.* ]] \
      || die "TLS hostname/SAN derivation is incomplete or invalid for $prefix"
    LOCAL_TLS_DOMAINS[${#LOCAL_TLS_DOMAINS[@]}]="$domain"
  done
  [ "${#LOCAL_TLS_DOMAINS[@]}" -gt 0 ] || die "TLS hostname list is empty"
}

prompt() {
  (
    case "$-" in *x*) set +x ;; esac
    local label="$1" default_value="${2:-}" reply=""
    if [ -t 0 ] && [ -r /dev/tty ]; then
      if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$label" "$default_value" >&2
      else
        printf '%s: ' "$label" >&2
      fi
      read -r reply </dev/tty
    fi
    if [ -z "$reply" ]; then reply="$default_value"; fi
    printf '%s' "$reply"
  )
}

load_dotenv() {
  local file="$1"
  [ -f "$file" ] || return 0
  local line key value xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*)
        key="${line%%=*}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value="${line#*=}"
        case "$key" in
          *PASS*|*TOKEN*|*SECRET*|*KEY*|*PAT*|*BEARER*|*COOKIE*|*AUTH*) : ;;
          *) : ;;
        esac
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
          value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
          value="${value:1:${#value}-2}"
        fi
        printf -v "$key" '%s' "$value"
        export "${key?}"
        ;;
    esac
  done < "$file"
  if (( xtrace_was_enabled )); then set -x; fi
}

load_dotenv .env

persist_env_value() {
  (
    case "$-" in *x*) set +x ;; esac
    local key="$1" value="$2" tmp value_file
    tmp="$(mktemp)"; value_file="$(mktemp)"
    chmod 600 "$value_file"
    printf '%s' "$value" > "$value_file"
    if ! awk -v key="$key" -v value_file="$value_file" '
      BEGIN { done = 0; if ((getline value < value_file) < 0) exit 1 }
      $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" { print key "=" value; done = 1; next }
      { print }
      END { if (done == 0) print key "=" value }
    ' .env > "$tmp"; then
      rm -f "$tmp" "$value_file"
      return 1
    fi
    rm -f "$value_file"
    if ! mv "$tmp" .env; then rm -f "$tmp"; return 1; fi
  )
}

refresh_public_urls_in_env() {
  local stage backup vault_snapshot vault_scheme scheme=https
  stage="$(stage_public_env_update .env "$scheme")" || return 1
  backup="$(mktemp .env.rollback.XXXXXX)" || { rm -f "$stage"; return 1; }
  cp -p .env "$backup" || { rm -f "$stage" "$backup"; return 1; }
  vault_snapshot="$(mktemp .vault-public.rollback.XXXXXX)" || { rm -f "$stage" "$backup"; return 1; }
  if ! vault_snapshot_public_url_entries "$vault_snapshot"; then
    rm -f "$stage" "$backup" "$vault_snapshot"
    return 1
  fi
  if ! vault_scheme="$(vault_snapshot_public_url_scheme "$vault_snapshot")"; then
    rm -f "$stage" "$backup" "$vault_snapshot"
    return 1
  fi
  if ! mv "$stage" .env; then
    rm -f "$stage" "$backup" "$vault_snapshot"
    return 1
  fi
  load_dotenv .env
  if ! vault_upsert_public_url_entries .env "$scheme"; then
    local compensation_failed=0
    printf '%s\n' 'ERROR: Vault update failed; compensating .env and Vault from retained snapshots' >&2
    if ! vault_restore_public_url_entries "$vault_snapshot" || ! vault_verify_public_url_entries "$vault_snapshot" "$vault_scheme"; then
      compensation_failed=1
    fi
    if ! mv "$backup" .env; then
      printf '%s\n' 'ERROR: Could not restore original .env; retained rollback diagnostics require manual restoration' >&2
      PUBLIC_ENV_BACKUP="$backup"
      PUBLIC_VAULT_SNAPSHOT="$vault_snapshot"
      return 1
    fi
    load_dotenv .env
    if [[ "$compensation_failed" -ne 0 ]]; then
      PUBLIC_ENV_BACKUP=""
      PUBLIC_VAULT_SNAPSHOT="$vault_snapshot"
      printf '%s\n' 'ERROR: Vault compensation was not verified; retained redacted snapshot requires manual cleanup' >&2
      return 1
    fi
    rm -f "$vault_snapshot"
    return 1
  fi
  PUBLIC_ENV_BACKUP="$backup"
  PUBLIC_VAULT_SNAPSHOT="$vault_snapshot"
}

compensate_public_url_propagation() {
  local env_backup="${PUBLIC_ENV_BACKUP:-}" vault_snapshot="${PUBLIC_VAULT_SNAPSHOT:-}" vault_scheme="" failed=0
  if [[ -n "$env_backup" && -f "$env_backup" ]]; then
    mv "$env_backup" .env || failed=1
  fi
  if [[ -n "$vault_snapshot" && -f "$vault_snapshot" ]]; then
    if ! vault_scheme="$(vault_snapshot_public_url_scheme "$vault_snapshot")" || \
       ! vault_restore_public_url_entries "$vault_snapshot" || \
       ! vault_verify_public_url_entries "$vault_snapshot" "$vault_scheme"; then
      failed=1
    fi
  fi
  load_dotenv .env
  if [[ "$failed" -ne 0 ]]; then
    printf '%s\n' 'ERROR: Public URL compensation was not fully verified; retained rollback diagnostics require manual cleanup' >&2
    return 1
  fi
  rm -f "$vault_snapshot"
  PUBLIC_ENV_BACKUP=""
  PUBLIC_VAULT_SNAPSHOT=""
}

BASE_DOMAIN="${BASE_DOMAIN:-}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-}"
pass_init_xtrace_was_enabled=0
case "$-" in *x*) pass_init_xtrace_was_enabled=1; set +x ;; esac
NPM_ADMIN_PASS="${NPM_ADMIN_PASS:-}"
if (( pass_init_xtrace_was_enabled )); then set -x; fi
TLS_MODE="${TLS_MODE:-}"
NPM_LOCAL_CERT_FILE="${NPM_LOCAL_CERT_FILE:-volumes/api/server.crt}"
NPM_LOCAL_KEY_FILE="${NPM_LOCAL_KEY_FILE:-volumes/api/server.key}"
NPM_CUSTOM_CERT_NAME="${NPM_CUSTOM_CERT_NAME:-daiana-custom-tls}"
NPM_CUSTOM_CERT_FILE="${NPM_CUSTOM_CERT_FILE:-}"
NPM_CUSTOM_KEY_FILE="${NPM_CUSTOM_KEY_FILE:-}"

BASE_DOMAIN="${BASE_DOMAIN:-$(prompt 'BASE_DOMAIN' '')}"
[ -n "$BASE_DOMAIN" ] || die "BASE_DOMAIN is required"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-$(prompt 'NPM_ADMIN_EMAIL' 'admin@example.com')}"
[ -n "$NPM_ADMIN_EMAIL" ] || die "NPM_ADMIN_EMAIL is required"
pass_xtrace_was_enabled=0
case "$-" in *x*) pass_xtrace_was_enabled=1; set +x ;; esac
NPM_ADMIN_PASS="${NPM_ADMIN_PASS:-$(prompt 'NPM_ADMIN_PASS' '')}"
[ -n "$NPM_ADMIN_PASS" ] || { if (( pass_xtrace_was_enabled )); then set -x; fi; die "NPM_ADMIN_PASS is required"; }
if (( pass_xtrace_was_enabled )); then set -x; fi

if [ -z "$TLS_MODE" ]; then
  echo "Select certificate mode:" >&2
  echo "  1) Let's Encrypt" >&2
  echo "  2) Self-signed / local certs" >&2
  echo "  3) Custom cert files" >&2
  choice="$(prompt 'Choose [1/3]' '1')"
  case "$choice" in
    2) TLS_MODE=local ;;
    3) TLS_MODE=custom ;;
    *) TLS_MODE=letsencrypt ;;
  esac
fi

if [ "$TLS_MODE" = "local" ]; then
  NPM_LOCAL_CERT_FILE="${NPM_LOCAL_CERT_FILE:-$(prompt 'NPM_LOCAL_CERT_FILE' 'volumes/api/server.crt')}"
  NPM_LOCAL_KEY_FILE="${NPM_LOCAL_KEY_FILE:-$(prompt 'NPM_LOCAL_KEY_FILE' 'volumes/api/server.key')}"
elif [ "$TLS_MODE" = "custom" ]; then
  NPM_CUSTOM_CERT_FILE="${NPM_CUSTOM_CERT_FILE:-$(prompt 'NPM_CUSTOM_CERT_FILE' '')}"
  NPM_CUSTOM_KEY_FILE="${NPM_CUSTOM_KEY_FILE:-$(prompt 'NPM_CUSTOM_KEY_FILE' '')}"
  NPM_CUSTOM_CERT_NAME="${NPM_CUSTOM_CERT_NAME:-$(prompt 'NPM_CUSTOM_CERT_NAME' 'daiana-custom-tls')}"
fi

if [ "$DRY_RUN" = "1" ]; then
  cat <<EOF
DRY RUN ONLY
Would:
- use BASE_DOMAIN=$BASE_DOMAIN
- use certificate mode: $TLS_MODE
- apply certificates to existing NPM proxy hosts only
- refresh persisted public URLs in .env after all intended TLS hosts verify
- upsert corresponding public URL entries through the existing Vault function
- refresh Portainer stacks after the env update
EOF
  exit 0
fi

if [ "$TLS_MODE" = "local" ]; then
  collect_local_tls_domains
  if [ -n "${ONLY_PREFIX:-}" ]; then
    cert_paths=()
    while IFS= read -r cert_path; do
      cert_paths[${#cert_paths[@]}]="$cert_path"
    done < <(local_cert_paths_for_prefix "$ONLY_PREFIX")
    [ "${#cert_paths[@]}" -eq 2 ] || die "Could not derive local certificate paths"
    NPM_LOCAL_CERT_FILE="${cert_paths[0]}"
    NPM_LOCAL_KEY_FILE="${cert_paths[1]}"
    ensure_local_certificate_files "${LOCAL_TLS_DOMAINS[@]}"
  else
    ensure_local_certificate_files "${LOCAL_TLS_DOMAINS[@]}"
  fi
  log "Applying local self-signed certificates in NPM"
elif [ "$TLS_MODE" = "custom" ]; then
  [ -f "$NPM_CUSTOM_CERT_FILE" ] || die "Certificate file not found: $NPM_CUSTOM_CERT_FILE"
  [ -f "$NPM_CUSTOM_KEY_FILE" ] || die "Key file not found: $NPM_CUSTOM_KEY_FILE"
  log "Applying user-provided certificates in NPM"
else
  log "Applying Let's Encrypt certificates in NPM"
fi

bootstrap_status=0
bootstrap_xtrace_was_enabled=0
case "$-" in
  *x*) bootstrap_xtrace_was_enabled=1; set +x ;;
esac
if BASE_DOMAIN="$BASE_DOMAIN" NPM_ADMIN_EMAIL="$NPM_ADMIN_EMAIL" NPM_ADMIN_PASS="$NPM_ADMIN_PASS" \
  TLS_MODE="$TLS_MODE" ENSURE_PROXY_HOSTS=0 ONLY_PREFIX="${ONLY_PREFIX:-}" NPM_LOCAL_CERT_FILE="$NPM_LOCAL_CERT_FILE" NPM_LOCAL_KEY_FILE="$NPM_LOCAL_KEY_FILE" \
  NPM_CUSTOM_CERT_NAME="$NPM_CUSTOM_CERT_NAME" NPM_CUSTOM_CERT_FILE="$NPM_CUSTOM_CERT_FILE" NPM_CUSTOM_KEY_FILE="$NPM_CUSTOM_KEY_FILE" \
    bash utils/npm_ssl_bootstrap.sh; then
  bootstrap_status=0
else
  bootstrap_status=$?
fi
if (( bootstrap_xtrace_was_enabled )); then
  set -x
fi
[ "$bootstrap_status" -eq 0 ] || exit "$bootstrap_status"

if [[ -z "${ONLY_PREFIX:-}" && "$TLS_MODE" != "none" ]]; then
   log "Refreshing persisted public URLs in .env according to the configured domain/TLS projection after complete verification"
  refresh_public_urls_in_env || die "Could not derive an unambiguous public URL set; refusing env/Vault mutation"
  log "Refreshing Portainer stacks after the env and Vault update"
  if ! bash update-daiana.sh --update; then
    compensate_public_url_propagation || die "Stack refresh failed and public URL compensation was incomplete; no success claimed"
    die "Stack refresh failed; .env and Vault were compensated, but runtime stack state requires manual reconciliation"
  fi
  rm -f "$PUBLIC_ENV_BACKUP" "$PUBLIC_VAULT_SNAPSHOT"
fi
