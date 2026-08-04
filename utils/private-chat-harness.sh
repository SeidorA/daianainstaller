#!/usr/bin/env bash
set -euo pipefail

# Registry-free, local candidate harness. Only the four application containers
# are ever recreated.  In particular, this script does not use Portainer,
# pull images, remove volumes, or change the external network.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${DAIANA_HARNESS_STATE_DIR:-$ROOT_DIR/.private-chat-harness}"
NETWORK_NAME="daiana-mgmt"
COMPOSE_PROJECT_NAME="daiana-app"
COMPOSE_MUTATION_SERVICES=(daianapython daiananext daianamsteams daianastudio)
NEXT_CONTAINER="daiana-next"
PYTHON_CONTAINER="daiana-python"
MSTEAMS_CONTAINER="daiana-msteams"
STUDIO_CONTAINER="daiana-studio"
NEXT_BASE_IMAGE="cloudseidoranalytics/daiana:v2.1.9"
PYTHON_BASE_IMAGE="cloudseidoranalytics/daianapython:v2.1.9"
MSTEAMS_BASE_IMAGE="cloudseidoranalytics/daianamsteams:v2.1.9"
STUDIO_BASE_IMAGE="cloudseidoranalytics/daianastudio:v3.1.3"
APPROVED_NEXT_IMAGE_REPOSITORY="cloudseidoranalytics/daiana"
APPROVED_PYTHON_IMAGE_REPOSITORY="cloudseidoranalytics/daianapython"
APPROVED_MSTEAMS_IMAGE_REPOSITORY="cloudseidoranalytics/daianamsteams"
APPROVED_STUDIO_IMAGE_REPOSITORY="cloudseidoranalytics/daianastudio"
MIGRATION_120000="20260731120000_add_flowise_quota_finalization.sql"
MIGRATION_130000="20260727130000_add_history_message_refs.sql"
MIGRATION_140000="20260727140000_allow_authorized_private_message_quota.sql"
COMPOSE_BASE=("$ROOT_DIR/docker-compose.yml" "$ROOT_DIR/docker-compose.app.yml")
COMPOSE_CANDIDATE=("${COMPOSE_BASE[@]}" "$ROOT_DIR/docker-compose.private-chat-candidate.yml")
PRIVATE_CHAT_MIGRATION_DIR=""
PRIVATE_CHAT_STAGING_DIR=""
PRIVATE_CHAT_FINGERPRINT_DIR=""
RUNTIME_MUTATION_STARTED=0
ACTIVATION_COMMITTED=0
CLEANUP_COMMITTED=0
COMPENSATING=0
ACTIVATION_STATE_CREATED=0
MIGRATION_APPLIED=0
MIGRATION_BOUNDARY_PENDING=0
MIGRATION_SIGNAL_PENDING=0
CLEANUP_ATTEMPTED=0
CLEANUP_VALIDATION_MODE=0
LAST_FAILURE_REASON=""

die() {
  LAST_FAILURE_REASON="$*"
  if (( CLEANUP_VALIDATION_MODE )); then
    printf 'ERROR: %s\n' "$*" >&2
    # Validators are composed of `condition || die` assertions.  Returning
    # here would let the caller continue after a failed assertion; exit keeps
    # the pre-mutation boundary fail-closed while on_exit retains evidence.
    exit 1
  fi
  if [[ -e "${STATE_DIR:-}/active" || "${MIGRATION_APPLIED:-0}" == 1 ]]; then
    write_failure_diagnostics "$*" 2>/dev/null || true
    if [[ "${CLEANUP_ATTEMPTED:-0}" == 1 ]]; then
      mark_manual_cleanup "$*" 2>/dev/null || true
    fi
  fi
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
log() { printf '===> %s\n' "$*"; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1
  else shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

hex_encode() { LC_ALL=C od -An -v -tx1 | tr -d ' \n'; }

text_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d ' ' -f 1
  else shasum -a 256 | cut -d ' ' -f 1
  fi
}

docker_cmd() { docker "$@"; }

cleanup_private_chat_temp() {
  if [[ -n "$PRIVATE_CHAT_MIGRATION_DIR" && -d "$PRIVATE_CHAT_MIGRATION_DIR" ]]; then
    rm -rf "$PRIVATE_CHAT_MIGRATION_DIR"
    PRIVATE_CHAT_MIGRATION_DIR=""
  fi
  if [[ -n "$PRIVATE_CHAT_STAGING_DIR" && -d "$PRIVATE_CHAT_STAGING_DIR" ]]; then
    rm -rf "$PRIVATE_CHAT_STAGING_DIR"
    PRIVATE_CHAT_STAGING_DIR=""
  fi
  cleanup_fingerprint_temp
}

cleanup_fingerprint_temp() {
  if [[ -n "$PRIVATE_CHAT_FINGERPRINT_DIR" && -d "$PRIVATE_CHAT_FINGERPRINT_DIR" ]]; then
    rm -rf "$PRIVATE_CHAT_FINGERPRINT_DIR"
    PRIVATE_CHAT_FINGERPRINT_DIR=""
  fi
}

compose_base() {
  docker compose --project-name "$COMPOSE_PROJECT_NAME" --project-directory "$ROOT_DIR" -f "${COMPOSE_BASE[0]}" -f "${COMPOSE_BASE[1]}" "$@"
}

compose_candidate() {
  docker compose --project-name "$COMPOSE_PROJECT_NAME" --project-directory "$ROOT_DIR" -f "${COMPOSE_CANDIDATE[0]}" -f "${COMPOSE_CANDIDATE[1]}" -f "${COMPOSE_CANDIDATE[2]}" "$@"
}

compose_candidate_overlay() {
  docker compose --project-name "$COMPOSE_PROJECT_NAME" --project-directory "$ROOT_DIR" -f "$ROOT_DIR/docker-compose.private-chat-candidate.yml" "$@"
}

service_container() {
  case "$1" in
    daiananext) printf '%s\n' "$NEXT_CONTAINER" ;;
    daianapython) printf '%s\n' "$PYTHON_CONTAINER" ;;
    daianamsteams) printf '%s\n' "$MSTEAMS_CONTAINER" ;;
    daianastudio) printf '%s\n' "$STUDIO_CONTAINER" ;;
    *) return 1 ;;
  esac
}

service_base_image() {
  case "$1" in
    daiananext) printf '%s\n' "$NEXT_BASE_IMAGE" ;;
    daianapython) printf '%s\n' "$PYTHON_BASE_IMAGE" ;;
    daianamsteams) printf '%s\n' "$MSTEAMS_BASE_IMAGE" ;;
    daianastudio) printf '%s\n' "$STUDIO_BASE_IMAGE" ;;
    *) return 1 ;;
  esac
}

service_candidate_image() {
  case "$1" in
    daiananext) printf '%s\n' "${DAIANA_CANDIDATE_NEXT_IMAGE:-}" ;;
    daianapython) printf '%s\n' "${DAIANA_CANDIDATE_PYTHON_IMAGE:-}" ;;
    daianamsteams) printf '%s\n' "${DAIANA_CANDIDATE_MSTEAMS_IMAGE:-}" ;;
    daianastudio) printf '%s\n' "${DAIANA_CANDIDATE_STUDIO_IMAGE:-}" ;;
    *) return 1 ;;
  esac
}

service_repository() {
  case "$1" in
    daiananext) printf '%s\n' "$APPROVED_NEXT_IMAGE_REPOSITORY" ;;
    daianapython) printf '%s\n' "$APPROVED_PYTHON_IMAGE_REPOSITORY" ;;
    daianamsteams) printf '%s\n' "$APPROVED_MSTEAMS_IMAGE_REPOSITORY" ;;
    daianastudio) printf '%s\n' "$APPROVED_STUDIO_IMAGE_REPOSITORY" ;;
    *) return 1 ;;
  esac
}

service_env_contract() {
  case "$1" in
    daiananext) printf '%s\n' "${BASELINE_NEXT_ENV_CONTRACT:-}" ;;
    daianapython) printf '%s\n' "${BASELINE_PYTHON_ENV_CONTRACT:-}" ;;
    daianamsteams) printf '%s\n' "${BASELINE_MSTEAMS_ENV_CONTRACT:-}" ;;
    daianastudio) printf '%s\n' "${BASELINE_STUDIO_ENV_CONTRACT:-}" ;;
    *) return 1 ;;
  esac
}

service_explicit_env_contract() {
  case "$1" in
    daiananext) printf '%s\n' "${BASELINE_NEXT_EXPLICIT_ENV_CONTRACT:-}" ;;
    daianapython) printf '%s\n' "${BASELINE_PYTHON_EXPLICIT_ENV_CONTRACT:-}" ;;
    daianamsteams) printf '%s\n' "${BASELINE_MSTEAMS_EXPLICIT_ENV_CONTRACT:-}" ;;
    daianastudio) printf '%s\n' "${BASELINE_STUDIO_EXPLICIT_ENV_CONTRACT:-}" ;;
    *) return 1 ;;
  esac
}

service_is_development_candidate() {
  [[ "$1" == daiananext || "$1" == daianapython ]]
}

require_installer_compose_identity() {
  if [[ "${DAIANA_COMPOSE_PROJECT_NAME+x}" == x && "${DAIANA_COMPOSE_PROJECT_NAME}" != "$COMPOSE_PROJECT_NAME" ]]; then
    die "DAIANA_COMPOSE_PROJECT_NAME is not overridable; expected exactly $COMPOSE_PROJECT_NAME"
  fi
}

validate_candidate_compose_identity() {
  local rendered="$1"
  EXPECTED_PROJECT="$COMPOSE_PROJECT_NAME" EXPECTED_NETWORK="$NETWORK_NAME" \
    python3 -c 'import json, os, re, sys

try:
    model = json.loads(sys.stdin.read(), object_pairs_hook=lambda pairs: (
        (_ for _ in ()).throw(ValueError("duplicate JSON key"))
        if len({key for key, _ in pairs}) != len(pairs) else dict(pairs)
    ))
except (ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)

if not isinstance(model, dict) or model.get("name") != os.environ["EXPECTED_PROJECT"]:
    raise SystemExit(1)
networks = model.get("networks")
if not isinstance(networks, dict) or set(networks) != {"default"}:
    raise SystemExit(1)
default = networks["default"]
if not isinstance(default, dict) or default.get("name") != os.environ["EXPECTED_NETWORK"] or default.get("external") is not True:
    raise SystemExit(1)
if set(default) - {"name", "external", "ipam"} or ("ipam" in default and default["ipam"] != {}):
    raise SystemExit(1)
services = model.get("services")
if not isinstance(services, dict):
    raise SystemExit(1)
for name in ("daiananext", "daianapython", "daianamsteams", "daianastudio"):
    if name not in services or not isinstance(services[name], dict):
        raise SystemExit(1)
' <<< "$rendered" || die "rendered candidate Compose identity must be project $COMPOSE_PROJECT_NAME, external network $NETWORK_NAME, and include exactly one of each selected mutation service"
}

safe_config_fingerprint() {
  local container="$1" temp_dir env_file records_file labels_file canonical_labels_file metadata_file fingerprint_file status=1
  local xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/private-chat-fingerprint.XXXXXX")" || { (( xtrace_was_enabled )) && set -x; return 1; }
  PRIVATE_CHAT_FINGERPRINT_DIR="$temp_dir"
  env_file="$temp_dir/env"; records_file="$temp_dir/records"; labels_file="$temp_dir/labels"; canonical_labels_file="$temp_dir/canonical-labels"; metadata_file="$temp_dir/metadata"; fingerprint_file="$temp_dir/fingerprint"
  if ! command -v python3 >/dev/null 2>&1 || ! docker container inspect --format '{{json .Config.Env}}' "$container" > "$env_file"; then
    cleanup_fingerprint_temp
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if ! python3 -c 'import json,sys
for entry in json.load(sys.stdin):
    has_equals="=" in entry
    key,value=(entry.split("=",1)+[""])[:2] if has_equals else (entry,"")
    key_bytes=key.encode("utf-8"); value_bytes=value.encode("utf-8")
    print(f"{len(key_bytes)}:{key_bytes.hex()}:{1 if has_equals else 0}:{len(value_bytes)}:{value_bytes.hex()}")' < "$env_file" | LC_ALL=C sort > "$records_file"; then
    cleanup_fingerprint_temp
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if ! docker container inspect --format '{{json .Config.Labels}}' "$container" > "$labels_file" || ! python3 -c 'import json,sys
labels=json.load(sys.stdin)
if not isinstance(labels,dict):
    raise SystemExit(1)
print(json.dumps({key: value for key, value in labels.items() if not key.startswith("com.docker.compose.")}, sort_keys=True, separators=(",", ":")))' < "$labels_file" > "$canonical_labels_file"; then
    cleanup_fingerprint_temp
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if ! {
    printf '%s\0' 'schema=safe-config-fingerprint-v3'
     docker container inspect --format '{{.Config.Image}}|{{.Config.WorkingDir}}|{{json .Config.Cmd}}|{{json .Config.Entrypoint}}|' "$container"
     cat "$canonical_labels_file"
     docker container inspect --format '|{{json .Mounts}}|{{.HostConfig.NetworkMode}}' "$container"
    printf '\0sorted-length-delimited-env-records\0'
    cat "$records_file"
  } > "$metadata_file"; then
    cleanup_fingerprint_temp
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if ! text_sha256 < "$metadata_file" > "$fingerprint_file"; then
    cleanup_fingerprint_temp
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  if ! cat "$fingerprint_file"; then
    cleanup_fingerprint_temp
    (( xtrace_was_enabled )) && set -x
    return 1
  fi
  status=0
  cleanup_fingerprint_temp
  if (( xtrace_was_enabled )); then set -x; fi
  return "$status"
}

env_key_set() {
  local container="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  docker container inspect --format '{{json .Config.Env}}' "$container" |
    python3 -c 'import json,sys
for entry in json.load(sys.stdin): print(entry.split("=",1)[0])' | LC_ALL=C sort
}

env_key_list() { env_key_set "$1" | paste -sd, -; }

env_contract() {
  local container="$1"
  docker container inspect --format '{{json .Config.Env}}' "$container" | python3 -c 'import hashlib,json,sys
seen=set()
for entry in json.load(sys.stdin):
    key,value=(entry.split("=",1)+[""])[:2] if "=" in entry else (entry,"")
    if key in seen: raise SystemExit(1)
    seen.add(key)
    print("{}|{}".format(key,hashlib.sha256(value.encode("utf-8")).hexdigest()))' | LC_ALL=C sort
}

compose_environment_contract() {
  local service="$1"
  compose_base config --format json | SERVICE_NAME="$service" python3 -c 'import hashlib,json,os,sys

def pairs(items):
    keys=[key for key,_ in items]
    if len(keys) != len(set(keys)):
        raise SystemExit(1)
    return dict(items)

try:
    model=json.load(sys.stdin, object_pairs_hook=pairs)
    environment=model["services"][os.environ["SERVICE_NAME"]]["environment"]
    if not isinstance(environment, dict):
        raise SystemExit(1)
    for key,value in sorted(environment.items()):
        if not isinstance(key,str) or not isinstance(value,str):
            raise SystemExit(1)
        print("{}|{}".format(key,hashlib.sha256(value.encode("utf-8")).hexdigest()))
except (KeyError,TypeError,ValueError,json.JSONDecodeError):
    raise SystemExit(1)
' || return 1
}

image_environment_contract() {
  local image="$1"
  docker image inspect --format '{{json .Config.Env}}' "$image" | python3 -c 'import hashlib,json,sys
seen=set()
entries=json.load(sys.stdin)
if entries is None: entries=[]
for entry in entries:
    if not isinstance(entry,str): raise SystemExit(1)
    key,value=(entry.split("=",1)+[""])[:2] if "=" in entry else (entry,"")
    if key in seen: raise SystemExit(1)
    seen.add(key)
    print("{}|{}".format(key,hashlib.sha256(value.encode("utf-8")).hexdigest()))' | LC_ALL=C sort
}

protected_config_keys() {
  local container="$1"
  docker container inspect --format '{{json .Config.Env}}' "$container" | python3 -c 'import json,sys
explicit={"SITE_URL","SUPABASE_URL","SUPABASE_PUBLIC_URL","API_EXTERNAL_URL","WS_BASE_URL","CORS_ALLOW_ORIGIN","BACKEND_BASE_URL","STUDIO_BASE_URL","WEBUI_BASE_URL","LICENSE_ACTIVATION_BASE_URL","QDRANT_BASE_URL","SUPABASE_DB_URL","DATABASE_URL","GOTRUE_DB_DATABASE_URL","NPM_BASE_URL","NPM_URL","NPM_API_URL","UPSTREAM_URL","UPSTREAM_BASE_URL","INTERNAL_API_URL","INTERNAL_DB_URL","POSTGRES_URL"}
for entry in json.load(sys.stdin):
    key=entry.split("=",1)[0]
    upper=key.upper()
    generic=("URL" in upper or "URI" in upper or "PUBLIC" in upper or
             "AUTH" in upper or "REDIRECT" in upper or "CORS" in upper or
             "WS" in upper or "MS" in upper or "BASE_URL" in upper)
    if upper in explicit or upper.startswith("VAULT") or generic:
        print(key)' | LC_ALL=C sort
}

protected_config_fingerprint() {
  local container="$1"
  docker container inspect --format '{{json .Config.Env}}' "$container" | python3 -c 'import hashlib,json,sys
explicit={"SITE_URL","SUPABASE_URL","SUPABASE_PUBLIC_URL","API_EXTERNAL_URL","WS_BASE_URL","CORS_ALLOW_ORIGIN","BACKEND_BASE_URL","STUDIO_BASE_URL","WEBUI_BASE_URL","LICENSE_ACTIVATION_BASE_URL","QDRANT_BASE_URL","SUPABASE_DB_URL","DATABASE_URL","GOTRUE_DB_DATABASE_URL","NPM_BASE_URL","NPM_URL","NPM_API_URL","UPSTREAM_URL","UPSTREAM_BASE_URL","INTERNAL_API_URL","INTERNAL_DB_URL","POSTGRES_URL"}
records=[]
for entry in json.load(sys.stdin):
    key,value=(entry.split("=",1)+[""])[:2] if "=" in entry else (entry,"")
    upper=key.upper()
    generic=("URL" in upper or "URI" in upper or "PUBLIC" in upper or
             "AUTH" in upper or "REDIRECT" in upper or "CORS" in upper or
             "WS" in upper or "MS" in upper or "BASE_URL" in upper)
    if upper in explicit or upper.startswith("VAULT") or generic:
        records.append("{}:{}:{}".format(len(key.encode()),key.encode().hex(),hashlib.sha256(value.encode()).hexdigest()))
print(hashlib.sha256(("\\n".join(sorted(records))+"\\n").encode()).hexdigest())'
}

require_candidate_environment_set() {
  local container="$1" baseline_keys="$2" candidate_keys key
  candidate_keys="$(env_key_set "$container")"
  while IFS= read -r key; do
     [[ -n "$key" ]] || continue
     case ",$baseline_keys," in *",$key,"*) ;; *)
       case "$key" in
         NODE_ENV|PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN) ;;
         PRIVATE_CHAT_PYTHON_ORIGIN) [[ "$container" == "$NEXT_CONTAINER" ]] || return 1 ;;
         *) return 1 ;;
       esac
       ;;
     esac
  done <<< "$candidate_keys"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    printf '%s\n' "$candidate_keys" | grep -Fxq "$key" || return 1
  done <<< "$(printf '%s' "$baseline_keys" | tr ',' '\n')"
}

require_candidate_environment_contract() {
  local container="$1" baseline_contract="$2" candidate_image="$3" candidate_contract image_contract key expected_hash actual_hash service candidate_only
  for service in "${COMPOSE_MUTATION_SERVICES[@]}"; do
    [[ "$(service_container "$service")" == "$container" ]] && break
  done
  candidate_only=""
  if service_is_development_candidate "$service"; then candidate_only='NODE_ENV PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN'; fi
  [[ "$service" == daiananext ]] && candidate_only="$candidate_only PRIVATE_CHAT_PYTHON_ORIGIN"
  candidate_contract="$(env_contract "$container")" || return 1
  image_contract="$(image_environment_contract "$candidate_image")" || return 1
  while IFS='|' read -r key actual_hash; do
    [[ -n "$key" ]] || continue
      if [[ "$key" == NODE_ENV && "$candidate_only" == *NODE_ENV* ]]; then
       [[ "$actual_hash" == "$(printf '%s' development | text_sha256)" ]] || return 1
      elif [[ "$key" == PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN && "$candidate_only" == *PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN* ]]; then
         [[ "$actual_hash" == "$(printf '%s' true | text_sha256)" ]] || return 1
      elif [[ "$key" == PRIVATE_CHAT_PYTHON_ORIGIN && "$candidate_only" == *PRIVATE_CHAT_PYTHON_ORIGIN* ]]; then
        [[ -n "${PRIVATE_CHAT_PYTHON_ORIGIN:-}" && "$actual_hash" == "$(printf '%s' "$PRIVATE_CHAT_PYTHON_ORIGIN" | text_sha256)" ]] || return 1
     else
      expected_hash="$(printf '%s\n' "$baseline_contract" | awk -F '|' -v key="$key" '$1 == key { print $2; exit }')"
      if [[ -n "$expected_hash" ]]; then
        [[ "$actual_hash" == "$expected_hash" ]] || return 1
      else
        expected_hash="$(printf '%s\n' "$image_contract" | awk -F '|' -v key="$key" '$1 == key { print $2; exit }')"
        [[ -n "$expected_hash" && "$actual_hash" == "$expected_hash" ]] || return 1
      fi
    fi
  done <<< "$candidate_contract"
  while IFS='|' read -r key expected_hash; do
    [[ -n "$key" ]] || continue
    printf '%s\n' "$candidate_contract" | awk -F '|' -v key="$key" '$1 == key { found=1 } END { exit found ? 0 : 1 }' || return 1
  done <<< "$baseline_contract"
    for key in $candidate_only; do
      printf '%s\n' "$candidate_contract" | awk -F '|' -v key="$key" '$1 == key { found=1 } END { exit found ? 0 : 1 }' || return 1
    done
}

require_candidate_image() {
  local image="$1" component="$2" architecture expected_repository
  case "$component" in
    Next) expected_repository="$APPROVED_NEXT_IMAGE_REPOSITORY" ;;
    Python) expected_repository="$APPROVED_PYTHON_IMAGE_REPOSITORY" ;;
    Teams) expected_repository="$APPROVED_MSTEAMS_IMAGE_REPOSITORY" ;;
    Studio) expected_repository="$APPROVED_STUDIO_IMAGE_REPOSITORY" ;;
    *) die "unknown candidate component: $component" ;;
  esac
  [[ "${image%%:*}" == "$expected_repository" && "${image#*:}" =~ ^sha-[0-9a-f]{40}$ ]] || die "$component candidate image must use the approved repository and a full-SHA tag"
  docker image inspect "$image" >/dev/null 2>&1 || die "$component candidate image is not present locally: $image"
  architecture="$(docker image inspect --format '{{.Architecture}}' "$image")"
  [[ "$architecture" == arm64 || "$architecture" == aarch64 ]] || die "$component candidate image architecture is $architecture, expected arm64"
}

require_baseline_container() {
  local container="$1" expected="$2" actual status
  docker container inspect "$container" >/dev/null 2>&1 || die "baseline container is missing: $container"
  actual="$(docker container inspect --format '{{.Config.Image}}' "$container")"
  [[ "$actual" == "$expected" ]] || die "baseline container $container is not the known v2.1.9 image"
  status="$(docker container inspect --format '{{.State.Status}}' "$container")"
  [[ "$status" == running ]] || die "baseline container $container is not running"
}

baseline_image_identity() {
  local container="$1" ref image_id repo_digest
  ref="$(docker container inspect --format '{{.Config.Image}}' "$container")"
  image_id="$(docker container inspect --format '{{.Image}}' "$container")"
  repo_digest="$(docker image inspect --format '{{join .RepoDigests ","}}' "$ref" 2>/dev/null || true)"
  repo_digest="${repo_digest%%|*}"
  [[ "$image_id" == sha256:* ]] || return 1
  printf '%s|%s\n' "$image_id" "${repo_digest:-none}"
}

require_baseline_image_identity() {
  local container="$1" expected_id="$2" expected_digest="$3" actual identity
  identity="$(baseline_image_identity "$container")" || die "baseline image identity is unavailable for $container"
  actual="${identity%%|*}"; identity="${identity#*|}"
  [[ "$actual" == "$expected_id" ]] || die "baseline image ID changed for $container"
  [[ "${identity:-none}" == "$expected_digest" ]] || die "baseline image digest changed for $container (expected=$expected_digest observed=${identity:-none})"
}

require_baseline_configuration() {
  local container="$1"
  baseline_node_env_state "$container" >/dev/null || die "baseline container $container has a missing, malformed, conflicting, or non-production NODE_ENV contract"
  require_exact_env_absent "$container" 'PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true' || die "baseline container $container retained insecure local origin configuration"
}

baseline_node_env_state() {
  local container="$1" env entry key value count=0
  env="$(docker container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container")"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    key="${entry%%=*}"
    [[ "$key" == NODE_ENV ]] || continue
    [[ "$entry" == NODE_ENV=* ]] || return 1
    value="${entry#*=}"
    count=$((count + 1))
    [[ "$value" == production ]] || return 1
  done <<< "$env"
  case "$count" in
    0) printf 'implicit-production\n' ;;
    1) printf 'explicit-production\n' ;;
    *) return 1 ;;
  esac
}

require_exact_env_entry() {
  local container="$1" expected="$2" env entry expected_key expected_count=0 key_count=0
  expected_key="${expected%%=*}"
  env="$(docker container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container")"
  while IFS= read -r entry; do
    [[ "$entry" == "$expected" ]] && expected_count=$((expected_count + 1))
    [[ "${entry%%=*}" == "$expected_key" ]] && key_count=$((key_count + 1))
  done <<< "$env"
  [[ "$expected_count" -eq 1 && "$key_count" -eq 1 ]]
}

require_exact_env_absent() {
  local container="$1" expected="$2" expected_key env key_count=0 expected_count=0 entry
  expected_key="${expected%%=*}"
  env="$(docker container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$container")"
  while IFS= read -r entry; do
    if [[ "${entry%%=*}" == "$expected_key" ]]; then
      key_count=$((key_count + 1))
      [[ "$entry" == "$expected" ]] && expected_count=$((expected_count + 1))
    fi
  done <<< "$env"
  # The baseline legitimately keeps NODE_ENV=production.  Any duplicate,
  # development value, or other protected candidate-only value is invalid.
  if [[ "$expected_key" == NODE_ENV ]]; then
    [[ "$key_count" -eq 1 && "$expected_count" -eq 0 && "$env" == *'NODE_ENV=production'* ]]
  else
    [[ "$key_count" -eq 0 ]]
  fi
}

require_candidate_configuration() {
  local container="$1" requested observed service
  for service in "${COMPOSE_MUTATION_SERVICES[@]}"; do
    [[ "$(service_container "$service")" == "$container" ]] && break
  done
  requested="$(service_candidate_image "$service")"
  observed="$(docker container inspect --format '{{.Config.Image}}' "$container")"
  [[ "$observed" == "$requested" ]] || die "candidate image mismatch for $container (requested=$requested observed=$observed)"
  if service_is_development_candidate "$service"; then
    require_exact_env_entry "$container" 'NODE_ENV=development' || die "candidate container $container is not using the exact development-only environment"
    require_exact_env_entry "$container" 'PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true' || die "candidate container $container is missing the exact insecure local origin guard"
  fi
  if [[ "$service" == daiananext ]]; then
    require_exact_env_entry "$container" "PRIVATE_CHAT_PYTHON_ORIGIN=${PRIVATE_CHAT_PYTHON_ORIGIN:?}" || die "candidate container $container is missing the exact private-chat Python origin"
  fi
}

require_paths() {
  local path
  for path in "${COMPOSE_BASE[@]}" "$ROOT_DIR/docker-compose.private-chat-candidate.yml" \
    "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000" \
    "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000" \
    "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000" "$ROOT_DIR/VERSION"; do
    [[ -f "$path" ]] || die "required harness path is missing: $path"
  done
}

validate_candidate_compose_contract() {
  local next_contract="$1" python_contract="$2" msteams_contract="$3" studio_contract="$4" xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac

  [[ "${DAIANA_CANDIDATE_NEXT_IMAGE:-}" =~ ^${APPROVED_NEXT_IMAGE_REPOSITORY}:sha-[0-9a-f]{40}$ ]] || {
    (( xtrace_was_enabled )) && set -x
    die "Next candidate image must use the approved repository and full SHA tag"
  }
  [[ "${DAIANA_CANDIDATE_PYTHON_IMAGE:-}" =~ ^${APPROVED_PYTHON_IMAGE_REPOSITORY}:sha-[0-9a-f]{40}$ ]] || {
    (( xtrace_was_enabled )) && set -x
    die "Python candidate image must use the approved repository and full SHA tag"
  }
  [[ "${DAIANA_CANDIDATE_MSTEAMS_IMAGE:-}" =~ ^${APPROVED_MSTEAMS_IMAGE_REPOSITORY}:sha-[0-9a-f]{40}$ ]] || {
    (( xtrace_was_enabled )) && set -x
    die "Teams candidate image must use the approved repository and full SHA tag"
  }
  [[ "${DAIANA_CANDIDATE_STUDIO_IMAGE:-}" =~ ^${APPROVED_STUDIO_IMAGE_REPOSITORY}:sha-[0-9a-f]{40}$ ]] || {
    (( xtrace_was_enabled )) && set -x
    die "Studio candidate image must use the approved repository and full SHA tag"
  }

  # Validate the overlay independently. The merged model intentionally contains
  # unrelated baseline services and fields, so it cannot establish a closed-
  # world contract for the candidate file.
  if ! compose_candidate_overlay config --format json 2>/dev/null |
    EXPECTED_NEXT_IMAGE="$DAIANA_CANDIDATE_NEXT_IMAGE" \
     EXPECTED_PYTHON_IMAGE="$DAIANA_CANDIDATE_PYTHON_IMAGE" \
     EXPECTED_MSTEAMS_IMAGE="$DAIANA_CANDIDATE_MSTEAMS_IMAGE" \
     EXPECTED_STUDIO_IMAGE="$DAIANA_CANDIDATE_STUDIO_IMAGE" \
     EXPECTED_PRIVATE_CHAT_PYTHON_ORIGIN="${PRIVATE_CHAT_PYTHON_ORIGIN:?}" \
     python3 -c 'import json, os, re, sys

def valid_origin(value):
    from ipaddress import ip_address
    from urllib.parse import urlsplit
    if not value or any(char.isspace() for char in value):
        return False
    try:
        parsed = urlsplit(value)
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
            return False
        host = parsed.hostname
        if not host:
            return False
        parsed.port
        if parsed.scheme == "https":
            return True
        if host.lower() == "localhost":
            return True
        try:
            return ip_address(host).is_loopback
        except ValueError:
            match = re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*(\d{1,3}(?:\.\d{1,3}){3})\.nip\.io", host, re.IGNORECASE)
            if not match:
                return False
            address = ip_address(match.group(1))
            return address.is_private or address.is_loopback
    except ValueError:
        return False

def pairs(items):
    keys = [key for key, _ in items]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate JSON key")
    return dict(items)

try:
    model = json.load(sys.stdin, object_pairs_hook=pairs)
    if not isinstance(model, dict) or set(model) != {"name", "services", "networks"} or model["name"] != "daiana-app":
        raise ValueError("overlay top-level contract mismatch")
    services = model["services"]
    if not isinstance(services, dict) or set(services) != {"daiananext", "daianapython", "daianamsteams", "daianastudio"}:
        raise ValueError("overlay service scope mismatch")
    expected = {
        "daiananext": (os.environ["EXPECTED_NEXT_IMAGE"], "cloudseidoranalytics/daiana"),
        "daianapython": (os.environ["EXPECTED_PYTHON_IMAGE"], "cloudseidoranalytics/daianapython"),
        "daianamsteams": (os.environ["EXPECTED_MSTEAMS_IMAGE"], "cloudseidoranalytics/daianamsteams"),
        "daianastudio": (os.environ["EXPECTED_STUDIO_IMAGE"], "cloudseidoranalytics/daianastudio"),
    }
    for name, (image, repository) in expected.items():
        service = services[name]
        if not isinstance(service, dict):
            raise ValueError("overlay service fields mismatch")
        generated_nulls = {key for key in ("command", "entrypoint") if key in service and service[key] is None}
        if set(service) - {"image", "pull_policy", "environment", "networks", "command", "entrypoint"} or generated_nulls != {"command", "entrypoint"}:
            raise ValueError("overlay service fields mismatch")
        if service["image"] != image or not re.fullmatch(re.escape(repository) + r":sha-[0-9a-f]{40}", service["image"]):
            raise ValueError("overlay image mismatch")
        expected_environment = {"NODE_ENV": "development", "PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN": "true"} if name in ("daiananext", "daianapython") else {}
        if name == "daiananext":
            origin = os.environ["EXPECTED_PRIVATE_CHAT_PYTHON_ORIGIN"]
            if not valid_origin(origin):
                raise ValueError("invalid private-chat Python origin")
            expected_environment["PRIVATE_CHAT_PYTHON_ORIGIN"] = origin
        if service["pull_policy"] != "never" or service.get("environment", {}) != expected_environment:
            raise ValueError("overlay candidate settings mismatch")
        if service["networks"] != {"default": None}:
            raise ValueError("unexpected Compose-generated service network metadata")
    networks = model["networks"]
    if not isinstance(networks, dict) or set(networks) != {"default"}:
        raise ValueError("overlay network scope mismatch")
    network = networks["default"]
    if not isinstance(network, dict) or network.get("name") != "daiana-mgmt" or network.get("external") is not True:
        raise ValueError("overlay network identity mismatch")
    if set(network) - {"name", "external", "ipam"} or ("ipam" in network and network["ipam"] != {}):
        raise ValueError("unexpected normalized network metadata")
except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    print(str(error), file=sys.stderr)
    raise SystemExit(1)
'; then
    cleanup_private_chat_temp
    (( xtrace_was_enabled )) && set -x
    die "candidate Compose overlay must match the closed-world contract"
  fi

  # Compose is the sole YAML parser and its normalized JSON is the canonical
  # model. Pipe it directly to the structural validators: candidate env values
  # never enter a shell variable, temporary file, diagnostic, or xtrace.
  if ! compose_candidate config --format json 2>/dev/null |
    EXPECTED_NEXT_IMAGE="$DAIANA_CANDIDATE_NEXT_IMAGE" \
    EXPECTED_PYTHON_IMAGE="$DAIANA_CANDIDATE_PYTHON_IMAGE" \
    EXPECTED_MSTEAMS_IMAGE="$DAIANA_CANDIDATE_MSTEAMS_IMAGE" \
    EXPECTED_STUDIO_IMAGE="$DAIANA_CANDIDATE_STUDIO_IMAGE" \
    EXPECTED_PRIVATE_CHAT_PYTHON_ORIGIN="${PRIVATE_CHAT_PYTHON_ORIGIN:?}" \
    NEXT_BASELINE_CONTRACT="$next_contract" \
    PYTHON_BASELINE_CONTRACT="$python_contract" \
    MSTEAMS_BASELINE_CONTRACT="$msteams_contract" \
    STUDIO_BASELINE_CONTRACT="$studio_contract" \
    python3 -c 'import hashlib, json, os, re, sys

def valid_origin(value):
    from ipaddress import ip_address
    from urllib.parse import urlsplit
    if not value or any(char.isspace() for char in value):
        return False
    try:
        parsed = urlsplit(value)
        if parsed.scheme not in ("http", "https") or not parsed.netloc or parsed.username or parsed.password or parsed.path or parsed.query or parsed.fragment:
            return False
        host = parsed.hostname
        if not host:
            return False
        parsed.port
        if parsed.scheme == "https":
            return True
        if host.lower() == "localhost":
            return True
        try:
            return ip_address(host).is_loopback
        except ValueError:
            match = re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*(\d{1,3}(?:\.\d{1,3}){3})\.nip\.io", host, re.IGNORECASE)
            if not match:
                return False
            address = ip_address(match.group(1))
            return address.is_private or address.is_loopback
    except ValueError:
        return False

def pairs(pairs):
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate JSON key")
    return dict(pairs)

try:
    model = json.load(sys.stdin, object_pairs_hook=pairs)
    if model.get("name") != "daiana-app":
        raise ValueError("wrong project")
    networks = model.get("networks")
    if not isinstance(networks, dict) or set(networks) != {"default"}:
        raise ValueError("wrong networks")
    network = networks["default"]
    if not isinstance(network, dict) or network.get("name") != "daiana-mgmt" or network.get("external") is not True:
        raise ValueError("wrong default network")
    if set(network) - {"name", "external", "ipam"} or ("ipam" in network and network["ipam"] != {}):
        raise ValueError("unexpected network metadata")
    services = model.get("services")
    if not isinstance(services, dict):
        raise ValueError("services must be a mapping")
    expected = {
        "daiananext": (os.environ["EXPECTED_NEXT_IMAGE"], "cloudseidoranalytics/daiana", os.environ["NEXT_BASELINE_CONTRACT"]),
        "daianapython": (os.environ["EXPECTED_PYTHON_IMAGE"], "cloudseidoranalytics/daianapython", os.environ["PYTHON_BASELINE_CONTRACT"]),
        "daianamsteams": (os.environ["EXPECTED_MSTEAMS_IMAGE"], "cloudseidoranalytics/daianamsteams", os.environ["MSTEAMS_BASELINE_CONTRACT"]),
        "daianastudio": (os.environ["EXPECTED_STUDIO_IMAGE"], "cloudseidoranalytics/daianastudio", os.environ["STUDIO_BASELINE_CONTRACT"]),
    }
    for name, (image, repository, contract) in expected.items():
        service = services.get(name)
        if not isinstance(service, dict) or service.get("image") != image or service.get("pull_policy") != "never":
            raise ValueError("selected service identity mismatch")
        if not re.fullmatch(re.escape(repository) + r":sha-[0-9a-f]{40}", image):
            raise ValueError("unapproved image")
        environment = service.get("environment")
        if not isinstance(environment, dict):
            raise ValueError("environment must be a mapping")
        baseline = {}
        for line in contract.splitlines():
            key, digest = line.split("|", 1)
            if key in baseline or len(digest) != 64:
                raise ValueError("invalid baseline contract")
            baseline[key] = digest
        candidate_only = {"NODE_ENV", "PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN"} if name in ("daiananext", "daianapython") else set()
        if name == "daiananext":
            candidate_only.add("PRIVATE_CHAT_PYTHON_ORIGIN")
        if set(environment) - (set(baseline) | candidate_only):
            raise ValueError("environment scope mismatch")
        for key, value in environment.items():
            if not isinstance(value, str):
                raise ValueError("environment value is not a string")
            if key in candidate_only:
                if key == "NODE_ENV" and value != "development":
                    raise ValueError("NODE_ENV mismatch")
                if key == "PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN" and value != "true":
                    raise ValueError("origin guard mismatch")
                if key == "PRIVATE_CHAT_PYTHON_ORIGIN" and (value != os.environ["EXPECTED_PRIVATE_CHAT_PYTHON_ORIGIN"] or not valid_origin(value)):
                    raise ValueError("private-chat Python origin mismatch")
            elif hashlib.sha256(value.encode()).hexdigest() != baseline[key]:
                raise ValueError("baseline environment mismatch")
        for key in baseline:
            if key not in environment:
                raise ValueError("missing explicit baseline environment key")
        required = {"NODE_ENV": "development", "PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN": "true"} if name in ("daiananext", "daianapython") else {}
        if name == "daiananext":
            required["PRIVATE_CHAT_PYTHON_ORIGIN"] = os.environ["EXPECTED_PRIVATE_CHAT_PYTHON_ORIGIN"]
        if any(environment.get(key) != value for key, value in required.items()):
            raise ValueError("missing candidate environment addition")
except (KeyError, TypeError, ValueError, json.JSONDecodeError):
    raise SystemExit(1)
'; then
    cleanup_private_chat_temp
    (( xtrace_was_enabled )) && set -x
    die "candidate rendered Compose model must match the full Installer identity and selected service contract"
  fi
  if (( xtrace_was_enabled )); then set -x; fi
}

docker_psql() {
  local query="$1" psql_status=0 xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  { printf '%s\n' "$POSTGRES_PASSWORD"; } | docker_cmd exec -i "$DAIANA_DB_CONTAINER" \
    sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql "$@"' sh \
    -X -h 127.0.0.1 -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -Atqc "$query" || psql_status=$?
  if (( xtrace_was_enabled )); then set -x; fi
  return "$psql_status"
}

apply_and_verify_migrations() {
  local migration_dir ledger_checks schema_checks migration_status migration_outcome result_file
  migration_dir="$(mktemp -d "${TMPDIR:-/tmp}/private-chat-migrations.XXXXXX")"
  PRIVATE_CHAT_MIGRATION_DIR="$migration_dir"
  cp "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000" "$migration_dir/"
  cp "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000" "$migration_dir/"
  cp "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000" "$migration_dir/"
  export DAIANA_MIGRATIONS_DIR="$migration_dir"
  result_file="$(mktemp "${TMPDIR:-/tmp}/private-chat-migration-result.XXXXXX")"
  printf 'outcome=unknown\nstatus=125\n' > "$result_file"
  export DAIANA_MIGRATION_RESULT_FILE="$result_file"
  # shellcheck disable=SC1091
  source "$ROOT_DIR/utils/daiana-migrations.sh"
  # Signals are deferred while the runner is in flight. A successful runner
  # return must cross the durable forward-only boundary only after the live
  # ledger/schema evidence has been checked. The intent marker is durable
  # before the runner starts; if the process is killed, it remains pending and
  # blocks retry because the database outcome is unknown.
  write_migration_commitment pending || die "could not durably write the pre-migration intent marker"
  MIGRATION_BOUNDARY_PENDING=1
  MIGRATION_SIGNAL_PENDING=0
  if (cd "$ROOT_DIR" && run_daiana_migrations); then
    migration_status=0
  else
    migration_status=$?
  fi
  migration_outcome="$(awk -F= '$1 == "outcome" { print $2; exit }' "$result_file" 2>/dev/null || printf unknown)"
  migration_outcome="${migration_outcome:-unknown}"
  rm -f "$result_file"
  unset DAIANA_MIGRATION_RESULT_FILE
  if [[ "${DAIANA_HARNESS_TEST_SIGNAL_AFTER_MIGRATION:-}" == yes ]]; then
    kill -TERM "$$"
  fi
  if (( migration_status != 0 )); then
    if [[ "$migration_outcome" == unknown ]]; then
      PRIVATE_CHAT_DIAGNOSTIC_STATE=blocked
      export PRIVATE_CHAT_DIAGNOSTIC_STATE
      write_migration_commitment blocked || true
      MIGRATION_BOUNDARY_PENDING=0
      die "migration execution outcome is unknown after connection or transport loss; manual reconciliation is required and retry is blocked"
    fi
    write_migration_commitment failed || true
    MIGRATION_BOUNDARY_PENDING=0
    return "$migration_status"
  fi
  if (( MIGRATION_SIGNAL_PENDING )); then
    PRIVATE_CHAT_DIAGNOSTIC_STATE=blocked
    export PRIVATE_CHAT_DIAGNOSTIC_STATE
    write_migration_commitment blocked || true
    MIGRATION_BOUNDARY_PENDING=0
    die "migration execution was interrupted; database outcome is unknown and manual recovery is required"
  fi
  MIGRATION_APPLIED=1
  export MIGRATION_APPLIED
  ledger_checks="$(docker_psql "SELECT count(*) = 3 FROM private.daiana_installer_schema_migrations WHERE (version, name, checksum) IN (('20260727130000', 'add_history_message_refs', '$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000")'), ('20260727140000', 'allow_authorized_private_message_quota', '$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000")'), ('20260731120000', 'add_flowise_quota_finalization', '$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000")')); SELECT version || '|' || name || '|' || checksum FROM private.daiana_installer_schema_migrations WHERE version IN ('20260727130000', '20260727140000', '20260731120000') ORDER BY version;")"
  [[ "$(printf '%s\n' "$ledger_checks" | sed -n '1p')" == t ]] || die "Installer migration ledger does not contain all approved feature entries"
  [[ "$(printf '%s\n' "$ledger_checks" | sed -n '2p')" == "20260727130000|add_history_message_refs|$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000")" ]] || die "history-message migration ledger verification failed"
  [[ "$(printf '%s\n' "$ledger_checks" | sed -n '3p')" == "20260727140000|allow_authorized_private_message_quota|$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000")" ]] || die "private-quota migration ledger verification failed"
  [[ "$(printf '%s\n' "$ledger_checks" | sed -n '4p')" == "20260731120000|add_flowise_quota_finalization|$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000")" ]] || die "Flowise quota finalization migration ledger verification failed"
  schema_checks="$(docker_psql "SELECT to_regclass('public.history') IS NOT NULL AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'history' AND column_name = 'message_ref'); SELECT to_regclass('public.figure_artifacts') IS NOT NULL; SELECT to_regprocedure('public.finalize_tenant_message_quota_turn(text,text,jsonb,jsonb,timestamptz)') IS NOT NULL; SELECT to_regprocedure('public.finalize_tenant_message_quota_without_history(text,text,jsonb,timestamptz)') IS NOT NULL;")"
  [[ "$(printf '%s\n' "$schema_checks" | grep -c '^t$')" -eq 4 ]] || die "required private-chat schema objects are missing"
  write_migration_commitment || die "migrations committed but durable commitment evidence could not be written"
  MIGRATION_BOUNDARY_PENDING=0
}

image_identity() {
  local image="$1"
  docker image inspect --format '{{.Id}}|{{join .RepoDigests ","}}|{{.Architecture}}' "$image"
}

image_source_sha() {
  local image="$1" tag
  tag="${image##*:}"
  [[ "$tag" =~ ^sha-[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "${tag#sha-}"
}

require_local_candidate_context() {
  [[ "${DAIANA_HARNESS_MODE:-}" == local-candidate ]] || die "feature-ref exception requires local candidate mode"
  [[ "${DAIANA_HARNESS_NO_PUSH:-}" == 1 ]] || die "feature-ref exception requires no-push invariant"
  [[ "${DAIANA_HARNESS_NO_PUBLICATION:-}" == 1 ]] || die "feature-ref exception requires no-publication invariant"
  [[ "${DAIANA_HARNESS_NO_REGISTRY_PUBLISH:-}" == 1 ]] || die "feature-ref exception requires no-registry-publish invariant"
  [[ "${DAIANA_HARNESS_OPERATION:-}" == candidate ]] || die "feature-ref exception requires candidate operation"
  [[ "${DAIANA_DEPLOYMENT_MODE:-}" == local-candidate ]] || die "feature-ref exception requires local-candidate deployment mode"
  [[ "${DAIANA_HARNESS_PUSH:-0}" == 0 && "${DAIANA_HARNESS_PUBLISH:-0}" == 0 && "${DAIANA_HARNESS_REGISTRY_PUBLISH:-0}" == 0 ]] || die "feature-ref exception cannot be used with push or publication enabled"
}

validate_candidate_source_refs() {
  local next_sha python_sha msteams_sha studio_sha front_repo python_repo msteams_repo studio_repo
  local front_base_ref python_base_ref msteams_base_ref studio_base_ref
  local approved_next_sha approved_python_sha approved_msteams_sha approved_studio_sha
  require_local_candidate_context
  [[ "${DAIANA_CANDIDATE_NEXT_IMAGE:-}" == "$APPROVED_NEXT_IMAGE_REPOSITORY":* ]] || die "Next candidate image must use the approved repository"
  [[ "${DAIANA_CANDIDATE_PYTHON_IMAGE:-}" == "$APPROVED_PYTHON_IMAGE_REPOSITORY":* ]] || die "Python candidate image must use the approved repository"
  [[ "${DAIANA_CANDIDATE_MSTEAMS_IMAGE:-}" == "$APPROVED_MSTEAMS_IMAGE_REPOSITORY":* ]] || die "Teams candidate image must use the approved repository"
  [[ "${DAIANA_CANDIDATE_STUDIO_IMAGE:-}" == "$APPROVED_STUDIO_IMAGE_REPOSITORY":* ]] || die "Studio candidate image must use the approved repository"
  next_sha="$(image_source_sha "${DAIANA_CANDIDATE_NEXT_IMAGE:-}")" || die "Next candidate image must carry a full 40-character source SHA tag"
  python_sha="$(image_source_sha "${DAIANA_CANDIDATE_PYTHON_IMAGE:-}")" || die "Python candidate image must carry a full 40-character source SHA tag"
  msteams_sha="$(image_source_sha "${DAIANA_CANDIDATE_MSTEAMS_IMAGE:-}")" || die "Teams candidate image must carry a full 40-character source SHA tag"
  studio_sha="$(image_source_sha "${DAIANA_CANDIDATE_STUDIO_IMAGE:-}")" || die "Studio candidate image must carry a full 40-character source SHA tag"
  front_repo="${DAIANA_FRONT_REPO:-$ROOT_DIR/../daiananext}"
  python_repo="${DAIANA_PYTHON_REPO:-$ROOT_DIR/../daianapython}"
  msteams_repo="${DAIANA_MSTEAMS_REPO:-$ROOT_DIR/../daianamsteams}"
  studio_repo="${DAIANA_STUDIO_REPO:-$ROOT_DIR/../daianastudio}"
  [[ -z "${DAIANA_FEATURE_BASE_REF:-}" ]] || die "DAIANA_FEATURE_BASE_REF is not a supported override; ancestry is fixed by repository policy"
  front_base_ref='develop'
  python_base_ref='develop'
  msteams_base_ref='develop'
  studio_base_ref='feat/daiana-313'
  [[ -d "$front_repo/.git" || -f "$front_repo/.git" ]] || die "Front source repository is unavailable for ancestry validation"
  [[ -d "$python_repo/.git" || -f "$python_repo/.git" ]] || die "Python source repository is unavailable for ancestry validation"
  [[ -d "$msteams_repo/.git" || -f "$msteams_repo/.git" ]] || die "Teams source repository is unavailable for ancestry validation"
  [[ -d "$studio_repo/.git" || -f "$studio_repo/.git" ]] || die "Studio source repository is unavailable for ancestry validation"
  git -C "$front_repo" cat-file -e "$next_sha^{commit}" 2>/dev/null || die "Next candidate source SHA is not present in the local source repository"
  git -C "$python_repo" cat-file -e "$python_sha^{commit}" 2>/dev/null || die "Python candidate source SHA is not present in the local source repository"
  git -C "$msteams_repo" cat-file -e "$msteams_sha^{commit}" 2>/dev/null || die "Teams candidate source SHA is not present in the local source repository"
  git -C "$studio_repo" cat-file -e "$studio_sha^{commit}" 2>/dev/null || die "Studio candidate source SHA is not present in the local source repository"
  approved_next_sha="${DAIANA_APPROVED_NEXT_SOURCE_SHA:-}"
  approved_python_sha="${DAIANA_APPROVED_PYTHON_SOURCE_SHA:-}"
  approved_msteams_sha="${DAIANA_APPROVED_MSTEAMS_SOURCE_SHA:-}"
  approved_studio_sha="${DAIANA_APPROVED_STUDIO_SOURCE_SHA:-}"
  if [[ "$next_sha" == 892c3e34c07b8d2c6b1c49736a90ba192bb6c3f8 \
     && "$python_sha" == 68565fb1870da340a6f5f3f6bc258f7bf3d70ab8 \
     && "$msteams_sha" == c31a2262eb5720707861ac79a8d4cd55311c730e \
     && "$studio_sha" == ed872073e7f359e7b8c88c6c2a26f55c46582c69 ]]; then
    [[ "${ALLOW_LOCAL_FEATURE_REFS:-}" == 1 ]] || die "approved feature refs require ALLOW_LOCAL_FEATURE_REFS=1"
    [[ "$approved_next_sha" =~ ^[a-f0-9]{40}$ \
      && "$approved_python_sha" =~ ^[a-f0-9]{40}$ \
      && "$approved_msteams_sha" =~ ^[a-f0-9]{40}$ \
      && "$approved_studio_sha" =~ ^[a-f0-9]{40}$ ]] || die "all four services require explicit full-SHA allowlist inputs"
    [[ "$approved_next_sha" == 892c3e34c07b8d2c6b1c49736a90ba192bb6c3f8 \
      && "$approved_python_sha" == 68565fb1870da340a6f5f3f6bc258f7bf3d70ab8 \
      && "$approved_msteams_sha" == c31a2262eb5720707861ac79a8d4cd55311c730e \
      && "$approved_studio_sha" == ed872073e7f359e7b8c88c6c2a26f55c46582c69 ]] || die "caller-supplied source SHA allowlist is not approved"
    [[ "$next_sha" == "$approved_next_sha" \
      && "$python_sha" == "$approved_python_sha" \
      && "$msteams_sha" == "$approved_msteams_sha" \
      && "$studio_sha" == "$approved_studio_sha" ]] || die "candidate source SHA does not match the approved four-service allowlist"
    return 0
  fi
  git -C "$front_repo" rev-parse --verify "$front_base_ref^{commit}" >/dev/null 2>&1 || die "Front repository develop ref is unavailable"
  git -C "$python_repo" rev-parse --verify "$python_base_ref^{commit}" >/dev/null 2>&1 || die "Python repository develop ref is unavailable"
  git -C "$msteams_repo" rev-parse --verify "$msteams_base_ref^{commit}" >/dev/null 2>&1 || die "Teams repository develop ref is unavailable"
  git -C "$studio_repo" rev-parse --verify "$studio_base_ref^{commit}" >/dev/null 2>&1 || die "Studio repository feat/daiana-313 ref is unavailable"
  if git -C "$front_repo" merge-base --is-ancestor "$next_sha" "$front_base_ref" \
     && git -C "$python_repo" merge-base --is-ancestor "$python_sha" "$python_base_ref" \
     && git -C "$msteams_repo" merge-base --is-ancestor "$msteams_sha" "$msteams_base_ref" \
     && git -C "$studio_repo" merge-base --is-ancestor "$studio_sha" "$studio_base_ref"; then
    return 0
  fi
  [[ "${ALLOW_LOCAL_FEATURE_REFS:-}" == 1 ]] || die "candidate source refs must be ancestors of the fixed repository baselines; ALLOW_LOCAL_FEATURE_REFS=1 is required for the approved local exception"
  die "local feature-ref exception accepts only the exact approved four-service candidate"
}

candidate_config_fingerprint() {
  local container="$1"
  if [[ "$container" == "$NEXT_CONTAINER" || "$container" == "$PYTHON_CONTAINER" ]]; then
    {
      safe_config_fingerprint "$container"
      printf '%s\n' 'NODE_ENV=development' 'PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true'
      [[ "$container" == "$NEXT_CONTAINER" ]] && printf 'PRIVATE_CHAT_PYTHON_ORIGIN=%s\n' "${PRIVATE_CHAT_PYTHON_ORIGIN:?}"
    } | text_sha256
  else
    safe_config_fingerprint "$container"
  fi
}

write_migrations_applied_receipt() {
  local receipt="$STATE_DIR/migrations-applied.receipt" tmp
  [[ "${DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_WRITE:-}" == yes ]] && return 1
  tmp="$receipt.tmp.$$"
  {
    printf 'schema=private-chat-harness/migrations-applied-v1\nstate=applied\nforward_only=true\nrollback=manual-recovery-required\n'
    printf 'migration_120000_version=20260731120000\nmigration_120000_name=add_flowise_quota_finalization\nmigration_120000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000")"
    printf 'migration_130000_version=20260727130000\nmigration_130000_name=add_history_message_refs\nmigration_130000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000")"
    printf 'migration_140000_version=20260727140000\nmigration_140000_name=allow_authorized_private_message_quota\nmigration_140000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000")"
    printf 'redaction=credentials, tokens, cookies, passwords, URLs, and database connection strings are never recorded\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  durable_publish "$tmp" "$receipt" migration-receipt || return 1
  if ! verify_receipts_redacted "$STATE_DIR"; then
    return 1
  fi
}

write_migration_commitment() {
  local state="${1:-committed}" receipt="$STATE_DIR/migrations-committed.receipt" tmp
  [[ "$state" == committed && "${DAIANA_HARNESS_TEST_FAIL_MIGRATION_COMMITMENT_WRITE:-}" == yes ]] && return 1
  tmp="$receipt.tmp.$$"
  mkdir -p "$STATE_DIR"
  {
    printf 'schema=private-chat-harness/migration-boundary-v1\nstate=%s\nforward_only=true\nrollback=manual-recovery-required\n' "$state"
    printf 'recovery=forward-only manual reconciliation is required; never claim database rollback\n'
    printf 'retry=blocked until the database outcome and live migration ledger are manually reconciled\n'
    printf 'migration_120000_version=20260731120000\nmigration_120000_name=add_flowise_quota_finalization\nmigration_120000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000")"
    printf 'migration_130000_version=20260727130000\nmigration_130000_name=add_history_message_refs\nmigration_130000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000")"
    printf 'migration_140000_version=20260727140000\nmigration_140000_name=allow_authorized_private_message_quota\nmigration_140000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000")"
    printf 'redaction=credentials, tokens, cookies, passwords, URLs, and database connection strings are never recorded\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  python3 - "$tmp" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  durable_publish "$tmp" "$receipt" migration-commitment || return 1
  if ! verify_receipts_redacted "$STATE_DIR"; then
    return 1
  fi
}

durable_publish() {
  local tmp="$1" destination="$2" kind="${3:-receipt}" fail_rename="${DAIANA_HARNESS_TEST_FAIL_RECEIPT_RENAME:-}" fail_fsync="${DAIANA_HARNESS_TEST_FAIL_RECEIPT_FSYNC:-}"
  case "$kind" in
    migration-receipt) fail_rename="${DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_RENAME:-$fail_rename}"; fail_fsync="${DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_FSYNC:-$fail_fsync}" ;;
    migration-commitment) fail_rename="${DAIANA_HARNESS_TEST_FAIL_MIGRATION_COMMITMENT_RENAME:-$fail_rename}"; fail_fsync="${DAIANA_HARNESS_TEST_FAIL_MIGRATION_COMMITMENT_FSYNC:-$fail_fsync}" ;;
  esac
  mkdir -p "$(dirname "$destination")" || return 1
  if [[ "$fail_rename" == yes ]]; then
    rm -f "$tmp"
    return 1
  fi
  python3 - "$tmp" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
  [[ -n "${DAIANA_HARNESS_TEST_DURABLE_TRACE_FILE:-}" ]] && printf 'fsync-before-rename:%s\n' "$destination" >> "$DAIANA_HARNESS_TEST_DURABLE_TRACE_FILE"
  mv "$tmp" "$destination" || return 1
  if [[ "$fail_fsync" == yes ]]; then
    return 1
  fi
  python3 - "$destination" "$(dirname "$destination")" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
dir_fd = os.open(sys.argv[2], os.O_RDONLY)
try:
    os.fsync(dir_fd)
finally:
    os.close(dir_fd)
PY
  [[ -n "${DAIANA_HARNESS_TEST_DURABLE_TRACE_FILE:-}" ]] && printf 'fsync-file-after-rename:%s\nfsync-directory-after-rename:%s\n' "$destination" "$(dirname "$destination")" >> "$DAIANA_HARNESS_TEST_DURABLE_TRACE_FILE"
  return 0
}

validate_migrations_applied_receipt() {
  local receipt="$1" key line
  [[ -s "$receipt" ]] || die "migration receipt is missing or empty; diagnostics retained: $receipt"
  while IFS= read -r line; do
    case "$line" in
      schema=*|state=*|forward_only=*|rollback=*|migration_120000_version=*|migration_120000_name=*|migration_120000_sha256=*|migration_130000_version=*|migration_130000_name=*|migration_130000_sha256=*|migration_140000_version=*|migration_140000_name=*|migration_140000_sha256=*|redaction=*) ;;
      *) die "migration receipt contains an unknown or malformed field; diagnostics retained: $receipt" ;;
    esac
  done < "$receipt"
  for key in schema state forward_only rollback migration_130000_version migration_130000_name migration_130000_sha256 migration_140000_version migration_140000_name migration_140000_sha256 redaction; do
    receipt_has_exactly_one_key "$key" "$receipt" || die "migration receipt field is missing or duplicated ($key); diagnostics retained: $receipt"
  done
  [[ "$(receipt_value schema "$receipt")" == private-chat-harness/migrations-applied-v1 ]] || die "migration receipt schema is invalid; diagnostics retained: $receipt"
  if [[ -n "$(receipt_value migration_120000_version "$receipt")$(receipt_value migration_120000_name "$receipt")$(receipt_value migration_120000_sha256 "$receipt")" ]]; then
    [[ "$(receipt_value migration_120000_version "$receipt")" == 20260731120000 && "$(receipt_value migration_120000_name "$receipt")" == add_flowise_quota_finalization && "$(receipt_value migration_120000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000")" ]] || die "migration 120000 receipt mismatch; diagnostics retained: $receipt"
  fi
  [[ "$(receipt_value state "$receipt")" == applied && "$(receipt_value forward_only "$receipt")" == true && "$(receipt_value rollback "$receipt")" == manual-recovery-required ]] || die "migration receipt does not declare forward-only manual recovery; diagnostics retained: $receipt"
  [[ "$(receipt_value migration_130000_version "$receipt")" == 20260727130000 && "$(receipt_value migration_130000_name "$receipt")" == add_history_message_refs && "$(receipt_value migration_130000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000")" ]] || die "migration 130000 receipt mismatch; diagnostics retained: $receipt"
  [[ "$(receipt_value migration_140000_version "$receipt")" == 20260727140000 && "$(receipt_value migration_140000_name "$receipt")" == allow_authorized_private_message_quota && "$(receipt_value migration_140000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000")" ]] || die "migration 140000 receipt mismatch; diagnostics retained: $receipt"
}

validate_migration_commitment() {
  local receipt="$1" key line
  [[ -s "$receipt" ]] || die "migration commitment is missing or empty; diagnostics retained: $receipt"
  while IFS= read -r line; do
    case "$line" in
      schema=*|state=*|forward_only=*|rollback=*|recovery=*|retry=*|migration_120000_version=*|migration_120000_name=*|migration_120000_sha256=*|migration_130000_version=*|migration_130000_name=*|migration_130000_sha256=*|migration_140000_version=*|migration_140000_name=*|migration_140000_sha256=*|redaction=*) ;;
      *) die "migration commitment contains an unknown or malformed field; diagnostics retained: $receipt" ;;
    esac
  done < "$receipt"
  for key in schema state forward_only rollback recovery retry migration_130000_version migration_130000_name migration_130000_sha256 migration_140000_version migration_140000_name migration_140000_sha256 redaction; do
    receipt_has_exactly_one_key "$key" "$receipt" || die "migration commitment field is missing or duplicated ($key); diagnostics retained: $receipt"
  done
  [[ "$(receipt_value schema "$receipt")" == private-chat-harness/migration-boundary-v1 && "$(receipt_value state "$receipt")" == committed && "$(receipt_value forward_only "$receipt")" == true && "$(receipt_value rollback "$receipt")" == manual-recovery-required && "$(receipt_value recovery "$receipt")" == 'forward-only manual reconciliation is required; never claim database rollback' && "$(receipt_value retry "$receipt")" == 'blocked until the database outcome and live migration ledger are manually reconciled' ]] || die "migration commitment is not forward-only; diagnostics retained: $receipt"
  [[ -z "$(receipt_value migration_120000_sha256 "$receipt")" || ( "$(receipt_value migration_120000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000")" && "$(receipt_value migration_120000_version "$receipt")" == 20260731120000 ) ]] || die "migration commitment Flowise fingerprint mismatch; diagnostics retained: $receipt"
  [[ "$(receipt_value migration_130000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000")" && "$(receipt_value migration_140000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000")" && "$(receipt_value migration_130000_version "$receipt")" == 20260727130000 && "$(receipt_value migration_140000_version "$receipt")" == 20260727140000 ]] || die "migration commitment fingerprint mismatch; diagnostics retained: $receipt"
}

receipt_value() { awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$2"; }
receipt_has_exactly_one_key() { [[ "$(awk -F= -v key="$1" '$1 == key { count++ } END { print count + 0 }' "$2")" == 1 ]]; }

verify_receipts_redacted() {
  local receipt_dir="${1:-$STATE_DIR}"
  python3 "${DAIANA_HARNESS_REDACTION_SCRIPT:-$ROOT_DIR/utils/private-chat-redaction.py}" --verify-dir "$receipt_dir"
}

redact_reason() {
  python3 "${DAIANA_HARNESS_REDACTION_SCRIPT:-$ROOT_DIR/utils/private-chat-redaction.py}"
}

validate_receipt_integrity() {
  local receipt="$1" expected_phase="$2" key line
  [[ -s "$receipt" ]] || die "required $expected_phase receipt is missing or empty; diagnostics retained: $receipt"
  [[ "$(receipt_value phase "$receipt")" == "$expected_phase" ]] || die "receipt phase is invalid; diagnostics retained: $receipt"
  while IFS= read -r line; do
    case "$line" in
      schema=*|phase=*|compose_project=*|network=*|mutation_services=*|host_architecture=*|baseline_next_*|baseline_python_*|baseline_msteams_*|baseline_studio_*|candidate_next_*|candidate_python_*|candidate_msteams_*|candidate_studio_*|migration_120000_sha256=*|migration_130000_sha256=*|migration_140000_sha256=*|next_container_id=*|python_container_id=*|msteams_container_id=*|studio_container_id=*|next_safe_config_sha256=*|python_safe_config_sha256=*|msteams_safe_config_sha256=*|studio_safe_config_sha256=*|next_candidate_config_sha256=*|python_candidate_config_sha256=*|msteams_candidate_config_sha256=*|studio_candidate_config_sha256=*|candidate_architecture=*|redaction=*) ;;
      *) die "receipt contains an unknown or malformed field; diagnostics retained: $receipt" ;;
    esac
  done < "$receipt"
  for key in schema phase compose_project network mutation_services host_architecture baseline_next_image baseline_python_image baseline_msteams_image baseline_studio_image baseline_next_image_id baseline_python_image_id baseline_msteams_image_id baseline_studio_image_id baseline_next_repo_digest baseline_python_repo_digest baseline_msteams_repo_digest baseline_studio_repo_digest baseline_next_env_keys baseline_python_env_keys baseline_msteams_env_keys baseline_studio_env_keys baseline_next_node_env_state baseline_python_node_env_state baseline_msteams_node_env_state baseline_studio_node_env_state baseline_next_protected_config_keys baseline_python_protected_config_keys baseline_msteams_protected_config_keys baseline_studio_protected_config_keys baseline_next_protected_config_sha256 baseline_python_protected_config_sha256 baseline_msteams_protected_config_sha256 baseline_studio_protected_config_sha256 candidate_next_image candidate_python_image candidate_msteams_image candidate_studio_image migration_130000_sha256 migration_140000_sha256 next_container_id python_container_id msteams_container_id studio_container_id next_safe_config_sha256 python_safe_config_sha256 msteams_safe_config_sha256 studio_safe_config_sha256 candidate_next_image_id candidate_python_image_id candidate_msteams_image_id candidate_studio_image_id candidate_next_repo_digest candidate_python_repo_digest candidate_msteams_repo_digest candidate_studio_repo_digest candidate_next_source_sha candidate_python_source_sha candidate_msteams_source_sha candidate_studio_source_sha candidate_architecture next_candidate_config_sha256 python_candidate_config_sha256 msteams_candidate_config_sha256 studio_candidate_config_sha256 redaction; do
    receipt_has_exactly_one_key "$key" "$receipt" || die "receipt field is missing or duplicated ($key); diagnostics retained: $receipt"
  done
  [[ "$(receipt_value schema "$receipt")" == private-chat-harness/v1 ]] || die "receipt schema is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value compose_project "$receipt")" == "$COMPOSE_PROJECT_NAME" && "$(receipt_value mutation_services "$receipt")" == daianapython,daiananext,daianamsteams,daianastudio ]] || die "receipt Compose identity or mutation scope is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value network "$receipt")" == "$NETWORK_NAME" && "$(receipt_value host_architecture "$receipt")" == "$(uname -m)" ]] || die "receipt host/network is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_next_node_env_state "$receipt")" == implicit-production || "$(receipt_value baseline_next_node_env_state "$receipt")" == explicit-production ]] || die "receipt Next baseline NODE_ENV state is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_python_node_env_state "$receipt")" == implicit-production || "$(receipt_value baseline_python_node_env_state "$receipt")" == explicit-production ]] || die "receipt Python baseline NODE_ENV state is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_msteams_node_env_state "$receipt")" == implicit-production || "$(receipt_value baseline_msteams_node_env_state "$receipt")" == explicit-production ]] || die "receipt Teams baseline NODE_ENV state is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_studio_node_env_state "$receipt")" == implicit-production || "$(receipt_value baseline_studio_node_env_state "$receipt")" == explicit-production ]] || die "receipt Studio baseline NODE_ENV state is invalid; diagnostics retained: $receipt"
  [[ -n "$(receipt_value baseline_next_explicit_env_keys "$receipt")" && -n "$(receipt_value baseline_python_explicit_env_keys "$receipt")" ]] || die "receipt explicit Compose environment keys are missing; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_next_explicit_env_contract "$receipt")" == *'|'* && "$(receipt_value baseline_python_explicit_env_contract "$receipt")" == *'|'* ]] || die "receipt explicit Compose environment contracts are invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_next_image "$receipt")" == "$NEXT_BASE_IMAGE" && "$(receipt_value baseline_python_image "$receipt")" == "$PYTHON_BASE_IMAGE" && "$(receipt_value baseline_msteams_image "$receipt")" == "$MSTEAMS_BASE_IMAGE" && "$(receipt_value baseline_studio_image "$receipt")" == "$STUDIO_BASE_IMAGE" ]] || die "receipt baseline image is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_next_image_id "$receipt")" == sha256:* && "$(receipt_value baseline_python_image_id "$receipt")" == sha256:* && "$(receipt_value baseline_msteams_image_id "$receipt")" == sha256:* && "$(receipt_value baseline_studio_image_id "$receipt")" == sha256:* ]] || die "receipt baseline image ID is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_next_repo_digest "$receipt")" == none || "$(receipt_value baseline_next_repo_digest "$receipt")" == *sha256:* ]] || die "receipt baseline image digest is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_python_repo_digest "$receipt")" == none || "$(receipt_value baseline_python_repo_digest "$receipt")" == *sha256:* ]] || die "receipt baseline image digest is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_msteams_repo_digest "$receipt")" == none || "$(receipt_value baseline_msteams_repo_digest "$receipt")" == *sha256:* ]] || die "receipt baseline image digest is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_studio_repo_digest "$receipt")" == none || "$(receipt_value baseline_studio_repo_digest "$receipt")" == *sha256:* ]] || die "receipt baseline image digest is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value candidate_next_image "$receipt")" == "$DAIANA_CANDIDATE_NEXT_IMAGE" && "$(receipt_value candidate_python_image "$receipt")" == "$DAIANA_CANDIDATE_PYTHON_IMAGE" && "$(receipt_value candidate_msteams_image "$receipt")" == "$DAIANA_CANDIDATE_MSTEAMS_IMAGE" && "$(receipt_value candidate_studio_image "$receipt")" == "$DAIANA_CANDIDATE_STUDIO_IMAGE" ]] || die "receipt candidate image does not match requested candidate; diagnostics retained: $receipt"
  [[ -z "$(receipt_value migration_120000_sha256 "$receipt")" || "$(receipt_value migration_120000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000")" ]] || die "receipt Flowise migration fingerprint mismatch; diagnostics retained: $receipt"
  [[ "$(receipt_value migration_130000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000")" && "$(receipt_value migration_140000_sha256 "$receipt")" == "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000")" ]] || die "receipt migration fingerprint mismatch; diagnostics retained: $receipt"
  [[ "$(receipt_value next_safe_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value python_safe_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value msteams_safe_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value studio_safe_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ ]] || die "receipt configuration fingerprint is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value baseline_next_protected_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value baseline_python_protected_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value baseline_msteams_protected_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value baseline_studio_protected_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ ]] || die "public/internal URL and Vault configuration fingerprint is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value candidate_architecture "$receipt")" == arm64 || "$(receipt_value candidate_architecture "$receipt")" == aarch64 ]] || die "receipt candidate architecture is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value candidate_next_image_id "$receipt")" == sha256:* && "$(receipt_value candidate_python_image_id "$receipt")" == sha256:* && "$(receipt_value candidate_msteams_image_id "$receipt")" == sha256:* && "$(receipt_value candidate_studio_image_id "$receipt")" == sha256:* ]] || die "receipt candidate image ID is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value candidate_next_source_sha "$receipt")" =~ ^[a-f0-9]{40}$ && "$(receipt_value candidate_python_source_sha "$receipt")" =~ ^[a-f0-9]{40}$ && "$(receipt_value candidate_msteams_source_sha "$receipt")" =~ ^[a-f0-9]{40}$ && "$(receipt_value candidate_studio_source_sha "$receipt")" =~ ^[a-f0-9]{40}$ ]] || die "receipt candidate source SHA is invalid; diagnostics retained: $receipt"
  [[ "$(receipt_value next_candidate_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value python_candidate_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value msteams_candidate_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ && "$(receipt_value studio_candidate_config_sha256 "$receipt")" =~ ^[a-f0-9]{64}$ ]] || die "receipt candidate configuration fingerprint is invalid; diagnostics retained: $receipt"
}

write_receipt() {
  local phase="$1" receipt_dir="${2:-$STATE_DIR}" receipt tmp next_identity python_identity msteams_identity studio_identity next_id python_id msteams_id studio_id next_digest python_digest msteams_digest studio_digest architecture baseline_next_identity baseline_python_identity baseline_msteams_identity baseline_studio_identity baseline_next_id baseline_python_id baseline_msteams_id baseline_studio_id baseline_next_digest baseline_python_digest baseline_msteams_digest baseline_studio_digest baseline_next_node_env_state baseline_python_node_env_state baseline_msteams_node_env_state baseline_studio_node_env_state
  if [[ "$phase" == active && "${DAIANA_HARNESS_TEST_FAIL_RECEIPT_WRITE:-}" == yes ]]; then
    return 1
  fi
  mkdir -p "$receipt_dir"
  receipt="$receipt_dir/$phase.receipt"
  tmp="$receipt.tmp.$$"
  next_identity="$(image_identity "$DAIANA_CANDIDATE_NEXT_IMAGE")" || return 1
  python_identity="$(image_identity "$DAIANA_CANDIDATE_PYTHON_IMAGE")" || return 1
  msteams_identity="$(image_identity "$DAIANA_CANDIDATE_MSTEAMS_IMAGE")" || return 1
  studio_identity="$(image_identity "$DAIANA_CANDIDATE_STUDIO_IMAGE")" || return 1
  next_id="${next_identity%%|*}"; next_identity="${next_identity#*|}"
  next_digest="${next_identity%%|*}"; architecture="${next_identity#*|}"
  python_id="${python_identity%%|*}"; python_identity="${python_identity#*|}"
  python_digest="${python_identity%%|*}"
  msteams_id="${msteams_identity%%|*}"; msteams_identity="${msteams_identity#*|}"
  msteams_digest="${msteams_identity%%|*}"
  studio_id="${studio_identity%%|*}"; studio_identity="${studio_identity#*|}"
  studio_digest="${studio_identity%%|*}"
  if [[ "$phase" == baseline ]]; then
    baseline_next_identity="$(baseline_image_identity "$NEXT_CONTAINER")" || return 1
    baseline_python_identity="$(baseline_image_identity "$PYTHON_CONTAINER")" || return 1
    baseline_msteams_identity="$(baseline_image_identity "$MSTEAMS_CONTAINER")" || return 1
    baseline_studio_identity="$(baseline_image_identity "$STUDIO_CONTAINER")" || return 1
    baseline_next_id="${baseline_next_identity%%|*}"; baseline_next_identity="${baseline_next_identity#*|}"
    baseline_next_digest="${baseline_next_identity%%|*}"
    baseline_python_id="${baseline_python_identity%%|*}"; baseline_python_identity="${baseline_python_identity#*|}"
    baseline_python_digest="${baseline_python_identity%%|*}"
    baseline_msteams_id="${baseline_msteams_identity%%|*}"; baseline_msteams_identity="${baseline_msteams_identity#*|}"
    baseline_msteams_digest="${baseline_msteams_identity%%|*}"
    baseline_studio_id="${baseline_studio_identity%%|*}"; baseline_studio_identity="${baseline_studio_identity#*|}"
    baseline_studio_digest="${baseline_studio_identity%%|*}"
    baseline_next_node_env_state="$(baseline_node_env_state "$NEXT_CONTAINER")" || return 1
    baseline_python_node_env_state="$(baseline_node_env_state "$PYTHON_CONTAINER")" || return 1
    baseline_msteams_node_env_state="$(baseline_node_env_state "$MSTEAMS_CONTAINER")" || return 1
    baseline_studio_node_env_state="$(baseline_node_env_state "$STUDIO_CONTAINER")" || return 1
  else
    baseline_next_id="${BASELINE_NEXT_IMAGE_ID:?missing baseline image ID}"
    baseline_python_id="${BASELINE_PYTHON_IMAGE_ID:?missing baseline image ID}"
    baseline_next_digest="${BASELINE_NEXT_REPO_DIGEST:-none}"
    baseline_python_digest="${BASELINE_PYTHON_REPO_DIGEST:-none}"
    baseline_next_node_env_state="${BASELINE_NEXT_NODE_ENV_STATE:?missing baseline NODE_ENV state}"
    baseline_python_node_env_state="${BASELINE_PYTHON_NODE_ENV_STATE:?missing baseline NODE_ENV state}"
    baseline_msteams_id="${BASELINE_MSTEAMS_IMAGE_ID:?missing baseline image ID}"
    baseline_studio_id="${BASELINE_STUDIO_IMAGE_ID:?missing baseline image ID}"
    baseline_msteams_digest="${BASELINE_MSTEAMS_REPO_DIGEST:-none}"
    baseline_studio_digest="${BASELINE_STUDIO_REPO_DIGEST:-none}"
    baseline_msteams_node_env_state="${BASELINE_MSTEAMS_NODE_ENV_STATE:?missing baseline NODE_ENV state}"
    baseline_studio_node_env_state="${BASELINE_STUDIO_NODE_ENV_STATE:?missing baseline NODE_ENV state}"
  fi
  [[ "$architecture" == arm64 || "$architecture" == aarch64 ]] || return 1
  {
    printf 'schema=private-chat-harness/v1\nphase=%s\ncompose_project=%s\nnetwork=%s\nmutation_services=daianapython,daiananext,daianamsteams,daianastudio\nhost_architecture=%s\n' "$phase" "$COMPOSE_PROJECT_NAME" "$NETWORK_NAME" "$(uname -m)"
    printf 'baseline_next_image=%s\nbaseline_python_image=%s\nbaseline_msteams_image=%s\nbaseline_studio_image=%s\n' "$NEXT_BASE_IMAGE" "$PYTHON_BASE_IMAGE" "$MSTEAMS_BASE_IMAGE" "$STUDIO_BASE_IMAGE"
    printf 'baseline_next_image_id=%s\nbaseline_python_image_id=%s\nbaseline_msteams_image_id=%s\nbaseline_studio_image_id=%s\n' "$baseline_next_id" "$baseline_python_id" "$baseline_msteams_id" "$baseline_studio_id"
    printf 'baseline_next_repo_digest=%s\nbaseline_python_repo_digest=%s\nbaseline_msteams_repo_digest=%s\nbaseline_studio_repo_digest=%s\n' "${baseline_next_digest:-none}" "${baseline_python_digest:-none}" "${baseline_msteams_digest:-none}" "${baseline_studio_digest:-none}"
      printf 'baseline_next_env_keys=%s\nbaseline_python_env_keys=%s\nbaseline_msteams_env_keys=%s\nbaseline_studio_env_keys=%s\n' \
        "${BASELINE_NEXT_ENV_KEYS:-$(env_key_list "$NEXT_CONTAINER")}" \
        "${BASELINE_PYTHON_ENV_KEYS:-$(env_key_list "$PYTHON_CONTAINER")}" \
        "${BASELINE_MSTEAMS_ENV_KEYS:-$(env_key_list "$MSTEAMS_CONTAINER")}" \
        "${BASELINE_STUDIO_ENV_KEYS:-$(env_key_list "$STUDIO_CONTAINER")}" || return 1
     printf 'baseline_next_explicit_env_keys=%s\nbaseline_python_explicit_env_keys=%s\n' "$(printf '%s\n' "${BASELINE_NEXT_EXPLICIT_ENV_CONTRACT:?missing explicit Next environment contract}" | cut -d'|' -f1 | paste -sd, -)" "$(printf '%s\n' "${BASELINE_PYTHON_EXPLICIT_ENV_CONTRACT:?missing explicit Python environment contract}" | cut -d'|' -f1 | paste -sd, -)"
     printf 'baseline_next_explicit_env_contract=%s\nbaseline_python_explicit_env_contract=%s\n' "$(printf '%s\n' "$BASELINE_NEXT_EXPLICIT_ENV_CONTRACT" | paste -sd, -)" "$(printf '%s\n' "$BASELINE_PYTHON_EXPLICIT_ENV_CONTRACT" | paste -sd, -)"
     printf 'baseline_next_node_env_state=%s\nbaseline_python_node_env_state=%s\nbaseline_msteams_node_env_state=%s\nbaseline_studio_node_env_state=%s\n' "$baseline_next_node_env_state" "$baseline_python_node_env_state" "$baseline_msteams_node_env_state" "$baseline_studio_node_env_state"
     printf 'candidate_next_image=%s\ncandidate_python_image=%s\ncandidate_msteams_image=%s\ncandidate_studio_image=%s\n' "${DAIANA_CANDIDATE_NEXT_IMAGE:?missing}" "${DAIANA_CANDIDATE_PYTHON_IMAGE:?missing}" "${DAIANA_CANDIDATE_MSTEAMS_IMAGE:?missing}" "${DAIANA_CANDIDATE_STUDIO_IMAGE:?missing}"
     printf 'migration_120000_sha256=%s\nmigration_130000_sha256=%s\nmigration_140000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000")" "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000")" "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000")"
     printf 'next_container_id=%s\npython_container_id=%s\nmsteams_container_id=%s\nstudio_container_id=%s\n' "$(docker container inspect --format '{{.Id}}' "$NEXT_CONTAINER")" "$(docker container inspect --format '{{.Id}}' "$PYTHON_CONTAINER")" "$(docker container inspect --format '{{.Id}}' "$MSTEAMS_CONTAINER")" "$(docker container inspect --format '{{.Id}}' "$STUDIO_CONTAINER")"
     printf 'next_safe_config_sha256=%s\npython_safe_config_sha256=%s\nmsteams_safe_config_sha256=%s\nstudio_safe_config_sha256=%s\n' "$(safe_config_fingerprint "$NEXT_CONTAINER")" "$(safe_config_fingerprint "$PYTHON_CONTAINER")" "$(safe_config_fingerprint "$MSTEAMS_CONTAINER")" "$(safe_config_fingerprint "$STUDIO_CONTAINER")"
     printf 'candidate_next_image_id=%s\ncandidate_python_image_id=%s\ncandidate_msteams_image_id=%s\ncandidate_studio_image_id=%s\n' "$next_id" "$python_id" "$msteams_id" "$studio_id"
     printf 'candidate_next_repo_digest=%s\ncandidate_python_repo_digest=%s\ncandidate_msteams_repo_digest=%s\ncandidate_studio_repo_digest=%s\n' "${next_digest:-none}" "${python_digest:-none}" "${msteams_digest:-none}" "${studio_digest:-none}"
     printf 'candidate_next_source_sha=%s\ncandidate_python_source_sha=%s\ncandidate_msteams_source_sha=%s\ncandidate_studio_source_sha=%s\n' "$(image_source_sha "$DAIANA_CANDIDATE_NEXT_IMAGE")" "$(image_source_sha "$DAIANA_CANDIDATE_PYTHON_IMAGE")" "$(image_source_sha "$DAIANA_CANDIDATE_MSTEAMS_IMAGE")" "$(image_source_sha "$DAIANA_CANDIDATE_STUDIO_IMAGE")"
    printf 'candidate_architecture=%s\n' "$architecture"
     printf 'next_candidate_config_sha256=%s\npython_candidate_config_sha256=%s\nmsteams_candidate_config_sha256=%s\nstudio_candidate_config_sha256=%s\n' "$(candidate_config_fingerprint "$NEXT_CONTAINER")" "$(candidate_config_fingerprint "$PYTHON_CONTAINER")" "$(candidate_config_fingerprint "$MSTEAMS_CONTAINER")" "$(candidate_config_fingerprint "$STUDIO_CONTAINER")"
     printf 'baseline_next_protected_config_keys=%s\nbaseline_python_protected_config_keys=%s\nbaseline_msteams_protected_config_keys=%s\nbaseline_studio_protected_config_keys=%s\n' "${BASELINE_NEXT_PROTECTED_CONFIG_KEYS:-$(protected_config_keys "$NEXT_CONTAINER" | paste -sd, -)}" "${BASELINE_PYTHON_PROTECTED_CONFIG_KEYS:-$(protected_config_keys "$PYTHON_CONTAINER" | paste -sd, -)}" "${BASELINE_MSTEAMS_PROTECTED_CONFIG_KEYS:-$(protected_config_keys "$MSTEAMS_CONTAINER" | paste -sd, -)}" "${BASELINE_STUDIO_PROTECTED_CONFIG_KEYS:-$(protected_config_keys "$STUDIO_CONTAINER" | paste -sd, -)}"
     printf 'baseline_next_protected_config_sha256=%s\nbaseline_python_protected_config_sha256=%s\nbaseline_msteams_protected_config_sha256=%s\nbaseline_studio_protected_config_sha256=%s\n' \
       "${BASELINE_NEXT_PROTECTED_CONFIG_SHA256:-$(protected_config_fingerprint "$NEXT_CONTAINER")}" \
       "${BASELINE_PYTHON_PROTECTED_CONFIG_SHA256:-$(protected_config_fingerprint "$PYTHON_CONTAINER")}" \
       "${BASELINE_MSTEAMS_PROTECTED_CONFIG_SHA256:-$(protected_config_fingerprint "$MSTEAMS_CONTAINER")}" \
       "${BASELINE_STUDIO_PROTECTED_CONFIG_SHA256:-$(protected_config_fingerprint "$STUDIO_CONTAINER")}" || return 1
    printf 'redaction=environment values, credentials, tokens, cookies, passwords, URLs, and database connection strings are never recorded\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  durable_publish "$tmp" "$receipt" receipt
}

write_failure_diagnostics() {
  local reason="$1" file tmp terminal_state="${PRIVATE_CHAT_DIAGNOSTIC_STATE:-failed}"
  mkdir -p "$STATE_DIR"
  file="$STATE_DIR/failure-diagnostics.txt"
  tmp="$file.tmp.$$"
  {
    printf 'schema=private-chat-harness/failure-v1\nstate=%s\nreason=%s\n' "$terminal_state" "$reason"
    printf 'candidate_runtime_mutation_started=%s\ncompensation_attempted=%s\n' "$RUNTIME_MUTATION_STARTED" "${COMPENSATING:-0}"
    printf 'baseline_next_image=%s\nbaseline_python_image=%s\n' "$NEXT_BASE_IMAGE" "$PYTHON_BASE_IMAGE"
    printf 'baseline_next_fingerprint=%s\nbaseline_python_fingerprint=%s\n' "${BASELINE_NEXT_FINGERPRINT:-unknown}" "${BASELINE_PYTHON_FINGERPRINT:-unknown}"
     printf 'migration_120000_version=20260731120000\nmigration_120000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_120000" 2>/dev/null || printf unknown)"
     printf 'migration_130000_version=20260727130000\nmigration_130000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_130000" 2>/dev/null || printf unknown)"
    printf 'migration_140000_version=20260727140000\nmigration_140000_sha256=%s\n' "$(sha256 "$ROOT_DIR/volumes/db/daiana-migrations/$MIGRATION_140000" 2>/dev/null || printf unknown)"
    printf 'diagnostics=redacted; no environment values, credentials, tokens, cookies, passwords, URLs, or database connection strings\n'
  } | redact_reason > "$tmp" || {
    # Never publish unredacted failure input.  The fallback is deliberately
    # constant so a broken redactor cannot discard the recovery evidence.
    printf 'schema=private-chat-harness/failure-v1\nstate=%s\nreason=redaction-failure; manual cleanup is required\ncandidate_runtime_mutation_started=%s\ncompensation_attempted=%s\ndiagnostics=redaction failed closed; inspect retained receipts manually\n' \
      "$terminal_state" "$RUNTIME_MUTATION_STARTED" "${COMPENSATING:-0}" > "$tmp"
  }
  chmod 600 "$tmp"
  durable_publish "$tmp" "$file" diagnostics || return 1
  if ! verify_receipts_redacted "$STATE_DIR"; then
    return 1
  fi
}

mark_manual_cleanup() {
  local reason="${1:-baseline restoration could not be verified}" marker="$STATE_DIR/manual-cleanup-required" tmp
  mkdir -p "$STATE_DIR"
  tmp="$marker.tmp.$$"
  printf 'schema=private-chat-harness/manual-cleanup-v1\nstate=blocked\nreason=%s\nretry=blocked\nnext_action=manual recovery only: restore both app containers from baseline Compose, verify receipts and fingerprints, then remove this marker\n' "$reason" | redact_reason > "$tmp" || {
    # Keep a safe retry-blocking marker even when the redaction verifier itself
    # is unavailable or fails closed.
    printf 'schema=private-chat-harness/manual-cleanup-v1\nstate=blocked\nreason=redaction-failure; manual cleanup is required\nretry=blocked\nnext_action=manual recovery only: inspect retained receipts and restore baseline manually\n' > "$tmp"
  }
  chmod 600 "$tmp"
  durable_publish "$tmp" "$marker" manual-marker || return 1
  if ! verify_receipts_redacted "$STATE_DIR"; then
    return 1
  fi
}

cleanup_failure() {
  local reason="${1:-cleanup validation failed; manual cleanup is required}"
  set +e
  PRIVATE_CHAT_DIAGNOSTIC_STATE=blocked
  export PRIVATE_CHAT_DIAGNOSTIC_STATE
  write_failure_diagnostics "$reason" >/dev/null 2>&1
  mark_manual_cleanup "$reason" >/dev/null 2>&1
  set -e
  printf 'ERROR: %s\n' "$reason" >&2
  return 1
}

verify_baseline_restored() {
  local actual_next actual_python actual_msteams actual_studio
  require_baseline_container "$NEXT_CONTAINER" "$NEXT_BASE_IMAGE"
  require_baseline_container "$PYTHON_CONTAINER" "$PYTHON_BASE_IMAGE"
  require_baseline_container "$MSTEAMS_CONTAINER" "$MSTEAMS_BASE_IMAGE"
  require_baseline_container "$STUDIO_CONTAINER" "$STUDIO_BASE_IMAGE"
  require_baseline_configuration "$NEXT_CONTAINER"
  require_baseline_configuration "$PYTHON_CONTAINER"
  require_baseline_configuration "$MSTEAMS_CONTAINER"
  require_baseline_configuration "$STUDIO_CONTAINER"
  require_baseline_image_identity "$NEXT_CONTAINER" "${BASELINE_NEXT_IMAGE_ID:-}" "${BASELINE_NEXT_REPO_DIGEST:-none}"
  require_baseline_image_identity "$PYTHON_CONTAINER" "${BASELINE_PYTHON_IMAGE_ID:-}" "${BASELINE_PYTHON_REPO_DIGEST:-none}"
  require_baseline_image_identity "$MSTEAMS_CONTAINER" "${BASELINE_MSTEAMS_IMAGE_ID:-}" "${BASELINE_MSTEAMS_REPO_DIGEST:-none}"
  require_baseline_image_identity "$STUDIO_CONTAINER" "${BASELINE_STUDIO_IMAGE_ID:-}" "${BASELINE_STUDIO_REPO_DIGEST:-none}"
  [[ "$(env_key_list "$NEXT_CONTAINER")" == "${BASELINE_NEXT_ENV_KEYS:-}" && "$(env_key_list "$PYTHON_CONTAINER")" == "${BASELINE_PYTHON_ENV_KEYS:-}" && "$(env_key_list "$MSTEAMS_CONTAINER")" == "${BASELINE_MSTEAMS_ENV_KEYS:-}" && "$(env_key_list "$STUDIO_CONTAINER")" == "${BASELINE_STUDIO_ENV_KEYS:-}" ]] || return 1
  actual_next="$(safe_config_fingerprint "$NEXT_CONTAINER")"
  actual_python="$(safe_config_fingerprint "$PYTHON_CONTAINER")"
  actual_msteams="$(safe_config_fingerprint "$MSTEAMS_CONTAINER")"
  actual_studio="$(safe_config_fingerprint "$STUDIO_CONTAINER")"
  [[ -n "${BASELINE_NEXT_FINGERPRINT:-}" && "$actual_next" == "$BASELINE_NEXT_FINGERPRINT" ]] || return 1
  [[ -n "${BASELINE_PYTHON_FINGERPRINT:-}" && "$actual_python" == "$BASELINE_PYTHON_FINGERPRINT" ]] || return 1
  [[ -n "${BASELINE_MSTEAMS_FINGERPRINT:-}" && "$actual_msteams" == "$BASELINE_MSTEAMS_FINGERPRINT" ]] || return 1
  [[ -n "${BASELINE_STUDIO_FINGERPRINT:-}" && "$actual_studio" == "$BASELINE_STUDIO_FINGERPRINT" ]] || return 1
  [[ "$(protected_config_keys "$NEXT_CONTAINER" | paste -sd, -)" == "${BASELINE_NEXT_PROTECTED_CONFIG_KEYS:-}" && "$(protected_config_keys "$PYTHON_CONTAINER" | paste -sd, -)" == "${BASELINE_PYTHON_PROTECTED_CONFIG_KEYS:-}" && "$(protected_config_keys "$MSTEAMS_CONTAINER" | paste -sd, -)" == "${BASELINE_MSTEAMS_PROTECTED_CONFIG_KEYS:-}" && "$(protected_config_keys "$STUDIO_CONTAINER" | paste -sd, -)" == "${BASELINE_STUDIO_PROTECTED_CONFIG_KEYS:-}" ]] || return 1
  [[ "$(protected_config_fingerprint "$NEXT_CONTAINER")" == "${BASELINE_NEXT_PROTECTED_CONFIG_SHA256:-}" && "$(protected_config_fingerprint "$PYTHON_CONTAINER")" == "${BASELINE_PYTHON_PROTECTED_CONFIG_SHA256:-}" && "$(protected_config_fingerprint "$MSTEAMS_CONTAINER")" == "${BASELINE_MSTEAMS_PROTECTED_CONFIG_SHA256:-}" && "$(protected_config_fingerprint "$STUDIO_CONTAINER")" == "${BASELINE_STUDIO_PROTECTED_CONFIG_SHA256:-}" ]] || return 1
}

verify_active_receipt_runtime() {
  local receipt="$1" container service ref observed identity image_id container_image_id digest architecture config_sha expected_id expected_digest status
  for service in "${COMPOSE_MUTATION_SERVICES[@]}"; do
    container="$(service_container "$service")"
    case "$service" in
      daiananext) ref="$(receipt_value candidate_next_image "$receipt")"; expected_id="$(receipt_value candidate_next_image_id "$receipt")"; expected_digest="$(receipt_value candidate_next_repo_digest "$receipt")"; config_sha="$(receipt_value next_candidate_config_sha256 "$receipt")" ;;
      daianapython) ref="$(receipt_value candidate_python_image "$receipt")"; expected_id="$(receipt_value candidate_python_image_id "$receipt")"; expected_digest="$(receipt_value candidate_python_repo_digest "$receipt")"; config_sha="$(receipt_value python_candidate_config_sha256 "$receipt")" ;;
      daianamsteams) ref="$(receipt_value candidate_msteams_image "$receipt")"; expected_id="$(receipt_value candidate_msteams_image_id "$receipt")"; expected_digest="$(receipt_value candidate_msteams_repo_digest "$receipt")"; config_sha="$(receipt_value msteams_candidate_config_sha256 "$receipt")" ;;
      daianastudio) ref="$(receipt_value candidate_studio_image "$receipt")"; expected_id="$(receipt_value candidate_studio_image_id "$receipt")"; expected_digest="$(receipt_value candidate_studio_repo_digest "$receipt")"; config_sha="$(receipt_value studio_candidate_config_sha256 "$receipt")" ;;
    esac
     observed="$(docker container inspect --format '{{.Config.Image}}' "$container")"
     [[ "$observed" == "$ref" ]] || die "active receipt image reference mismatch for $container; diagnostics retained"
     status="$(docker container inspect --format '{{.State.Status}}' "$container")"
     [[ "$status" == running ]] || die "active receipt candidate container is not running: $container; diagnostics retained"
     container_image_id="$(docker container inspect --format '{{.Image}}' "$container")"
     [[ "$container_image_id" == "$expected_id" ]] || die "active container immutable image ID mismatch for $container; diagnostics retained"
     identity="$(image_identity "$observed")" || die "active container image integrity is unavailable for $container; diagnostics retained"
    image_id="${identity%%|*}"; identity="${identity#*|}"
    digest="${identity%%|*}"; architecture="${identity#*|}"
    [[ "$image_id" == "$expected_id" ]] || die "active receipt image ID mismatch for $container; diagnostics retained"
    [[ "${digest:-none}" == "$expected_digest" ]] || die "active receipt image digest mismatch for $container; diagnostics retained"
    [[ "$architecture" == "$(receipt_value candidate_architecture "$receipt")" ]] || die "active receipt architecture mismatch for $container; diagnostics retained"
    [[ "$(candidate_config_fingerprint "$container")" == "$config_sha" ]] || die "active receipt candidate configuration fingerprint mismatch for $container; diagnostics retained"
    require_candidate_configuration "$container"
  done
  [[ "$(receipt_value candidate_next_image "$receipt")" == "$DAIANA_CANDIDATE_NEXT_IMAGE" && "$(receipt_value candidate_python_image "$receipt")" == "$DAIANA_CANDIDATE_PYTHON_IMAGE" && "$(receipt_value candidate_msteams_image "$receipt")" == "$DAIANA_CANDIDATE_MSTEAMS_IMAGE" && "$(receipt_value candidate_studio_image "$receipt")" == "$DAIANA_CANDIDATE_STUDIO_IMAGE" ]] || die "active receipt requested image values do not match; diagnostics retained"
  [[ "$(receipt_value next_container_id "$receipt")" == "$(docker container inspect --format '{{.Id}}' "$NEXT_CONTAINER")" && "$(receipt_value python_container_id "$receipt")" == "$(docker container inspect --format '{{.Id}}' "$PYTHON_CONTAINER")" && "$(receipt_value msteams_container_id "$receipt")" == "$(docker container inspect --format '{{.Id}}' "$MSTEAMS_CONTAINER")" && "$(receipt_value studio_container_id "$receipt")" == "$(docker container inspect --format '{{.Id}}' "$STUDIO_CONTAINER")" ]] || die "active receipt container ID mismatch; diagnostics retained"
}

compensate() {
  local reason="${1:-activation failure}" restore_status=0
  (( COMPENSATING )) && return 1
  COMPENSATING=1
  set +e
  compose_base up --pull never --no-deps -d "${COMPOSE_MUTATION_SERVICES[@]}" >/dev/null 2>&1
  restore_status=$?
  if (( restore_status == 0 )); then verify_baseline_restored || restore_status=$?; fi
  if (( restore_status != 0 )); then
    write_failure_diagnostics "$reason"
    mark_manual_cleanup "$reason"
    return 1
  fi
  if (( MIGRATION_APPLIED )); then
    write_failure_diagnostics "$reason; migrations are forward-only and were not compensated"
    mark_manual_cleanup "$reason; migrations are forward-only and require manual recovery"
    return 1
  fi
  rm -f "$STATE_DIR/active" "$STATE_DIR/active.receipt" "$STATE_DIR/baseline.receipt" "$STATE_DIR/manual-cleanup-required" "$STATE_DIR/failure-diagnostics.txt"
  [[ -z "$PRIVATE_CHAT_STAGING_DIR" ]] || rm -rf "$PRIVATE_CHAT_STAGING_DIR"
  PRIVATE_CHAT_STAGING_DIR=""
  return 0
}

on_exit() {
  local status=$?
  trap - EXIT ERR INT TERM
  cleanup_private_chat_temp
  if (( MIGRATION_BOUNDARY_PENDING )); then
    PRIVATE_CHAT_DIAGNOSTIC_STATE=blocked
    export PRIVATE_CHAT_DIAGNOSTIC_STATE
    write_migration_commitment blocked 2>/dev/null || true
    write_failure_diagnostics "activation interrupted during migration boundary; database outcome requires manual recovery" 2>/dev/null || true
    mark_manual_cleanup "migration execution was interrupted; database outcome is unknown and retry is blocked" 2>/dev/null || true
  fi
  if (( ACTIVATION_STATE_CREATED && !RUNTIME_MUTATION_STARTED && !ACTIVATION_COMMITTED )); then
    if (( MIGRATION_APPLIED )); then
      write_failure_diagnostics "activation failed after migrations-applied boundary; no database compensation was attempted"
      mark_manual_cleanup "activation failed after forward-only migrations-applied boundary"
    else
      rm -f "$STATE_DIR/baseline.receipt"
      rmdir "$STATE_DIR" 2>/dev/null || true
    fi
  fi
  if (( CLEANUP_ATTEMPTED && !RUNTIME_MUTATION_STARTED && !ACTIVATION_COMMITTED && !CLEANUP_COMMITTED )); then
    # Cleanup validations run before the mutation boundary.  Preserve both
    # receipts even when a validator or redaction check fails.
    write_failure_diagnostics "${LAST_FAILURE_REASON:-cleanup validation failed; manual cleanup is required}" 2>/dev/null || true
    mark_manual_cleanup "${LAST_FAILURE_REASON:-cleanup validation failed; retry is blocked}" 2>/dev/null || true
    status=1
  fi
  if (( RUNTIME_MUTATION_STARTED && !ACTIVATION_COMMITTED )); then
    compensate "activation failed with status $status" || status=1
  fi
  exit "$status"
}

on_signal() {
  local signal="$1"
  if (( MIGRATION_BOUNDARY_PENDING )); then
    MIGRATION_SIGNAL_PENDING=1
    printf 'ERROR: received %s during migration boundary; deferring until recovery marker is durable\n' "$signal" >&2
    return 0
  fi
  printf 'ERROR: received %s during candidate activation\n' "$signal" >&2
  exit 1
}
trap on_exit EXIT
trap 'exit 1' ERR
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

preflight() {
  local next_image="${DAIANA_CANDIDATE_NEXT_IMAGE:-}" python_image="${DAIANA_CANDIDATE_PYTHON_IMAGE:-}" msteams_image="${DAIANA_CANDIDATE_MSTEAMS_IMAGE:-}" studio_image="${DAIANA_CANDIDATE_STUDIO_IMAGE:-}" stale staging_path baseline_next_contract baseline_python_contract baseline_msteams_contract baseline_studio_contract baseline_next_explicit_contract baseline_python_explicit_contract baseline_msteams_explicit_contract baseline_studio_explicit_contract
  require_local_candidate_context
  require_installer_compose_identity
  command -v docker >/dev/null 2>&1 || die "docker is required"
  docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
  [[ "$(uname -m)" == arm64 || "$(uname -m)" == aarch64 ]] || die "host architecture must be arm64"
  [[ -n "${POSTGRES_PASSWORD:-}" && -n "${POSTGRES_DB:-}" ]] || die "migration verification credentials are required"
  export DAIANA_CANDIDATE_NEXT_IMAGE="$next_image" DAIANA_CANDIDATE_PYTHON_IMAGE="$python_image" DAIANA_CANDIDATE_MSTEAMS_IMAGE="$msteams_image" DAIANA_CANDIDATE_STUDIO_IMAGE="$studio_image"
  require_paths
  docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || die "required external network is missing: $NETWORK_NAME"
  [[ ! -e "$STATE_DIR/active" && ! -e "$STATE_DIR/manual-cleanup-required" ]] || die "active or incomplete harness state exists; restore baseline manually first"
  if [[ -e "$STATE_DIR/migrations-committed.receipt" && "$(receipt_value state "$STATE_DIR/migrations-committed.receipt" 2>/dev/null || true)" != committed ]]; then
    die "unreconciled migration boundary exists; inspect the durable marker and reconcile manually before retry"
  fi
  [[ ! -e "$STATE_DIR/baseline.receipt" || -e "$STATE_DIR/active" ]] || die "incomplete receipt state exists; inspect diagnostics before retry"
  stale=""
  for staging_path in "$STATE_DIR"/.staging.*; do
    [[ -e "$staging_path" ]] || continue
    stale="$stale $staging_path"
  done
  [[ -z "$stale" ]] || die "stale staging state exists; remove only after inspecting diagnostics: $stale"
  require_baseline_container "$NEXT_CONTAINER" "$NEXT_BASE_IMAGE"
  require_baseline_container "$PYTHON_CONTAINER" "$PYTHON_BASE_IMAGE"
  require_baseline_container "$MSTEAMS_CONTAINER" "$MSTEAMS_BASE_IMAGE"
  require_baseline_container "$STUDIO_CONTAINER" "$STUDIO_BASE_IMAGE"
  require_baseline_configuration "$NEXT_CONTAINER"
  require_baseline_configuration "$PYTHON_CONTAINER"
  require_baseline_configuration "$MSTEAMS_CONTAINER"
  require_baseline_configuration "$STUDIO_CONTAINER"
  baseline_next_contract="$(env_contract "$NEXT_CONTAINER")" || die "baseline Next environment is malformed or duplicated"
  baseline_python_contract="$(env_contract "$PYTHON_CONTAINER")" || die "baseline Python environment is malformed or duplicated"
  baseline_msteams_contract="$(env_contract "$MSTEAMS_CONTAINER")" || die "baseline Teams environment is malformed or duplicated"
  baseline_studio_contract="$(env_contract "$STUDIO_CONTAINER")" || die "baseline Studio environment is malformed or duplicated"
  baseline_next_explicit_contract="$(compose_environment_contract daiananext)" || die "baseline Compose Next environment contract is unavailable"
  baseline_python_explicit_contract="$(compose_environment_contract daianapython)" || die "baseline Compose Python environment contract is unavailable"
  baseline_msteams_explicit_contract="$(compose_environment_contract daianamsteams)" || die "baseline Compose Teams environment contract is unavailable"
  baseline_studio_explicit_contract="$(compose_environment_contract daianastudio)" || die "baseline Compose Studio environment contract is unavailable"
  BASELINE_NEXT_ENV_CONTRACT="$baseline_next_contract"
  BASELINE_PYTHON_ENV_CONTRACT="$baseline_python_contract"
  BASELINE_MSTEAMS_ENV_CONTRACT="$baseline_msteams_contract"
  BASELINE_STUDIO_ENV_CONTRACT="$baseline_studio_contract"
  BASELINE_NEXT_EXPLICIT_ENV_CONTRACT="$baseline_next_explicit_contract"
  BASELINE_PYTHON_EXPLICIT_ENV_CONTRACT="$baseline_python_explicit_contract"
  BASELINE_MSTEAMS_EXPLICIT_ENV_CONTRACT="$baseline_msteams_explicit_contract"
  BASELINE_STUDIO_EXPLICIT_ENV_CONTRACT="$baseline_studio_explicit_contract"
  export BASELINE_NEXT_ENV_CONTRACT BASELINE_PYTHON_ENV_CONTRACT BASELINE_MSTEAMS_ENV_CONTRACT BASELINE_STUDIO_ENV_CONTRACT BASELINE_NEXT_EXPLICIT_ENV_CONTRACT BASELINE_PYTHON_EXPLICIT_ENV_CONTRACT BASELINE_MSTEAMS_EXPLICIT_ENV_CONTRACT BASELINE_STUDIO_EXPLICIT_ENV_CONTRACT
  validate_candidate_compose_contract "$baseline_next_explicit_contract" "$baseline_python_explicit_contract" "$baseline_msteams_explicit_contract" "$baseline_studio_explicit_contract"
  require_candidate_image "$next_image" "Next"
  require_candidate_image "$python_image" "Python"
  require_candidate_image "$msteams_image" "Teams"
  require_candidate_image "$studio_image" "Studio"
  validate_candidate_source_refs
  log "Preflight passed: complete paths, known baseline, external network, and local arm64 images"
}

activate() {
  local expected_next expected_python active_marker
  [[ "${DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION:-}" == yes ]] || die 'activation requires explicit runtime mutation consent'
  preflight
  mkdir -p "$STATE_DIR"
  ACTIVATION_STATE_CREATED=1
  export DAIANA_CANDIDATE_NEXT_IMAGE DAIANA_CANDIDATE_PYTHON_IMAGE
  PRIVATE_CHAT_STAGING_DIR="$(mktemp -d "$STATE_DIR/.staging.XXXXXX")"
  write_receipt baseline "$PRIVATE_CHAT_STAGING_DIR" || die "baseline receipt could not be written"
  verify_receipts_redacted "$PRIVATE_CHAT_STAGING_DIR"
  validate_receipt_integrity "$PRIVATE_CHAT_STAGING_DIR/baseline.receipt" baseline
  durable_publish "$PRIVATE_CHAT_STAGING_DIR/baseline.receipt" "$STATE_DIR/baseline.receipt" baseline-receipt || die "baseline receipt publication could not be made durable"
  if [[ "${DAIANA_HARNESS_TEST_TAMPER_STAGED_RECEIPT:-}" == yes ]]; then
    printf 'tampered=staged-baseline-injection\n' >> "$STATE_DIR/baseline.receipt"
  fi
  validate_receipt_integrity "$STATE_DIR/baseline.receipt" baseline
  expected_next="$(receipt_value next_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
  expected_python="$(receipt_value python_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_IMAGE_ID="$(receipt_value baseline_next_image_id "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_IMAGE_ID="$(receipt_value baseline_python_image_id "$STATE_DIR/baseline.receipt")"
  BASELINE_MSTEAMS_IMAGE_ID="$(receipt_value baseline_msteams_image_id "$STATE_DIR/baseline.receipt")"
  BASELINE_STUDIO_IMAGE_ID="$(receipt_value baseline_studio_image_id "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_REPO_DIGEST="$(receipt_value baseline_next_repo_digest "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_REPO_DIGEST="$(receipt_value baseline_python_repo_digest "$STATE_DIR/baseline.receipt")"
  BASELINE_MSTEAMS_REPO_DIGEST="$(receipt_value baseline_msteams_repo_digest "$STATE_DIR/baseline.receipt")"
  BASELINE_STUDIO_REPO_DIGEST="$(receipt_value baseline_studio_repo_digest "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_ENV_KEYS="$(receipt_value baseline_next_env_keys "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_ENV_KEYS="$(receipt_value baseline_python_env_keys "$STATE_DIR/baseline.receipt")"
  BASELINE_MSTEAMS_ENV_KEYS="$(receipt_value baseline_msteams_env_keys "$STATE_DIR/baseline.receipt")"
  BASELINE_STUDIO_ENV_KEYS="$(receipt_value baseline_studio_env_keys "$STATE_DIR/baseline.receipt")"
  BASELINE_MSTEAMS_NODE_ENV_STATE="$(receipt_value baseline_msteams_node_env_state "$STATE_DIR/baseline.receipt")"
  BASELINE_STUDIO_NODE_ENV_STATE="$(receipt_value baseline_studio_node_env_state "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_NODE_ENV_STATE="$(receipt_value baseline_next_node_env_state "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_NODE_ENV_STATE="$(receipt_value baseline_python_node_env_state "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_PROTECTED_CONFIG_KEYS="$(receipt_value baseline_next_protected_config_keys "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_PROTECTED_CONFIG_KEYS="$(receipt_value baseline_python_protected_config_keys "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_PROTECTED_CONFIG_SHA256="$(receipt_value baseline_next_protected_config_sha256 "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_PROTECTED_CONFIG_SHA256="$(receipt_value baseline_python_protected_config_sha256 "$STATE_DIR/baseline.receipt")"
  BASELINE_MSTEAMS_FINGERPRINT="$(receipt_value msteams_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
  BASELINE_STUDIO_FINGERPRINT="$(receipt_value studio_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
  BASELINE_MSTEAMS_PROTECTED_CONFIG_SHA256="$(receipt_value baseline_msteams_protected_config_sha256 "$STATE_DIR/baseline.receipt")"
  BASELINE_STUDIO_PROTECTED_CONFIG_SHA256="$(receipt_value baseline_studio_protected_config_sha256 "$STATE_DIR/baseline.receipt")"
  export BASELINE_NEXT_IMAGE_ID BASELINE_PYTHON_IMAGE_ID BASELINE_MSTEAMS_IMAGE_ID BASELINE_STUDIO_IMAGE_ID BASELINE_NEXT_REPO_DIGEST BASELINE_PYTHON_REPO_DIGEST BASELINE_MSTEAMS_REPO_DIGEST BASELINE_STUDIO_REPO_DIGEST BASELINE_NEXT_ENV_KEYS BASELINE_PYTHON_ENV_KEYS BASELINE_MSTEAMS_ENV_KEYS BASELINE_STUDIO_ENV_KEYS BASELINE_NEXT_NODE_ENV_STATE BASELINE_PYTHON_NODE_ENV_STATE BASELINE_MSTEAMS_NODE_ENV_STATE BASELINE_STUDIO_NODE_ENV_STATE BASELINE_NEXT_PROTECTED_CONFIG_KEYS BASELINE_PYTHON_PROTECTED_CONFIG_KEYS BASELINE_MSTEAMS_PROTECTED_CONFIG_KEYS BASELINE_STUDIO_PROTECTED_CONFIG_KEYS BASELINE_NEXT_PROTECTED_CONFIG_SHA256 BASELINE_PYTHON_PROTECTED_CONFIG_SHA256 BASELINE_MSTEAMS_PROTECTED_CONFIG_SHA256 BASELINE_STUDIO_PROTECTED_CONFIG_SHA256 BASELINE_MSTEAMS_FINGERPRINT BASELINE_STUDIO_FINGERPRINT
  [[ "${DAIANA_HARNESS_TEST_TAMPER_BASELINE_FINGERPRINT:-}" == yes ]] && expected_next="$(printf '%064d' 1)"
  BASELINE_NEXT_FINGERPRINT="$expected_next" BASELINE_PYTHON_FINGERPRINT="$expected_python"
  export BASELINE_NEXT_FINGERPRINT BASELINE_PYTHON_FINGERPRINT
  [[ "$(safe_config_fingerprint "$NEXT_CONTAINER")" == "$expected_next" && "$(safe_config_fingerprint "$PYTHON_CONTAINER")" == "$expected_python" ]] || die "staged baseline receipt does not match current containers"
  DAIANA_DB_CONTAINER="${DAIANA_DB_CONTAINER:-supabase-db}" apply_and_verify_migrations
  write_migrations_applied_receipt || die "migrations applied but durable forward-only receipt could not be written"
  if [[ "${DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_VALIDATION:-}" == yes ]]; then
    printf 'tampered=migration-receipt-validation-injection\n' >> "$STATE_DIR/migrations-applied.receipt"
  fi
  validate_migrations_applied_receipt "$STATE_DIR/migrations-applied.receipt"
  [[ "${DAIANA_HARNESS_TEST_FAIL_POST_MIGRATION:-}" == yes ]] && die "test failure after migrations-applied boundary"
  compose_candidate config >/dev/null || die "candidate Compose configuration is invalid"
  RUNTIME_MUTATION_STARTED=1
  compose_candidate up --pull never --no-deps -d "${COMPOSE_MUTATION_SERVICES[@]}" || die "candidate startup failed"
  require_candidate_configuration "$NEXT_CONTAINER"
  require_candidate_configuration "$PYTHON_CONTAINER"
  require_candidate_configuration "$MSTEAMS_CONTAINER"
  require_candidate_configuration "$STUDIO_CONTAINER"
   require_candidate_environment_contract "$NEXT_CONTAINER" "$BASELINE_NEXT_EXPLICIT_ENV_CONTRACT" "$DAIANA_CANDIDATE_NEXT_IMAGE" || die "candidate Next Config.Env values changed outside the documented additions or candidate image defaults"
   require_candidate_environment_contract "$PYTHON_CONTAINER" "$BASELINE_PYTHON_EXPLICIT_ENV_CONTRACT" "$DAIANA_CANDIDATE_PYTHON_IMAGE" || die "candidate Python Config.Env values changed outside the documented additions or candidate image defaults"
   require_candidate_environment_contract "$MSTEAMS_CONTAINER" "$BASELINE_MSTEAMS_EXPLICIT_ENV_CONTRACT" "$DAIANA_CANDIDATE_MSTEAMS_IMAGE" || die "candidate Teams Config.Env values changed outside the baseline or candidate image defaults"
   require_candidate_environment_contract "$STUDIO_CONTAINER" "$BASELINE_STUDIO_EXPLICIT_ENV_CONTRACT" "$DAIANA_CANDIDATE_STUDIO_IMAGE" || die "candidate Studio Config.Env values changed outside the baseline or candidate image defaults"
  write_receipt active "$PRIVATE_CHAT_STAGING_DIR" || die "active receipt could not be written"
  verify_receipts_redacted "$PRIVATE_CHAT_STAGING_DIR"
  if [[ "${DAIANA_HARNESS_TEST_FAIL_RECEIPT_VALIDATION:-}" == yes ]]; then
    printf 'tampered=receipt-validation-injection\n' >> "$PRIVATE_CHAT_STAGING_DIR/active.receipt"
  fi
  validate_receipt_integrity "$PRIVATE_CHAT_STAGING_DIR/active.receipt" active
  verify_active_receipt_runtime "$PRIVATE_CHAT_STAGING_DIR/active.receipt"
  durable_publish "$PRIVATE_CHAT_STAGING_DIR/active.receipt" "$STATE_DIR/active.receipt" active-receipt || die "active receipt publication could not be made durable"
  active_marker="$PRIVATE_CHAT_STAGING_DIR/active.marker"
  printf 'schema=private-chat-harness/active-marker-v1\nstate=active\n' > "$active_marker"
  chmod 600 "$active_marker"
  durable_publish "$active_marker" "$STATE_DIR/active" active-marker || die "active marker publication could not be made durable"
  rm -rf "$PRIVATE_CHAT_STAGING_DIR"
  PRIVATE_CHAT_STAGING_DIR=""
  ACTIVATION_COMMITTED=1
  log "Candidate activated: requested images match observed images and only app containers were recreated"
}

cleanup() {
  local expected_next expected_python
  CLEANUP_ATTEMPTED=1
  CLEANUP_VALIDATION_MODE=1
  if ! require_local_candidate_context; then cleanup_failure "cleanup context validation failed; retry is blocked"; return 1; fi
  if ! require_installer_compose_identity; then cleanup_failure "Installer Compose identity validation failed; retry is blocked"; return 1; fi
  if [[ ! -e "$STATE_DIR/active" ]]; then cleanup_failure "no active candidate harness state; retained receipts require manual inspection"; return 1; fi
  if [[ "${DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION:-}" != yes ]]; then cleanup_failure "cleanup requires explicit runtime mutation consent; retry is blocked"; return 1; fi
  if [[ ! -f "$STATE_DIR/baseline.receipt" || ! -f "$STATE_DIR/active.receipt" ]]; then cleanup_failure "required active receipts are missing; diagnostics retained"; return 1; fi
  if ! verify_receipts_redacted; then cleanup_failure "cleanup receipt redaction verification failed; receipts retained and retry is blocked"; return 1; fi
   DAIANA_CANDIDATE_NEXT_IMAGE="$(receipt_value candidate_next_image "$STATE_DIR/active.receipt")"
   DAIANA_CANDIDATE_PYTHON_IMAGE="$(receipt_value candidate_python_image "$STATE_DIR/active.receipt")"
   DAIANA_CANDIDATE_MSTEAMS_IMAGE="$(receipt_value candidate_msteams_image "$STATE_DIR/active.receipt")"
   DAIANA_CANDIDATE_STUDIO_IMAGE="$(receipt_value candidate_studio_image "$STATE_DIR/active.receipt")"
   export DAIANA_CANDIDATE_NEXT_IMAGE DAIANA_CANDIDATE_PYTHON_IMAGE DAIANA_CANDIDATE_MSTEAMS_IMAGE DAIANA_CANDIDATE_STUDIO_IMAGE
  # The active receipt is untrusted input. Re-run the complete local candidate
  # source/image contract before accepting it or invoking baseline Compose.
  if ! require_candidate_image "$DAIANA_CANDIDATE_NEXT_IMAGE" "Next"; then cleanup_failure "candidate Next image validation failed before baseline restore"; return 1; fi
   if ! require_candidate_image "$DAIANA_CANDIDATE_PYTHON_IMAGE" "Python"; then cleanup_failure "candidate Python image validation failed before baseline restore"; return 1; fi
   if ! require_candidate_image "$DAIANA_CANDIDATE_MSTEAMS_IMAGE" "Teams"; then cleanup_failure "candidate Teams image validation failed before baseline restore"; return 1; fi
   if ! require_candidate_image "$DAIANA_CANDIDATE_STUDIO_IMAGE" "Studio"; then cleanup_failure "candidate Studio image validation failed before baseline restore"; return 1; fi
  if ! validate_candidate_source_refs; then cleanup_failure "candidate source-reference validation failed before baseline restore"; return 1; fi
  if ! validate_receipt_integrity "$STATE_DIR/baseline.receipt" baseline; then cleanup_failure "baseline receipt validation failed before baseline restore"; return 1; fi
  if ! validate_receipt_integrity "$STATE_DIR/active.receipt" active; then cleanup_failure "active receipt validation failed before baseline restore"; return 1; fi
  if ! validate_migration_commitment "$STATE_DIR/migrations-committed.receipt"; then cleanup_failure "migration commitment validation failed before baseline restore"; return 1; fi
  if ! validate_migrations_applied_receipt "$STATE_DIR/migrations-applied.receipt"; then cleanup_failure "migration receipt validation failed before baseline restore"; return 1; fi
  BASELINE_NEXT_IMAGE_ID="$(receipt_value baseline_next_image_id "$STATE_DIR/baseline.receipt")"
   BASELINE_PYTHON_IMAGE_ID="$(receipt_value baseline_python_image_id "$STATE_DIR/baseline.receipt")"
   BASELINE_MSTEAMS_IMAGE_ID="$(receipt_value baseline_msteams_image_id "$STATE_DIR/baseline.receipt")"
   BASELINE_STUDIO_IMAGE_ID="$(receipt_value baseline_studio_image_id "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_REPO_DIGEST="$(receipt_value baseline_next_repo_digest "$STATE_DIR/baseline.receipt")"
   BASELINE_PYTHON_REPO_DIGEST="$(receipt_value baseline_python_repo_digest "$STATE_DIR/baseline.receipt")"
   BASELINE_MSTEAMS_REPO_DIGEST="$(receipt_value baseline_msteams_repo_digest "$STATE_DIR/baseline.receipt")"
   BASELINE_STUDIO_REPO_DIGEST="$(receipt_value baseline_studio_repo_digest "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_ENV_KEYS="$(receipt_value baseline_next_env_keys "$STATE_DIR/baseline.receipt")"
   BASELINE_PYTHON_ENV_KEYS="$(receipt_value baseline_python_env_keys "$STATE_DIR/baseline.receipt")"
   BASELINE_MSTEAMS_ENV_KEYS="$(receipt_value baseline_msteams_env_keys "$STATE_DIR/baseline.receipt")"
   BASELINE_STUDIO_ENV_KEYS="$(receipt_value baseline_studio_env_keys "$STATE_DIR/baseline.receipt")"
   BASELINE_MSTEAMS_NODE_ENV_STATE="$(receipt_value baseline_msteams_node_env_state "$STATE_DIR/baseline.receipt")"
   BASELINE_STUDIO_NODE_ENV_STATE="$(receipt_value baseline_studio_node_env_state "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_NODE_ENV_STATE="$(receipt_value baseline_next_node_env_state "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_NODE_ENV_STATE="$(receipt_value baseline_python_node_env_state "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_PROTECTED_CONFIG_KEYS="$(receipt_value baseline_next_protected_config_keys "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_PROTECTED_CONFIG_KEYS="$(receipt_value baseline_python_protected_config_keys "$STATE_DIR/baseline.receipt")"
  BASELINE_NEXT_PROTECTED_CONFIG_SHA256="$(receipt_value baseline_next_protected_config_sha256 "$STATE_DIR/baseline.receipt")"
  BASELINE_PYTHON_PROTECTED_CONFIG_SHA256="$(receipt_value baseline_python_protected_config_sha256 "$STATE_DIR/baseline.receipt")"
   BASELINE_MSTEAMS_FINGERPRINT="$(receipt_value msteams_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
   BASELINE_STUDIO_FINGERPRINT="$(receipt_value studio_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
   BASELINE_MSTEAMS_PROTECTED_CONFIG_SHA256="$(receipt_value baseline_msteams_protected_config_sha256 "$STATE_DIR/baseline.receipt")"
   BASELINE_STUDIO_PROTECTED_CONFIG_SHA256="$(receipt_value baseline_studio_protected_config_sha256 "$STATE_DIR/baseline.receipt")"
   export BASELINE_NEXT_IMAGE_ID BASELINE_PYTHON_IMAGE_ID BASELINE_MSTEAMS_IMAGE_ID BASELINE_STUDIO_IMAGE_ID BASELINE_NEXT_REPO_DIGEST BASELINE_PYTHON_REPO_DIGEST BASELINE_MSTEAMS_REPO_DIGEST BASELINE_STUDIO_REPO_DIGEST BASELINE_NEXT_ENV_KEYS BASELINE_PYTHON_ENV_KEYS BASELINE_MSTEAMS_ENV_KEYS BASELINE_STUDIO_ENV_KEYS BASELINE_NEXT_NODE_ENV_STATE BASELINE_PYTHON_NODE_ENV_STATE BASELINE_MSTEAMS_NODE_ENV_STATE BASELINE_STUDIO_NODE_ENV_STATE BASELINE_NEXT_PROTECTED_CONFIG_KEYS BASELINE_PYTHON_PROTECTED_CONFIG_KEYS BASELINE_MSTEAMS_PROTECTED_CONFIG_KEYS BASELINE_STUDIO_PROTECTED_CONFIG_KEYS BASELINE_NEXT_PROTECTED_CONFIG_SHA256 BASELINE_PYTHON_PROTECTED_CONFIG_SHA256 BASELINE_MSTEAMS_PROTECTED_CONFIG_SHA256 BASELINE_STUDIO_PROTECTED_CONFIG_SHA256 BASELINE_MSTEAMS_FINGERPRINT BASELINE_STUDIO_FINGERPRINT
  expected_next="$(receipt_value next_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
  expected_python="$(receipt_value python_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
    BASELINE_NEXT_FINGERPRINT="$expected_next" BASELINE_PYTHON_FINGERPRINT="$expected_python"
    BASELINE_MSTEAMS_FINGERPRINT="$(receipt_value msteams_safe_config_sha256 "$STATE_DIR/baseline.receipt")" BASELINE_STUDIO_FINGERPRINT="$(receipt_value studio_safe_config_sha256 "$STATE_DIR/baseline.receipt")"
   export BASELINE_NEXT_FINGERPRINT BASELINE_PYTHON_FINGERPRINT
    if ! verify_active_receipt_runtime "$STATE_DIR/active.receipt"; then cleanup_failure "active runtime identity/configuration validation failed before baseline restore"; return 1; fi
    CLEANUP_VALIDATION_MODE=0
    RUNTIME_MUTATION_STARTED=1
  compose_base up --pull never --no-deps -d "${COMPOSE_MUTATION_SERVICES[@]}" || die "baseline cleanup Compose failed"
  verify_baseline_restored || die "baseline restoration fingerprint mismatch; diagnostics retained"
   rm -f "$STATE_DIR/active" "$STATE_DIR/active.receipt" "$STATE_DIR/baseline.receipt" "$STATE_DIR/manual-cleanup-required" "$STATE_DIR/failure-diagnostics.txt"
   RUNTIME_MUTATION_STARTED=0
   CLEANUP_COMMITTED=1
   rmdir "$STATE_DIR" 2>/dev/null || true
  log "Cleanup assertion passed: baseline app containers restored; volumes and external network untouched"
}

case "${1:-preflight}" in
  preflight) preflight ;;
  validate-source-refs) validate_candidate_source_refs ;;
  activate) activate ;;
  cleanup) cleanup ;;
  *) die "usage: $0 {preflight|activate|cleanup}" ;;
esac
