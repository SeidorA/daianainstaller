#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

awk '/^ensure_flowise_storage_permissions\(\)/,/^}/' "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/flowise-functions.sh"
# shellcheck source=/dev/null
source "$TMP_DIR/flowise-functions.sh"

cat > "$MOCK_BIN/uname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "${FLOWISE_TEST_OS:?}"
MOCK

cat > "$MOCK_BIN/id" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '501\n' ;;
  -g) printf '20\n' ;;
  *) exit 1 ;;
esac
MOCK

cat > "$MOCK_BIN/sudo" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FLOWISE_SUDO_LOG:?}"
MOCK

chmod +x "$MOCK_BIN/uname" "$MOCK_BIN/id" "$MOCK_BIN/sudo"

log() { :; }
die() { fail "$*"; }
prompt_yes_no() { fail "unexpected permission prompt"; }

run_case() {
  local os_name="$1" local_install="$2" expected_sudo_calls="$3"
  local work_dir="$TMP_DIR/$os_name-$local_install"
  local sudo_log="$work_dir/sudo.log"

  mkdir -p "$work_dir/volumes/daiana/flowise/logs"
  : > "$sudo_log"
  (
    cd "$work_dir"
    PATH="$MOCK_BIN:$PATH" \
      FLOWISE_TEST_OS="$os_name" \
      FLOWISE_SUDO_LOG="$sudo_log" \
      ACTION=install \
      DAIANA_LOCAL_INSTALL="$local_install" \
      ensure_flowise_storage_permissions
  )

  local actual_sudo_calls
  actual_sudo_calls="$(wc -l < "$sudo_log" | tr -d ' ')"
  [ "$actual_sudo_calls" = "$expected_sudo_calls" ] \
    || fail "$os_name local=$local_install invoked sudo $actual_sudo_calls times; expected $expected_sudo_calls"
}

run_case Darwin 1 0
pass "writable local macOS Flowise logs skip sudo chown"

run_case Linux 1 1
pass "Linux installation retains sudo chown"

run_case Darwin 0 1
pass "non-local macOS installation retains sudo chown"
