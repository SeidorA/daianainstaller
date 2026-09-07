#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REAL_OPENSSL="$(command -v openssl)"
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/openssl" <<'MOCK'
#!/usr/bin/env bash
set -u

if [[ "${1:-}" == x509 && "${2:-}" == -help ]]; then
  if [[ "${CERT_VALIDATION_TEST_MODE:-}" == native ]]; then
    printf '%s\n' '    -checkhost hostname'
  else
    printf '%s\n' 'x509 options without hostname checking'
  fi
  exit 0
fi

if [[ "${1:-}" == x509 && " $* " == *' -checkhost '* ]]; then
  : >> "${CERT_VALIDATION_NATIVE_CALLS:?}"
  [[ "${CERT_VALIDATION_NATIVE_RESULT:-no}" == yes ]]
  exit $?
fi

exec "${REAL_OPENSSL:?}" "$@"
MOCK
chmod +x "$MOCK_BIN/openssl"

make_certificate() {
  local cert_file="$1" key_file="$2" config_file="$TMP_DIR/openssl.cnf" subject="$3"
  shift 3
  : > "$config_file"
  if [[ "$#" -gt 0 ]]; then
    printf '%s\n' '[req]' 'prompt = no' 'distinguished_name = req_distinguished_name' \
      'x509_extensions = req_ext' '[req_distinguished_name]' "CN = $subject" > "$config_file"
    printf '%s\n' '[req_ext]' 'subjectAltName = @alt_names' '[alt_names]' >> "$config_file"
    local index=1 san
    for san in "$@"; do
      printf 'DNS.%s = %s\n' "$index" "$san" >> "$config_file"
      index=$((index + 1))
    done
  else
    printf '%s\n' '[req]' 'prompt = no' 'distinguished_name = req_distinguished_name' \
      '[req_distinguished_name]' "CN = $subject" > "$config_file"
  fi
  "$REAL_OPENSSL" req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$key_file" -out "$cert_file" -config "$config_file" >/dev/null 2>&1
}

make_certificate "$TMP_DIR/with-san.crt" "$TMP_DIR/with-san.key" \
  cn-only.example.test example.test api.example.test '*.wild.example.test'
make_certificate "$TMP_DIR/cn-only.crt" "$TMP_DIR/cn-only.key" \
  cn-only.example.test
printf '%s\n' 'not a certificate' > "$TMP_DIR/malformed.crt"
: > "$TMP_DIR/native-calls"

# Native checkhost is preferred when advertised and its result is authoritative.
CERT_VALIDATION_TEST_MODE=native CERT_VALIDATION_NATIVE_RESULT=yes \
  CERT_VALIDATION_NATIVE_CALLS="$TMP_DIR/native-calls" PATH="$MOCK_BIN:$PATH" \
  bash -c 'source "$1"; certificate_hostname_matches "$2" api.example.test' \
  _ "$ROOT_DIR/utils/certificate-validation.sh" "$TMP_DIR/with-san.crt"
[[ "$(wc -l < "$TMP_DIR/native-calls" | tr -d ' ')" == 1 ]]

if CERT_VALIDATION_TEST_MODE=native CERT_VALIDATION_NATIVE_RESULT=no \
  CERT_VALIDATION_NATIVE_CALLS="$TMP_DIR/native-calls" PATH="$MOCK_BIN:$PATH" \
  bash -c 'source "$1"; certificate_hostname_matches "$2" api.example.test' \
  _ "$ROOT_DIR/utils/certificate-validation.sh" "$TMP_DIR/with-san.crt"; then
  printf 'Native hostname mismatch was accepted\n' >&2
  exit 1
fi

# Unsupported checkhost falls back to SAN parsing without trusting the CN.
CERT_VALIDATION_TEST_MODE=fallback CERT_VALIDATION_NATIVE_CALLS="$TMP_DIR/native-calls" \
  PATH="$MOCK_BIN:$PATH" bash -c '
    source "$1"
    certificate_hostname_matches "$2" example.test
    certificate_hostname_matches "$2" api.example.test
    certificate_hostname_matches "$2" one.wild.example.test
    ! certificate_hostname_matches "$2" deep.one.wild.example.test
    ! certificate_hostname_matches "$2" wild.example.test
  ' _ "$ROOT_DIR/utils/certificate-validation.sh" "$TMP_DIR/with-san.crt"

if CERT_VALIDATION_TEST_MODE=fallback PATH="$MOCK_BIN:$PATH" \
  bash -c 'source "$1"; certificate_hostname_matches "$2" cn-only.example.test' \
  _ "$ROOT_DIR/utils/certificate-validation.sh" "$TMP_DIR/cn-only.crt"; then
  printf 'CN-only certificate was accepted\n' >&2
  exit 1
fi

if CERT_VALIDATION_TEST_MODE=fallback PATH="$MOCK_BIN:$PATH" \
  bash -c 'source "$1"; certificate_hostname_matches "$2" api.example.test' \
  _ "$ROOT_DIR/utils/certificate-validation.sh" "$TMP_DIR/malformed.crt"; then
  printf 'Malformed certificate was accepted\n' >&2
  exit 1
fi

printf 'portable certificate hostname validation tests passed\n'
