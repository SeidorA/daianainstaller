#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDACTOR="$ROOT_DIR/utils/private-chat-redaction.py"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
# shellcheck disable=SC2088
tilde_secret_path='~/.local/share/keychain/secrets'

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_redacted() {
  local input="$1" forbidden="$2" output
  output="$(printf '%s' "$input" | python3 "$REDACTOR")"
  [[ "$output" != *"$forbidden"* ]] || fail "secret survived redaction: $forbidden"
  if printf '%s' "$input" | python3 "$REDACTOR" | grep -Eq 'BEGIN .*PRIVATE KEY|END .*PRIVATE KEY|/root/|\.ssh'; then
    fail "unsafe marker remained in redacted output: $input"
  fi
}

for marker in \
  '-----BEGIN RSA PRIVATE KEY-----' \
  '-----END OPENSSH PRIVATE KEY-----' \
  '-----BEGIN PRIVATE KEY-----truncated'; do
  assert_redacted "$marker" "$marker"
  printf '%s' "$marker" | python3 "$REDACTOR" >/dev/null
done

mkdir -p "$TMP_DIR/artifacts"
printf '%s\n' 'state=blocked' '-----BEGIN PRIVATE KEY-----' > "$TMP_DIR/artifacts/unsafe.marker"
if python3 "$REDACTOR" --verify-dir "$TMP_DIR/artifacts"; then
  fail 'verify-directory accepted a standalone private-key marker'
fi

for path in \
  '/root/.ssh/id_rsa' \
  '/root/.config/credentials.json' \
  "$tilde_secret_path" \
  './secrets/service.yaml' \
  '../credentials/token.json'; do
  assert_redacted "path=$path" "$path"
done

for command in \
  'cli --password plain-secret --verbose' \
  'cli --password=equals-secret --verbose' \
  'cli --token "quoted-secret" --safe-flag' \
  "cli --api-key 'single-quoted-secret' --safe-flag" \
  'cli --secret escaped\\ secret --safe-flag' \
  'mysql -p mysql-secret --safe-flag' \
  'mysql -pmysql-secret --safe-flag' \
  'mysql -ppassword --safe-flag' \
  'mysql --db-password=database-secret --safe-flag' \
  'psql -p 5432 --safe-flag'; do
  output="$(printf '%s' "$command" | python3 "$REDACTOR")"
  if grep -Eq 'plain-secret|equals-secret|quoted-secret|single-quoted-secret|escaped(\\\\)? secret|mysql-secret' <<<"$output"; then
    fail "command secret survived redaction: $command"
  fi
  [[ "$output" == *safe-flag* || "$output" == *--verbose* ]] || fail "ordinary flag was not preserved: $command"
done

attached_port_output="$(printf '%s' 'mysql -p5432 --safe-flag' | python3 "$REDACTOR")"
[[ "$attached_port_output" == *'-p5432'* ]] || fail 'attached numeric port was redacted'
[[ "$attached_port_output" == *'--safe-flag'* ]] || fail 'ordinary flag after attached port was lost'

grep -q '^\.private-chat-harness/$' "$ROOT_DIR/.gitignore" || fail 'default harness state directory is not ignored'
grep -q '^\.private-chat-harness/\*\.receipt$' "$ROOT_DIR/.gitignore" || fail 'harness receipt pattern is not ignored'
grep -q '^\.private-chat-harness/failure-diagnostics\.txt$' "$ROOT_DIR/.gitignore" || fail 'harness diagnostics pattern is not ignored'
git -C "$ROOT_DIR" check-ignore -q '.private-chat-harness/active.receipt' || fail 'generated harness receipt is not mechanically ignored'
git -C "$ROOT_DIR" check-ignore -q 'utils/private-chat-redaction.py' && fail 'redaction source was accidentally ignored'
git -C "$ROOT_DIR" check-ignore -q 'tests/test-private-chat-redaction.sh' && fail 'redaction tests were accidentally ignored'

for payload in \
  '{"nested":{"password":"json-secret","safe":true}}' \
  'token: yaml-secret' \
  'Authorization: Bearer header-secret' \
  'url=https://user:pass@example.test/x?token=url-secret' \
  'PASSWORD=assignment-secret'; do
  assert_redacted "$payload" 'secret'
done

printf 'private-chat redaction regression tests passed\n'
