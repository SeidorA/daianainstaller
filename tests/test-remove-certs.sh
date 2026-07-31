#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/utils" "$TMP_DIR/bin"
cp "$ROOT_DIR/remove-certs.sh" "$TMP_DIR/"
cp "$ROOT_DIR/utils/public-url-propagation.sh" "$TMP_DIR/utils/"
cp "$ROOT_DIR/utils/npm_ssl_bootstrap.sh" "$TMP_DIR/utils/"

cat > "$TMP_DIR/.env" <<'ENV'
BASE_DOMAIN=192.168.0.19.nip.io
NPM_ADMIN_EMAIL=test@example.test
NPM_ADMIN_PASS=redacted-secret
STUDIO_BASE_URL=https://studio.192.168.0.19.nip.io
SUPABASE_PUBLIC_URL=https://supa.192.168.0.19.nip.io
API_EXTERNAL_URL=https://supa.192.168.0.19.nip.io/auth/v1
SITE_URL=https://daiana.192.168.0.19.nip.io
WEBUI_BASE_URL=https://webui.192.168.0.19.nip.io
BACKEND_BASE_URL=https://api.192.168.0.19.nip.io
WS_BASE_URL=https://whatsapp.192.168.0.19.nip.io
MS_BASE_URL=https://msteams.192.168.0.19.nip.io
VANNA_BASE_URL=https://vanna.192.168.0.19.nip.io
QDRANT_BASE_URL=https://qdrant.192.168.0.19.nip.io
CORS_ALLOW_ORIGIN=https://daiana.192.168.0.19.nip.io
NEXT_PUBLIC_APP_URL=https://daiana.192.168.0.19.nip.io
ENV
cat > "$TMP_DIR/vault.db" <<'VAULT'
NEXT_PUBLIC_SUPABASE_URL	https://supa.192.168.0.19.nip.io
NEXT_PUBLIC_API_PYTHON	https://api.192.168.0.19.nip.io
NEXT_PUBLIC_API_TRAINING	https://vanna.192.168.0.19.nip.io
NEXT_PUBLIC_API_QDRANT	https://qdrant.192.168.0.19.nip.io
NEXT_PUBLIC_API_MSTEAMS	https://msteams.192.168.0.19.nip.io
NEXT_PUBLIC_API_WHATSAPP	https://whatsapp.192.168.0.19.nip.io
NEXT_PUBLIC_API_STUDIO_BASE_URL	https://studio.192.168.0.19.nip.io
NEXT_PUBLIC_WEBUI_URL	https://webui.192.168.0.19.nip.io
NEXT_PUBLIC_APP_URL	https://daiana.192.168.0.19.nip.io
VAULT

cat > "$TMP_DIR/npm-hosts.json" <<'HOSTS'
[{"id":1,"domain_names":["api.192.168.0.19.nip.io"],"forward_scheme":"http","forward_host":"api","forward_port":5002,"certificate_id":4,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":true,"block_exploits":true,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]},{"id":2,"domain_names":["daiana.192.168.0.19.nip.io"],"forward_scheme":"http","forward_host":"daiana","forward_port":3000,"certificate_id":4,"ssl_forced":true,"hsts_enabled":true,"hsts_subdomains":false,"trust_forwarded_proto":true,"http2_support":true,"block_exploits":false,"caching_enabled":false,"allow_websocket_upgrade":true,"access_list_id":0,"advanced_config":null,"enabled":true,"locations":[]}]
HOSTS

cat > "$TMP_DIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
method=GET data= url=''
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2;;
    -d) data="$2"; shift 2;;
    --data-binary) if [[ "$2" == @- ]]; then data="$(cat)"; else data="$2"; fi; shift 2;;
    http://*) url="$1"; shift;;
    *) shift;;
  esac
done
path="${url#*://*/api}"
case "$method $path" in
  "GET /") printf '{}\n200\n';;
  "POST /tokens") printf '{"token":"fixture-token"}\n200\n';;
  "GET /nginx/proxy-hosts?per_page=200") printf '%s\n200\n' "$(<"${NPM_HOSTS_FILE:?}")";;
  "GET /nginx/proxy-hosts/1"|"GET /nginx/proxy-hosts/2") id="${path##*/}"; jq -c --argjson id "$id" '.[] | select(.id == $id)' "${NPM_HOSTS_FILE:?}"; printf '\n200\n';;
  "PUT /nginx/proxy-hosts/1"|"PUT /nginx/proxy-hosts/2")
    id="${path##*/}"
    if ! jq -e --argjson update "$data" '
      ($update | type == "object") and
      (["id", "created_on", "modified_on", "runtime_only"] | all(.[]; . as $key | ($update | has($key) | not))) and
      (($update | keys | length) == 17)
    ' <<<"{}" >/dev/null; then
      printf '{"error":"read-only proxy-host payload"}\n400\n'
      exit 0
    fi
    jq --argjson id "$id" --argjson update "$data" 'map(if .id == $id then . + $update else . end)' "${NPM_HOSTS_FILE:?}" > "${NPM_HOSTS_FILE:?}.tmp"
    mv "${NPM_HOSTS_FILE:?}.tmp" "${NPM_HOSTS_FILE:?}"
    printf '{}\n200\n'
    ;;
  *) printf '{}\n404\n';;
esac
CURL
chmod +x "$TMP_DIR/bin/curl"

cat > "$TMP_DIR/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
IFS= read -r _password
assignment() { local wanted="$1" arg; while (($# > 1)); do shift; arg="$1"; [[ "$arg" == "$wanted"=* ]] && { printf '%s' "${arg#*=}"; return; }; done; }
for arg in "$@"; do
  if [[ "$arg" == "-Atqc" ]]; then cat "${VAULT_DB_FILE:?}"; exit 0; fi
done
sql=''
while (($#)); do
  case "$1" in
    -c) sql="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$sql" == *"vault_upsert_secret"* ]]; then
  : > "$VAULT_DB_FILE"
  printf '%s\n' "$sql" | sed -nE "s/.*vault_upsert_secret\\('([^']*)', '([^']*)'.*/\\2\\t\\1/p" >> "$VAULT_DB_FILE"
  [[ "$(wc -l < "$VAULT_DB_FILE" | tr -d ' ')" == 9 ]] || exit 1
  exit 0
fi
exit 1
DOCKER
chmod +x "$TMP_DIR/bin/docker"

cat > "$TMP_DIR/update-daiana.sh" <<'UPDATE'
#!/usr/bin/env bash
: > update-called
UPDATE
chmod +x "$TMP_DIR/update-daiana.sh"

if (cd "$TMP_DIR" && PATH="$TMP_DIR/bin:$PATH" NPM_HOSTS_FILE="$TMP_DIR/npm-hosts.json" VAULT_DB_FILE="$TMP_DIR/vault.db" \
  NPM_API_URL=http://npm POSTGRES_PASSWORD=redacted-secret bash ./remove-certs.sh --confirm) >"$TMP_DIR/remove.out" 2>&1; then :; else
  cat "$TMP_DIR/remove.out" >&2
  printf 'remove-certs fixture failed\n' >&2
  exit 1
fi
jq -e 'all(.[]; .certificate_id == 0 and .ssl_forced == false and .hsts_enabled == false and .http2_support == false)' "$TMP_DIR/npm-hosts.json" >/dev/null
grep -q '^SUPABASE_PUBLIC_URL=http://' "$TMP_DIR/.env"
[[ -f "$TMP_DIR/update-called" ]]
