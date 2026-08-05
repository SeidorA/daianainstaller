#!/usr/bin/env bash

# Called only after every intended NPM host has passed TLS verification.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_PROJECT_NAME="daiana-app"
COMPOSE_BASE=("$ROOT_DIR/docker-compose.yml" "$ROOT_DIR/docker-compose.app.yml")
PUBLIC_URL_KEYS=(
  STUDIO_BASE_URL SUPABASE_PUBLIC_URL API_EXTERNAL_URL SITE_URL WEBUI_BASE_URL
  BACKEND_BASE_URL WS_BASE_URL MS_BASE_URL VANNA_BASE_URL QDRANT_BASE_URL
  CORS_ALLOW_ORIGIN NEXT_PUBLIC_APP_URL
)
PUBLIC_URL_VAULT_NAMES=(
  NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_API_PYTHON NEXT_PUBLIC_API_TRAINING
  NEXT_PUBLIC_API_QDRANT NEXT_PUBLIC_API_MSTEAMS NEXT_PUBLIC_API_WHATSAPP
  NEXT_PUBLIC_API_STUDIO_BASE_URL NEXT_PUBLIC_WEBUI_URL NEXT_PUBLIC_APP_URL
)

require_installer_compose_identity() {
  if [[ "${DAIANA_COMPOSE_PROJECT_NAME+x}" == x && "${DAIANA_COMPOSE_PROJECT_NAME}" != "$COMPOSE_PROJECT_NAME" ]]; then
    printf 'ERROR: DAIANA_COMPOSE_PROJECT_NAME is not overridable; expected exactly %s\n' "$COMPOSE_PROJECT_NAME" >&2
    return 1
  fi
}

public_url_key() {
  local key="$1"
  case " ${PUBLIC_URL_KEYS[*]} " in *" $key "*) return 0 ;; *) return 1 ;; esac
}

public_url_scheme() {
  local domain="${BASE_DOMAIN:-}"
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  case "$domain" in
    *.nip.io) printf 'http' ;;
    *) printf 'https' ;;
  esac
}

public_url_value_for_key() {
  local key="$1" domain="${BASE_DOMAIN:-}" scheme="${2:-}"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
  [[ -n "$scheme" ]] || scheme="$(public_url_scheme)" || return 1
  [[ "$scheme" == http || "$scheme" == https ]] || return 1
  case "$key" in
    STUDIO_BASE_URL) printf '%s://studio.%s' "$scheme" "$domain" ;;
    SUPABASE_PUBLIC_URL) printf '%s://supa.%s' "$scheme" "$domain" ;;
    API_EXTERNAL_URL) printf '%s://supa.%s/auth/v1' "$scheme" "$domain" ;;
    SITE_URL|CORS_ALLOW_ORIGIN|NEXT_PUBLIC_APP_URL) printf '%s://daiana.%s' "$scheme" "$domain" ;;
    WEBUI_BASE_URL) printf '%s://webui.%s' "$scheme" "$domain" ;;
    BACKEND_BASE_URL) printf '%s://api.%s' "$scheme" "$domain" ;;
    WS_BASE_URL) printf '%s://whatsapp.%s' "$scheme" "$domain" ;;
    MS_BASE_URL) printf '%s://msteams.%s' "$scheme" "$domain" ;;
    VANNA_BASE_URL) printf '%s://vanna.%s' "$scheme" "$domain" ;;
    QDRANT_BASE_URL) printf '%s://qdrant.%s' "$scheme" "$domain" ;;
    *) return 1 ;;
  esac
}

public_url_expected_values() {
  local key value scheme="${1:-}"
  [[ -n "${BASE_DOMAIN:-}" ]] || return 1
  [[ -n "$scheme" ]] || scheme="$(public_url_scheme)" || return 1
  for key in "${PUBLIC_URL_KEYS[@]}"; do
    value="$(public_url_value_for_key "$key" "$scheme")" || return 1
    [[ "$value" == "$scheme://"* ]] || return 1
    printf '%s=%s\n' "$key" "$value"
  done
}

validate_public_url_set() {
  local expected_file key expected actual status=0 scheme="${1:-}"
  [[ -n "$scheme" ]] || scheme="$(public_url_scheme)" || return 1
  expected_file="$(mktemp "${TMPDIR:-/tmp}/public-url-expected.XXXXXX")" || return 1
  if ! public_url_expected_values "$scheme" > "$expected_file"; then
    rm -f "$expected_file"
    return 1
  fi
  while IFS='=' read -r key expected; do
    [[ -n "$key" && "$expected" == "$scheme://"* ]] || { status=1; break; }
    actual="${!key:-}"
    [[ -n "$actual" && "$actual" == "$expected" ]] || { status=1; break; }
  done < "$expected_file"
  rm -f "$expected_file"
  return "$status"
}

env_value() {
  local env_file="$1" key="$2"
  awk -v key="$key" '
    function is_target(line,   rest) {
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^export[[:space:]]+/) sub(/^export[[:space:]]+/, "", line)
      return line ~ ("^" key "([[:space:]]|=|$)")
    }
    {
      line = $0
      if (line ~ /^[[:space:]]*#/) next
      if (!is_target(line)) next
      count++
      if (line !~ ("^([[:space:]]*)" key "=")) malformed = 1
      value = line
      sub("^[^=]*=", "", value)
    }
    END { if (count != 1 || malformed) exit 1; print value }
  ' "$env_file"
}

validate_public_env_structure() {
  local env_file="$1" key scheme="${2:-}"
  [[ -n "$scheme" ]] || scheme="$(public_url_scheme)" || return 1
  for key in "${PUBLIC_URL_KEYS[@]}"; do
    env_value "$env_file" "$key" >/dev/null || return 1
  done
}

validate_public_env_file() {
  local env_file="$1" expected_file key actual expected status=0 scheme="${2:-}"
  [[ -n "$scheme" ]] || scheme="$(public_url_scheme)" || return 1
  [[ -f "$env_file" ]] || return 1
  validate_public_env_structure "$env_file" "$scheme" || return 1
  expected_file="$(mktemp "${TMPDIR:-/tmp}/public-url-expected.XXXXXX")" || return 1
  if ! public_url_expected_values "$scheme" > "$expected_file"; then
    rm -f "$expected_file"
    return 1
  fi
  while IFS='=' read -r key expected; do
    if [[ -z "$key" || "$expected" != "$scheme://"* ]]; then status=1; break; fi
    if ! actual="$(env_value "$env_file" "$key")" || [[ "$actual" != "$expected" ]]; then
      status=1
      break
    fi
  done < "$expected_file"
  rm -f "$expected_file"
  return "$status"
}

validate_public_source_env_file() {
  local env_file="$1" key actual expected_http expected_https status=0
  [[ -f "$env_file" ]] || return 1
  validate_public_env_structure "$env_file" || return 1
  for key in "${PUBLIC_URL_KEYS[@]}"; do
    if ! actual="$(env_value "$env_file" "$key")"; then
      status=1
      break
    fi
    expected_https="$(public_url_value_for_key "$key" https)" || { status=1; break; }
    expected_http="http://${expected_https#https://}"
    if [[ "$actual" != "$expected_http" && "$actual" != "$expected_https" ]]; then
      status=1
      break
    fi
  done
  return "$status"
}

persist_public_env_value() {
  local env_file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "${env_file}.tmp.XXXXXX")" || return 1
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" { print key "=" value; done = 1; next }
    { print }
    END { if (done == 0) print key "=" value }
  ' "$env_file" > "$tmp" && mv "$tmp" "$env_file"
}

stage_public_env_update() {
  local env_file="${1:-.env}" key value stage scheme="${2:-}"
  [[ -f "$env_file" ]] || return 1
  [[ -n "$scheme" ]] || scheme="$(public_url_scheme)" || return 1
  # The source may still be the valid HTTP projection written during install.
  # Only the staged projection is required to be the exact HTTPS set.
  validate_public_source_env_file "$env_file" || return 1
  stage="$(mktemp "${env_file}.stage.XXXXXX")" || return 1
  cp -p "$env_file" "$stage" || { rm -f "$stage"; return 1; }
  for key in "${PUBLIC_URL_KEYS[@]}"; do
    value="$(public_url_value_for_key "$key" "$scheme")" || { rm -f "$stage"; return 1; }
    persist_public_env_value "$stage" "$key" "$value" || { rm -f "$stage"; return 1; }
  done
  validate_public_env_file "$stage" "$scheme" || { rm -f "$stage"; return 1; }
  printf '%s' "$stage"
}

rewrite_public_urls_in_env() {
  local env_file="${1:-.env}" stage scheme="${2:-}"
  [[ -n "$scheme" ]] || scheme="$(public_url_scheme)" || return 1
  stage="$(stage_public_env_update "$env_file" "$scheme")" || return 1
  mv "$stage" "$env_file"
}

vault_psql_with_password() {
  local xtrace_was_enabled=0 psql_status=0
  require_installer_compose_identity || return 1
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  printf '%s\n' "$POSTGRES_PASSWORD" | docker compose \
    --project-name "$COMPOSE_PROJECT_NAME" --project-directory "$ROOT_DIR" \
    -f "${COMPOSE_BASE[0]}" -f "${COMPOSE_BASE[1]}" exec -T db \
    sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql "$@"' sh \
    "$@" || psql_status=$?
  if (( xtrace_was_enabled )); then set -x; fi
  return "$psql_status"
}

sql_string_literal() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}

vault_upsert_public_url_entries() {
  local env_file="${1:-.env}" scheme="${2:-}" sql
  local public_supabase_url public_api_python public_api_training public_api_qdrant
  local public_api_msteams public_api_whatsapp public_api_studio public_webui public_app
  command -v docker >/dev/null 2>&1 || return 1
  [[ -n "${POSTGRES_PASSWORD:-}" ]] || return 1
  case "$scheme" in
    http|https) ;;
    *) return 1 ;;
  esac
  validate_public_env_file "$env_file" "$scheme" || return 1
  public_supabase_url="$(env_value "$env_file" SUPABASE_PUBLIC_URL)" || return 1
  public_api_python="$(env_value "$env_file" BACKEND_BASE_URL)" || return 1
  public_api_training="$(env_value "$env_file" VANNA_BASE_URL)" || return 1
  public_api_qdrant="$(env_value "$env_file" QDRANT_BASE_URL)" || return 1
  public_api_msteams="$(env_value "$env_file" MS_BASE_URL)" || return 1
  public_api_whatsapp="$(env_value "$env_file" WS_BASE_URL)" || return 1
  public_api_studio="$(env_value "$env_file" STUDIO_BASE_URL)" || return 1
  public_webui="$(env_value "$env_file" WEBUI_BASE_URL)" || return 1
  public_app="$(env_value "$env_file" NEXT_PUBLIC_APP_URL)" || return 1
  sql="BEGIN;
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_supabase_url"), 'NEXT_PUBLIC_SUPABASE_URL', 'This is the description');
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_api_python"), 'NEXT_PUBLIC_API_PYTHON', 'This is the description');
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_api_training"), 'NEXT_PUBLIC_API_TRAINING', 'This is the description');
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_api_qdrant"), 'NEXT_PUBLIC_API_QDRANT', 'This is the description');
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_api_msteams"), 'NEXT_PUBLIC_API_MSTEAMS', 'This is the description');
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_api_whatsapp"), 'NEXT_PUBLIC_API_WHATSAPP', 'This is the description');
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_api_studio"), 'NEXT_PUBLIC_API_STUDIO_BASE_URL', 'This is the description');
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_webui"), 'NEXT_PUBLIC_WEBUI_URL', 'This is the description');
       SELECT public.vault_upsert_secret($(sql_string_literal "$public_app"), 'NEXT_PUBLIC_APP_URL', 'This is the description');
       DO \$\$
        DECLARE public_url_vault_mismatch boolean;
        BEGIN
          WITH expected(name, value) AS (VALUES
             ('NEXT_PUBLIC_SUPABASE_URL', $(sql_string_literal "$public_supabase_url")),
             ('NEXT_PUBLIC_API_PYTHON', $(sql_string_literal "$public_api_python")),
             ('NEXT_PUBLIC_API_TRAINING', $(sql_string_literal "$public_api_training")),
             ('NEXT_PUBLIC_API_QDRANT', $(sql_string_literal "$public_api_qdrant")),
             ('NEXT_PUBLIC_API_MSTEAMS', $(sql_string_literal "$public_api_msteams")),
             ('NEXT_PUBLIC_API_WHATSAPP', $(sql_string_literal "$public_api_whatsapp")),
             ('NEXT_PUBLIC_API_STUDIO_BASE_URL', $(sql_string_literal "$public_api_studio")),
             ('NEXT_PUBLIC_WEBUI_URL', $(sql_string_literal "$public_webui")),
             ('NEXT_PUBLIC_APP_URL', $(sql_string_literal "$public_app"))),
          actual(name, value) AS (
            SELECT name, decrypted_secret
            FROM public.vault_access()
            WHERE name IN (SELECT name FROM expected)
          )
          SELECT (SELECT count(*) FROM expected) <> 9
              OR (SELECT count(*) FROM actual) <> 9
               OR EXISTS (SELECT 1 FROM expected WHERE value NOT LIKE '$scheme://%')
              OR (SELECT count(*) FROM expected e JOIN actual a USING (name, value)) <> 9
            INTO public_url_vault_mismatch;
          IF public_url_vault_mismatch THEN
            RAISE EXCEPTION 'public URL Vault verification failed';
          END IF;
        END \$\$;
        COMMIT;"
  # Feed the password through stdin so it never appears in docker/ps argv.
  vault_psql_with_password -X -q -U "${VAULT_DB_USER:-supabase_admin}" -d "${POSTGRES_DB:-postgres}" \
    -v ON_ERROR_STOP=1 -c "$sql" >/dev/null
}

vault_snapshot_public_url_entries() {
  local output_file="$1" sql
  sql="SELECT name || E'\\t' || decrypted_secret FROM public.vault_access() WHERE name IN ($(printf "'%s'," "${PUBLIC_URL_VAULT_NAMES[@]}" | sed 's/,$//')) ORDER BY name;"
  umask 077
  vault_psql_with_password -X -q -U "${VAULT_DB_USER:-supabase_admin}" -d "${POSTGRES_DB:-postgres}" \
    -v ON_ERROR_STOP=1 -Atqc "$sql" > "$output_file" || return 1
  [[ "$(wc -l < "$output_file" | tr -d ' ')" == "${#PUBLIC_URL_VAULT_NAMES[@]}" ]]
  vault_snapshot_public_url_scheme "$output_file" >/dev/null
}

vault_snapshot_public_url_scheme() {
  local snapshot_file="$1" name value scheme="" current_scheme count=0 seen_names="" expected
  [[ -f "$snapshot_file" ]] || return 1
  while IFS=$'\t' read -r name value; do
    [[ -n "$name" && -n "$value" ]] || return 1
    case "$name" in
      NEXT_PUBLIC_SUPABASE_URL|NEXT_PUBLIC_API_PYTHON|NEXT_PUBLIC_API_TRAINING|NEXT_PUBLIC_API_QDRANT|NEXT_PUBLIC_API_MSTEAMS|NEXT_PUBLIC_API_WHATSAPP|NEXT_PUBLIC_API_STUDIO_BASE_URL|NEXT_PUBLIC_WEBUI_URL|NEXT_PUBLIC_APP_URL) ;;
      *) return 1 ;;
    esac
    case " $seen_names " in *" $name "*) return 1 ;; esac
    seen_names="$seen_names $name"
    [[ "$value" =~ ^(http|https)://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]+)?$ ]] || return 1
    current_scheme="${BASH_REMATCH[1]}"
    if [[ -z "$scheme" ]]; then
      scheme="$current_scheme"
    elif [[ "$scheme" != "$current_scheme" ]]; then
      return 1
    fi
    expected="$(public_url_value_for_vault_name "$name" "$current_scheme")" || return 1
    [[ "$value" == "$expected" ]] || return 1
    count=$((count + 1))
  done < "$snapshot_file"
  [[ "$count" == "${#PUBLIC_URL_VAULT_NAMES[@]}" ]] || return 1
  printf '%s' "$scheme"
}

public_url_value_for_vault_name() {
  local name="$1" scheme="$2" domain="${BASE_DOMAIN:-}" host
  [[ "$scheme" == http || "$scheme" == https ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || return 1
  case "$name" in
    NEXT_PUBLIC_SUPABASE_URL) host="supa.$domain" ;;
    NEXT_PUBLIC_API_PYTHON) host="api.$domain" ;;
    NEXT_PUBLIC_API_TRAINING) host="vanna.$domain" ;;
    NEXT_PUBLIC_API_QDRANT) host="qdrant.$domain" ;;
    NEXT_PUBLIC_API_MSTEAMS) host="msteams.$domain" ;;
    NEXT_PUBLIC_API_WHATSAPP) host="whatsapp.$domain" ;;
    NEXT_PUBLIC_API_STUDIO_BASE_URL) host="studio.$domain" ;;
    NEXT_PUBLIC_WEBUI_URL) host="webui.$domain" ;;
    NEXT_PUBLIC_APP_URL) host="daiana.$domain" ;;
    *) return 1 ;;
  esac
  printf '%s://%s' "$scheme" "$host"
}

vault_restore_public_url_entries() {
  local snapshot_file="$1" sql name value
  local seen_names="" seen_count=0
  vault_snapshot_public_url_scheme "$snapshot_file" >/dev/null || return 1
  sql='BEGIN;'
  while IFS=$'\t' read -r name value; do
    [[ -n "$name" && -n "$value" ]] || return 1
    case "$name" in
      NEXT_PUBLIC_SUPABASE_URL|NEXT_PUBLIC_API_PYTHON|NEXT_PUBLIC_API_TRAINING|NEXT_PUBLIC_API_QDRANT|NEXT_PUBLIC_API_MSTEAMS|NEXT_PUBLIC_API_WHATSAPP|NEXT_PUBLIC_API_STUDIO_BASE_URL|NEXT_PUBLIC_WEBUI_URL|NEXT_PUBLIC_APP_URL) ;;
      *) return 1 ;;
    esac
    [[ "$value" =~ ^https?://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]+)?$ ]] || return 1
    case " $seen_names " in *" $name "*) return 1 ;; esac
    seen_names="$seen_names $name"
    seen_count=$((seen_count + 1))
    sql+=$'\n'"SELECT public.vault_upsert_secret($(sql_string_literal "$value"), $(sql_string_literal "$name"), 'This is the description');"
  done < "$snapshot_file"
  [[ "$seen_count" == "${#PUBLIC_URL_VAULT_NAMES[@]}" ]] || return 1
  sql+=$'\nCOMMIT;'
  vault_psql_with_password -X -q -U "${VAULT_DB_USER:-supabase_admin}" -d "${POSTGRES_DB:-postgres}" \
    -v ON_ERROR_STOP=1 -c "$sql" >/dev/null
}

vault_verify_public_url_entries() {
  local snapshot_file="$1" expected_scheme="${2:-}" sql name value
  local seen_names="" seen_count=0
  case "$expected_scheme" in
    http|https) ;;
    *) return 1 ;;
  esac
  [[ "$(vault_snapshot_public_url_scheme "$snapshot_file")" == "$expected_scheme" ]] || return 1
  sql=$'BEGIN;\nDO $$\nDECLARE public_url_vault_mismatch boolean;\nBEGIN\n'
  while IFS=$'\t' read -r name value; do
    [[ -n "$name" && -n "$value" ]] || return 1
    case "$name" in
      NEXT_PUBLIC_SUPABASE_URL|NEXT_PUBLIC_API_PYTHON|NEXT_PUBLIC_API_TRAINING|NEXT_PUBLIC_API_QDRANT|NEXT_PUBLIC_API_MSTEAMS|NEXT_PUBLIC_API_WHATSAPP|NEXT_PUBLIC_API_STUDIO_BASE_URL|NEXT_PUBLIC_WEBUI_URL|NEXT_PUBLIC_APP_URL) ;;
      *) return 1 ;;
    esac
    [[ "$value" =~ ^${expected_scheme}://[A-Za-z0-9.-]+(/[A-Za-z0-9._/-]+)?$ ]] || return 1
    case " $seen_names " in *" $name "*) return 1 ;; esac
    seen_names="$seen_names $name"
    seen_count=$((seen_count + 1))
  done < "$snapshot_file"
  [[ "$seen_count" == "${#PUBLIC_URL_VAULT_NAMES[@]}" ]] || return 1
  sql+=$'  WITH expected(name, value) AS (VALUES\n'
  local index=0
  while IFS=$'\t' read -r name value; do
    index=$((index + 1))
    [[ "$index" == 1 ]] || sql+=$',\n'
    sql+="    ($(sql_string_literal "$name"), $(sql_string_literal "$value"))"
  done < "$snapshot_file"
  sql+=$');\n'
  sql+=$'  SELECT (SELECT count(*) FROM expected) <> 9\n'
  sql+=$'      OR (SELECT count(*) FROM public.vault_access() va WHERE va.name IN (SELECT name FROM expected)) <> 9\n'
  sql+=$'      OR (SELECT count(*) FROM expected e JOIN (SELECT name, decrypted_secret AS value FROM public.vault_access()) va USING (name, value)) <> 9\n'
  sql+=$'    INTO public_url_vault_mismatch;\n'
  sql+=$'  IF public_url_vault_mismatch THEN RAISE EXCEPTION \'public URL Vault restoration verification failed\'; END IF;\n'
  sql+=$'END $$;\nCOMMIT;'
  vault_psql_with_password -X -q -U "${VAULT_DB_USER:-supabase_admin}" -d "${POSTGRES_DB:-postgres}" \
    -v ON_ERROR_STOP=1 -c "$sql" >/dev/null
}
