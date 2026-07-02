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

NPM_API_URL="${NPM_API_URL:-http://127.0.0.1:81}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:?Falta NPM_ADMIN_EMAIL}"
NPM_ADMIN_PASS="${NPM_ADMIN_PASS:?Falta NPM_ADMIN_PASS}"
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

# Dominio base para generarlos dinámicamente (ej: dnains.duckdns.org)
BASE_DOMAIN="${BASE_DOMAIN:-}"


wait_for_npm() {
  echo "Esperando NPM en $NPM_API_URL ..."
  for i in {1..120}; do
    response="$(curl -sS "$NPM_API_URL/api" -w '\n%{http_code}' || true)"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    case "$status" in
      2*|3*)
        echo "NPM listo."
        return 0
        ;;
    esac
    if [[ "$i" == 1 || $((i % 10)) -eq 0 ]]; then
      echo "NPM aún no está listo (HTTP $status): $body"
    fi
    sleep 2
  done
  echo "NPM no respondió a tiempo."
  exit 1
}

npm_request() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local extra=()
  local response status body
  response="$(curl -sS -X "$method" "$NPM_API_URL$path" \
    ${TOKEN:+-H "Authorization: Bearer $TOKEN"} \
    -H "Content-Type: application/json" \
    ${data:+-d "$data"} \
    -w '\n%{http_code}' || true)"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "NPM $method $path falló (HTTP $status):" >&2
    echo "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

login() {
  local token payload
  payload="$(jq -n --arg identity "$NPM_ADMIN_EMAIL" \
    --arg secret "$NPM_ADMIN_PASS" \
    '{identity:$identity, secret:$secret}')"
  token="$(npm_request POST /api/tokens "$payload" | jq -r '.token')"
  if [[ -z "$token" || "$token" == "null" ]]; then
    echo "No pude autenticar en NPM (revisa NPM_ADMIN_EMAIL/NPM_ADMIN_PASS)." >&2
    exit 1
  fi
  echo "$token"
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
  api_get "/api/nginx/certificates?per_page=200" \
  | jq -r --arg d "$domain" '
      (if type=="object" and has("data") then .data else . end)
      | .[]
      | select(.provider=="letsencrypt")
      | select((.domain_names // []) | index($d))
      | .id
    ' | head -n1
}

create_letsencrypt_certificate() {
  local domain="$1"
  # NPM crea 1 cert por set de dominios; aquí hacemos 1 dominio por cert (simple)
  local payload
  payload="$(jq -n \
    --arg d "$domain" \
    '{
      provider: "letsencrypt",
      nice_name: $d,
      domain_names: [$d]
    }')"

  echo "Creando certificado Let's Encrypt para: $domain" >&2
  api_post "/api/nginx/certificates" "$payload" | jq -r '.id'
}

find_custom_certificate_id() {
  local name="$1"
  api_get "/api/nginx/certificates?per_page=200" \
  | jq -r --arg n "$name" '
      (if type=="object" and has("data") then .data else . end)
      | .[]?
      | select(.provider=="other")
      | select((.nice_name // .name // "") == $n)
      | .id
    ' | head -n1
}

create_custom_certificate_record() {
  local name="$1"
  local payload
  payload="$(jq -n --arg n "$name" '{provider:"other", nice_name:$n}')"
  echo "Creando certificado custom en NPM: $name" >&2
  api_post "/api/nginx/certificates" "$payload" | jq -r '.id'
}

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
    set -- $(local_cert_paths_for_prefix "$prefix")
    NPM_LOCAL_CERT_FILE="$1"
    NPM_LOCAL_KEY_FILE="$2"
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

  if [[ -f "$cert_path" && -f "$key_path" ]]; then
    return 0
  fi

  echo "Generando certificado local auto-firmado para $domain" >&2
  mkdir -p "$(dirname "$cert_path")"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$key_path" \
    -out "$cert_path" \
    -subj "/CN=$domain" >/dev/null 2>&1
  chmod 640 "$key_path"
  chgrp 65533 "$key_path" 2>/dev/null || true
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
  response="$(curl -sS -X POST "$NPM_API_URL/api/nginx/certificates/$cert_id/upload" \
    ${TOKEN:+-H "Authorization: Bearer $TOKEN"} \
    -F "certificate=@$cert_path" \
    -F "certificate_key=@$key_path" \
    -w '\n%{http_code}' || true)"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "NPM POST /api/nginx/certificates/$cert_id/upload falló (HTTP $status):" >&2
    echo "$body" >&2
    return 1
  fi
}

ensure_custom_certificate() {
  local cert_id
  cert_id="$(find_custom_certificate_id "$NPM_LOCAL_CERT_NAME" || true)"
  if [[ -z "$cert_id" || "$cert_id" == "null" ]]; then
    cert_id="$(create_custom_certificate_record "$NPM_LOCAL_CERT_NAME")"
  fi
  [[ -n "$cert_id" && "$cert_id" != "null" ]] || { echo "No pude crear/ubicar el certificado custom de NPM" >&2; return 1; }
  upload_custom_certificate "$cert_id" "$NPM_LOCAL_CERT_FILE" "$NPM_LOCAL_KEY_FILE"
  echo "$cert_id"
}

ensure_certificate() {
  local domain="$1"
  local cert_id=""
  cert_id="$(find_certificate_id_for_domain "$domain" || true)"
  if [[ -n "$cert_id" && "$cert_id" != "null" ]]; then
    echo "Cert existente para $domain (id=$cert_id)" >&2
    echo "$cert_id"
    return 0
  fi

  cert_id="$(create_letsencrypt_certificate "$domain" || true)"
  if [[ -n "$cert_id" && "$cert_id" != "null" ]]; then
    echo "Cert Let's Encrypt creado para $domain (id=$cert_id)" >&2
    echo "$cert_id"
    return 0
  fi

  cert_id="$(find_certificate_id_for_domain "$domain" || true)"
  if [[ -n "$cert_id" && "$cert_id" != "null" ]]; then
    echo "Cert encontrado para $domain después de crear (id=$cert_id)" >&2
    echo "$cert_id"
    return 0
  fi

  echo "No se pudo crear certificado automático para $domain; seguimos sin TLS forzado." >&2
  echo ""
}

# Busca proxy host existente por dominio
find_proxy_host_id_for_domain() {
  local domain="$1"
  api_get "/api/nginx/proxy-hosts?per_page=200" \
  | jq -r --arg d "$domain" '
      (if type=="object" and has("data") then .data else . end)
      | .[]
      | select((.domain_names // []) | index($d))
      | .id
    ' | head -n1
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
  local payload

  payload="$(proxy_host_payload "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id")"
  echo "Creando Proxy Host: $domain -> http://$upstream_host:$upstream_port (cert=$cert_id)"
  api_post "/api/nginx/proxy-hosts" "$payload" >/dev/null
}

update_proxy_host() {
  local prefix="$1"
  local domain="$2"
  local upstream_host="$3"
  local upstream_port="$4"
  local cert_id="$5"
  local id="$6"
  local payload

  payload="$(proxy_host_payload "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id")"
  echo "Actualizando Proxy Host: $domain (id=$id) -> http://$upstream_host:$upstream_port (cert=$cert_id)"
  response="$(curl -sS -X PUT "$NPM_API_URL/api/nginx/proxy-hosts/$id" \
    ${TOKEN:+-H "Authorization: Bearer $TOKEN"} \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    -w '\n%{http_code}' || true)"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "NPM PUT /api/nginx/proxy-hosts/$id falló (HTTP $status):" >&2
    echo "$body" >&2
    return 1
  fi
}

ensure_proxy_host() {
  local prefix="$1"
  local domain="$2"
  local upstream_host="$3"
  local upstream_port="$4"
  local cert_id="$5"

  local id
  id="$(find_proxy_host_id_for_domain "$domain" || true)"
  if [[ -n "$id" && "$id" != "null" ]]; then
    update_proxy_host "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id" "$id"
    return 0
  fi

  if [[ "$ENSURE_PROXY_HOSTS" == "1" ]]; then
    create_proxy_host "$prefix" "$domain" "$upstream_host" "$upstream_port" "$cert_id"
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

  wait_for_npm
  TOKEN="$(login)"

  if [[ -z "$TLS_MODE" ]]; then
    if [[ "$USE_LOCAL_TLS_CERTS" == "1" ]]; then
      TLS_MODE="local"
    else
      TLS_MODE="letsencrypt"
    fi
  fi

  CUSTOM_CERT_ID=""
  case "$TLS_MODE" in
    none)
      ;;
    local)
      if [[ -n "$ONLY_PREFIX" ]]; then
        configure_local_tls_for_prefix "$ONLY_PREFIX"
        ensure_local_certificate_files "$(resolve_domain_for_prefix "$ONLY_PREFIX")"
      else
        ensure_local_certificate_files "$BASE_DOMAIN"
      fi
      CUSTOM_CERT_ID="$(ensure_custom_certificate)"
      echo "Usando certificado local NPM id=$CUSTOM_CERT_ID" >&2
      ;;
    custom)
      NPM_LOCAL_CERT_NAME="$NPM_CUSTOM_CERT_NAME"
      NPM_LOCAL_CERT_FILE="$NPM_CUSTOM_CERT_FILE"
      NPM_LOCAL_KEY_FILE="$NPM_CUSTOM_KEY_FILE"
      CUSTOM_CERT_ID="$(ensure_custom_certificate)"
      echo "Usando certificado propio NPM id=$CUSTOM_CERT_ID" >&2
      ;;
    letsencrypt)
      ;;
    *)
      echo "TLS_MODE inválido: $TLS_MODE" >&2
      exit 1
      ;;
  esac

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
  )

  SERVICES+=("msteams:daiana-msteams:3978")

  matched=0
  tls_certificate_failures=0
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
    eval "up_host=\"\${${up_host_var}:-$default_host}\""
    eval "up_port=\"\${${up_port_var}:-$default_port}\""
    eval "custom_domain=\"\${${domain_var}:-}\""

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
        cert_id="$(ensure_certificate "$domain")"
        if [[ -z "$cert_id" || "$cert_id" == "null" ]]; then
          tls_certificate_failures=$((tls_certificate_failures + 1))
        fi
        ;;
      local|custom)
        cert_id="$CUSTOM_CERT_ID"
        ;;
      *)
        cert_id=""
        ;;
    esac
    ensure_proxy_host "$prefix" "$domain" "$up_host" "$up_port" "$cert_id"
  done

  if [[ -n "$ONLY_PREFIX" && "$matched" -eq 0 ]]; then
    echo "No se encontró ningún proxy host para ONLY_PREFIX=$ONLY_PREFIX" >&2
    exit 1
  fi

  case "$TLS_MODE" in
    none)
      if [[ -n "$ONLY_PREFIX" ]]; then
        echo "Listo: proxy host $ONLY_PREFIX actualizado sin TLS forzado."
      else
        echo "Listo: proxy hosts creados sin TLS."
      fi
      ;;
    *)
      if [[ "$tls_certificate_failures" -gt 0 ]]; then
        if [[ -n "$ONLY_PREFIX" ]]; then
          echo "Listo: proxy host $ONLY_PREFIX actualizado sin certificado TLS; revisá los errores anteriores."
        else
          echo "Listo: proxy hosts actualizados, pero $tls_certificate_failures certificado(s) Let's Encrypt no se pudieron crear."
        fi
      elif [[ -n "$ONLY_PREFIX" ]]; then
        echo "Listo: proxy host $ONLY_PREFIX actualizado con certificado."
      else
        echo "Listo: proxy hosts actualizados con certificados."
      fi
      ;;
  esac
}

main "$@"
