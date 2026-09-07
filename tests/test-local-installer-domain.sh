#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"

awk '/^load_dotenv\(\)/,/^}/' "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/env-functions.sh"
awk '/^persist_env_value\(\)/,/^}/' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/env-functions.sh"
awk '/^detect_local_ipv4\(\)/,/^if \[ -z "\$BASE_DOMAIN" \]/{ if ($0 !~ /^if \[ -z "\$BASE_DOMAIN"/) print }' \
  "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/local-domain.sh"
awk '/^prompt_missing\(\)/,/^}/' "$ROOT_DIR/install-daiana.sh" >> "$TMP_DIR/local-domain.sh"

cat > "$MOCK_BIN/uname" <<'MOCK'
#!/usr/bin/env bash
printf 'Darwin\n'
MOCK
cat > "$MOCK_BIN/route" <<'MOCK'
#!/usr/bin/env bash
printf '   interface: en0\n'
MOCK
cat > "$MOCK_BIN/ipconfig" <<'MOCK'
#!/usr/bin/env bash
[[ "$*" == 'getifaddr en0' ]]
printf '10.20.30.40\n'
MOCK
chmod +x "$MOCK_BIN/uname" "$MOCK_BIN/route" "$MOCK_BIN/ipconfig"

(
  cd "$TMP_DIR"
  printf 'BASE_DOMAIN=localhost\n' > .env
  DAIANA_LOCAL_INSTALL=1 DRY_RUN=0 PATH="$MOCK_BIN:$PATH" bash -c '
    log() { :; }
    die() { exit 1; }
    source "$1"
    source "$2"
    load_dotenv .env 1
    [[ "$BASE_DOMAIN" == "10.20.30.40.nip.io" ]]
  ' _ "$TMP_DIR/env-functions.sh" "$TMP_DIR/local-domain.sh"
)

grep -qx 'BASE_DOMAIN=10.20.30.40.nip.io' "$TMP_DIR/.env"

(
  cd "$TMP_DIR"
  PATH="$MOCK_BIN:$PATH"
  export DAIANA_LOCAL_INSTALL=0
  # shellcheck source=/dev/null
  source "$TMP_DIR/local-domain.sh"
  BASE_DOMAIN=""
  # shellcheck disable=SC2329
  prompt() {
    printf '%s' "${PROMPT_REPLY:-$2}"
  }
  default_domain="$(base_domain_prompt_default)"
  [[ "$default_domain" == "10.20.30.40.nip.io" ]]
  prompt_missing BASE_DOMAIN "$default_domain"
  [[ "$BASE_DOMAIN" == "10.20.30.40.nip.io" ]]

  BASE_DOMAIN='daiana.example.com'
  prompt_missing BASE_DOMAIN "$default_domain"
  [[ "$BASE_DOMAIN" == "daiana.example.com" ]]
)

printf 'local installer domain persistence and interactive default tests passed\n'
