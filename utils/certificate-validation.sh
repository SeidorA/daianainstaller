#!/usr/bin/env bash

# Validate a certificate hostname without exposing certificate contents. Native
# checkhost is used when advertised; older macOS/OpenSSL builds use SAN parsing.

certificate_x509_checkhost_supported() {
  local help_output
  help_output="$(openssl x509 -help 2>&1 || true)"
  [[ "$help_output" == *checkhost* ]]
}

certificate_dns_hostname_is_valid() {
  local hostname="$1"
  [[ "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]
}

certificate_dns_name_matches() {
  local san_name="$1" hostname="$2" suffix prefix
  san_name="$(printf '%s' "$san_name" | tr '[:upper:]' '[:lower:]')"
  hostname="$(printf '%s' "$hostname" | tr '[:upper:]' '[:lower:]')"

  [[ "$san_name" == "$hostname" ]] && return 0
  [[ "$san_name" == \*.\* ]] && return 1
  [[ "$san_name" == \*.* ]] || return 1
  suffix="${san_name#\*.}"
  [[ "$suffix" != *'*'* ]] || return 1
  certificate_dns_hostname_is_valid "$suffix" || return 1
  [[ "$hostname" == *".$suffix" ]] || return 1
  prefix="${hostname%."$suffix"}"
  [[ "$prefix" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

certificate_hostname_matches_san() {
  local cert_file="$1" hostname="$2" text_file san_file san matched=1
  text_file="$(mktemp "${TMPDIR:-/tmp}/certificate-validation.XXXXXX")" || return 1
  san_file="$(mktemp "${TMPDIR:-/tmp}/certificate-validation-san.XXXXXX")" || {
    rm -f "$text_file"
    return 1
  }

  if ! openssl x509 -in "$cert_file" -noout -text >"$text_file" 2>/dev/null; then
    rm -f "$text_file" "$san_file"
    return 1
  fi

  awk '
    /X509v3 Subject Alternative Name:/ { in_san = 1; next }
    in_san && $0 !~ /^[[:space:]]/ { in_san = 0; next }
    in_san {
      line = $0
      while (match(line, /DNS:[^,[:space:]]+/)) {
        print substr(line, RSTART + 4, RLENGTH - 4)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$text_file" >"$san_file"

  local xtrace_was_enabled=0
  case "$-" in
    *x*) xtrace_was_enabled=1; set +x ;;
  esac
  while IFS= read -r san; do
    if certificate_dns_name_matches "$san" "$hostname"; then
      matched=0
      break
    fi
  done <"$san_file"
  if (( xtrace_was_enabled )); then
    set -x
  fi

  rm -f "$text_file" "$san_file"
  return "$matched"
}

certificate_hostname_matches() {
  local cert_file="${1:-}" hostname="${2:-}"
  [[ -f "$cert_file" ]] || return 1
  certificate_dns_hostname_is_valid "$hostname" || return 1

  if certificate_x509_checkhost_supported; then
    # A supported native mismatch is authoritative; do not reinterpret it via
    # a weaker parser or trust the certificate common name.
    openssl x509 -in "$cert_file" -noout -checkhost "$hostname" >/dev/null 2>&1
    return $?
  fi

  certificate_hostname_matches_san "$cert_file" "$hostname"
}
