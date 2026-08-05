#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/apply-certs.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_ROOT="$TMP_DIR/workspace"
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$TEST_ROOT/utils" "$MOCK_BIN"
cp "$SCRIPT" "$TEST_ROOT/apply-certs.sh"
cp "$ROOT_DIR/utils/public-url-propagation.sh" "$TEST_ROOT/utils/public-url-propagation.sh"

cat > "$TEST_ROOT/.env" <<'ENV'
BASE_DOMAIN=example.nip.io
NPM_ADMIN_EMAIL=installer-test@example.test
NPM_ADMIN_PASS=fixture-secret-that-must-not-be-printed
TLS_MODE=letsencrypt
ENV

cat > "$MOCK_BIN/bash" <<'MOCK'
#!/bin/bash
set -eu
printf '%s\n' "${BASE_DOMAIN:-}" > "$NPM_APPLY_CERTS_TEST_STATE"
printf '%s\n' "${NPM_ADMIN_EMAIL:-}" >> "$NPM_APPLY_CERTS_TEST_STATE"
printf '%s\n' "${NPM_ADMIN_PASS:-}" >> "$NPM_APPLY_CERTS_TEST_STATE"
printf '%s\n' "${TLS_MODE:-}" >> "$NPM_APPLY_CERTS_TEST_STATE"
MOCK
chmod +x "$MOCK_BIN/bash"

state_file="$TMP_DIR/state"
PATH="$MOCK_BIN:$PATH" NPM_APPLY_CERTS_TEST_STATE="$state_file" ONLY_PREFIX=nginx \
  "$BASH" "$TEST_ROOT/apply-certs.sh"

expected_state=$'example.nip.io\ninstaller-test@example.test\nfixture-secret-that-must-not-be-printed\nletsencrypt'
actual_state="$(<"$state_file")"
[ "$actual_state" = "$expected_state" ] || {
  printf 'Unexpected exported environment:\n%s\n' "$actual_state" >&2
  exit 1
}

if PATH="$MOCK_BIN:$PATH" NPM_APPLY_CERTS_TEST_STATE="$TMP_DIR/unused" ONLY_PREFIX=nginx \
  "$BASH" "$TEST_ROOT/apply-certs.sh" 2>&1 | grep -q 'fixture-secret-that-must-not-be-printed'; then
  printf 'Certificate workflow leaked the fixture secret\n' >&2
  exit 1
fi

if PATH="$MOCK_BIN:$PATH" NPM_APPLY_CERTS_TEST_STATE="$TMP_DIR/xtrace-state" ONLY_PREFIX=nginx \
  "$BASH" -x "$TEST_ROOT/apply-certs.sh" >"$TMP_DIR/apply-xtrace.out" 2>&1; then
  :
else
  printf 'apply-certs xtrace path unexpectedly failed\n' >&2
  exit 1
fi
if grep -q 'fixture-secret-that-must-not-be-printed' "$TMP_DIR/apply-xtrace.out"; then
  printf 'apply-certs bash -x leaked the fixture secret\n' >&2
  exit 1
fi

printf 'apply-certs Bash 3.2 compatibility test passed\n'

# Exercise the real local certificate path (including prefix-specific path
# derivation and openssl output), rather than only mocking the child bootstrap.
LOCAL_CERT_ROOT="$TMP_DIR/local-certs"
cat > "$TEST_ROOT/.env" <<ENV
BASE_DOMAIN=example.nip.io
NPM_ADMIN_EMAIL=installer-test@example.test
NPM_ADMIN_PASS=fixture-secret-that-must-not-be-printed
TLS_MODE=local
NPM_LOCAL_CERT_FILE=$LOCAL_CERT_ROOT/server.crt
NPM_LOCAL_KEY_FILE=$LOCAL_CERT_ROOT/server.key
ENV
PATH="$MOCK_BIN:$PATH" NPM_APPLY_CERTS_TEST_STATE="$TMP_DIR/local-state" \
  ONLY_PREFIX=nginx TLS_MODE=local NPM_LOCAL_CERT_FILE="$LOCAL_CERT_ROOT/server.crt" \
  NPM_LOCAL_KEY_FILE="$LOCAL_CERT_ROOT/server.key" \
  "$BASH" "$TEST_ROOT/apply-certs.sh"
[ -s "$LOCAL_CERT_ROOT/server-nginx.crt" ] || { printf 'Local certificate was not generated\n' >&2; exit 1; }
[ -s "$LOCAL_CERT_ROOT/server-nginx.key" ] || { printf 'Local key was not generated\n' >&2; exit 1; }
openssl x509 -in "$LOCAL_CERT_ROOT/server-nginx.crt" -noout -subject >/dev/null
printf 'local TLS path exercised successfully\n'
