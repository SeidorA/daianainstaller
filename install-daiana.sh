#!/usr/bin/env bash
set -eEuo pipefail

CURRENT_PHASE="starting"
error_trap() {
  local code=$?
  printf "ERROR: installer failed during %s (exit %s)\n" "$CURRENT_PHASE" "$code" >&2
}
trap error_trap ERR

if [ -z "${BASH_VERSION:-}" ]; then
  printf 'ERROR: run this installer with bash, not sh. Use: bash ./install-daiana.sh [--dry-run]\n' >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

DRY_RUN=0
ACTION="install"
ROLLBACK_MODE=0
ROLLBACK_LIST=0
ROLLBACK_ID=""
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --update|--upgrade) ACTION="update" ;;
    --rollback) ACTION="update"; ROLLBACK_MODE=1 ;;
    --list) ROLLBACK_LIST=1 ;;
    *)
      if [ "$ROLLBACK_MODE" = "1" ] && [ -z "$ROLLBACK_ID" ]; then
        ROLLBACK_ID="$arg"
      fi
      ;;
  esac
done

log() { printf '===> %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf 'DRY-RUN: %q' "$1" >&2
    shift
    for arg in "$@"; do printf ' %q' "$arg" >&2; done
    printf '\n' >&2
    return 0
  fi
  "$@"
}

# shellcheck source=utils/daiana-migrations.sh
source "$ROOT_DIR/utils/daiana-migrations.sh"
# shellcheck source=utils/deployment-bundle.sh
source "$ROOT_DIR/utils/deployment-bundle.sh"
# shellcheck source=utils/update-verification.sh
source "$ROOT_DIR/utils/update-verification.sh"

prompt_yes_no() {
  local question="$1"
  local default_answer="${2:-y}"
  local reply=""
  if [ -t 0 ] && [ -r /dev/tty ]; then
    printf '%s [%s]: ' "$question" "$default_answer" >&2
    read -r reply </dev/tty
  fi
  reply="${reply:-$default_answer}"
  case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
    y*|s*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_repo_synchronized() {
  [ "$ACTION" = "update" ] || return 0
  [ "${SKIP_REPO_SYNC_CHECK:-0}" != "1" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local upstream local_ref remote_ref base_ref status
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  [ -n "$upstream" ] || return 0

  if [ "$DRY_RUN" = "1" ]; then
    log "Would validate git repository sync with $upstream"
    return 0
  fi

  log "Checking repository sync with $upstream"
  git fetch --quiet
  local_ref="$(git rev-parse @)"
  remote_ref="$(git rev-parse '@{u}')"
  base_ref="$(git merge-base @ '@{u}')"

  if [ "$local_ref" = "$remote_ref" ]; then
    return 0
  fi

  if [ "$local_ref" = "$base_ref" ]; then
    status="$(git status --porcelain)"
    if [ -n "$status" ]; then
      die "Repository is behind $upstream but has local changes; commit/stash them before pulling"
    fi
    if prompt_yes_no "Repository is behind $upstream. Pull latest changes before continuing?" "y"; then
      git pull --ff-only
      return 0
    fi
    die "Repository must be synchronized before update/rollback"
  fi

  if [ "$remote_ref" = "$base_ref" ]; then
    log "Repository has local commits ahead of $upstream; continuing without pulling"
    return 0
  fi

  die "Repository has diverged from $upstream; resolve git history before update/rollback"
}

ensure_repo_synchronized

install_supabase_cli() {
  local install_dir tmp installer
  if [ "$(id -u)" -eq 0 ]; then
    install_dir="${SUPABASE_INSTALL_DIR:-/usr/local/bin}"
  else
    install_dir="${SUPABASE_INSTALL_DIR:-$HOME/.supabase/bin}"
  fi

  tmp="$(mktemp)"
  installer="https://raw.githubusercontent.com/supabase/cli/main/install"
  curl -fsSL "$installer" -o "$tmp"
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    sudo env SUPABASE_INSTALL_DIR="$install_dir" bash "$tmp" --install-dir "$install_dir" --no-modify-path
  else
    SUPABASE_INSTALL_DIR="$install_dir" bash "$tmp" --install-dir "$install_dir" --no-modify-path
  fi
  rm -f "$tmp"
  case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) PATH="$install_dir:$PATH"; export PATH ;;
  esac
}

ensure_supabase_cli_on_path() {
  local target_user candidate home
  if command -v supabase >/dev/null 2>&1; then
    return 0
  fi

  target_user="${SUDO_USER:-${USER:-}}"
  candidate="$HOME/.supabase/bin"
  if [ -x "$candidate/supabase" ]; then
    case ":$PATH:" in
      *":$candidate:"*) ;;
      *) PATH="$candidate:$PATH"; export PATH ;;
    esac
    return 0
  fi

  if [ -n "$target_user" ] && [ "$target_user" != "$(id -un)" ] && command -v getent >/dev/null 2>&1; then
    home="$(getent passwd "$target_user" | awk -F: '{print $6}')"
    if [ -n "$home" ] && [ -x "$home/.supabase/bin/supabase" ]; then
      candidate="$home/.supabase/bin"
      case ":$PATH:" in
        *":$candidate:"*) ;;
        *) PATH="$candidate:$PATH"; export PATH ;;
      esac
    fi
  fi
}

  docker_cmd() {
    if command docker info >/dev/null 2>&1; then
      command docker "$@"
      return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
      sudo docker "$@"
    else
      command docker "$@"
    fi
  }

  ensure_docker_group_access() {
    local target_user="${SUDO_USER:-${USER:-}}"
    local group_name="docker"

    [ -n "$target_user" ] || return 0

    if ! getent group "$group_name" >/dev/null 2>&1; then
      if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
        sudo groupadd "$group_name" 2>/dev/null || true
      else
        groupadd "$group_name" 2>/dev/null || true
      fi
    fi

    if id -nG "$target_user" 2>/dev/null | tr " " "\n" | grep -qx "$group_name"; then
      return 0
    fi

    if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
      sudo usermod -aG "$group_name" "$target_user" || return 0
    else
      usermod -aG "$group_name" "$target_user" || return 0
    fi

    log "Added $target_user to the docker group. Run 'newgrp docker' in this terminal now, or log out and back in, for direct docker access without sudo."
  }

      warn_docker_group_refresh() {
        local current_user target_user
        current_user="$(id -un)"
        target_user="${SUDO_USER:-${USER:-}}"

        [ -n "$target_user" ] || return 0
        [ "$current_user" = "$target_user" ] || return 0

        if id -nG | tr ' ' '\n' | grep -qx 'docker'; then
          return 0
        fi

        if id -nG "$target_user" 2>/dev/null | tr ' ' '\n' | grep -qx 'docker'; then
          log "This shell has not refreshed docker group membership yet. Run 'newgrp docker' now, or log out and back in, for direct docker access without sudo."
        fi
      }

install_prereq_packages() {
  local pkg_mgr="$1"
  shift
  local apt_packages=() brew_packages=() need_supabase_cli=0 pkg

  case "$pkg_mgr" in
    brew)
      if ! command -v brew >/dev/null 2>&1; then
        return 1
      fi
      for pkg in "$@"; do
        case "$pkg" in
          psql) brew_packages+=("libpq") ;;
          supabase) brew_packages+=("supabase/tap/supabase") ;;
          *) brew_packages+=("$pkg") ;;
        esac
      done
      if [ "${#brew_packages[@]}" -gt 0 ]; then
        brew install "${brew_packages[@]}"
      fi
      local prefix
      for pkg in "${brew_packages[@]}"; do
        prefix="$(brew --prefix "$pkg" 2>/dev/null || true)"
        if [ -n "$prefix" ] && [ -d "$prefix/bin" ]; then
          PATH="$prefix/bin:$PATH"
        fi
      done
      export PATH
      ;;
    apt)
      for pkg in "$@"; do
        case "$pkg" in
          psql) apt_packages+=("postgresql-client") ;;
          supabase) need_supabase_cli=1 ;;
          *) apt_packages+=("$pkg") ;;
        esac
      done
      if [ "${#apt_packages[@]}" -gt 0 ]; then
        if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
          sudo apt-get update && sudo apt-get install -y "${apt_packages[@]}"
        else
          apt-get update && apt-get install -y "${apt_packages[@]}"
        fi
      fi
      if [ "$need_supabase_cli" = "1" ]; then
        install_supabase_cli
      fi
      ;;
    *) return 1 ;;
  esac
}

install_docker_linux() {
  if command -v docker >/dev/null 2>&1; then
    if docker_cmd compose version >/dev/null 2>&1; then
      log "Docker already installed: $(docker --version)"
      ensure_docker_group_access
      warn_docker_group_refresh
      return 0
    fi
  fi

  case "$(uname -s 2>/dev/null || true)" in
    Linux*) ;;
    *) return 1 ;;
  esac

  command -v apt-get >/dev/null 2>&1 || return 1

  log "Installing Docker Engine and Compose plugin"
  local docker_os_id docker_codename docker_arch
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    docker_os_id="${ID:-}"
    docker_codename="${VERSION_CODENAME:-}"
  fi
  [ -n "$docker_os_id" ] || return 1
  docker_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

  if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
    sudo apt-get update -qq -y
    sudo apt-get install -qq -y ca-certificates curl gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${docker_os_id}/gpg"       | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    docker_codename="${docker_codename:-$(lsb_release -cs 2>/dev/null || echo stable)}"
    echo "deb [arch=${docker_arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_os_id} ${docker_codename} stable"       | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq -y
    sudo apt-get install -qq -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo systemctl enable --now docker || warn "Could not enable docker via systemctl; start it manually."
  else
    apt-get update -qq -y
    apt-get install -qq -y ca-certificates curl gnupg lsb-release
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${docker_os_id}/gpg"       | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    docker_codename="${docker_codename:-$(lsb_release -cs 2>/dev/null || echo stable)}"
    echo "deb [arch=${docker_arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${docker_os_id} ${docker_codename} stable"       > /etc/apt/sources.list.d/docker.list
    apt-get update -qq -y
    apt-get install -qq -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker || warn "Could not enable docker via systemctl; start it manually."
  fi

  ensure_docker_group_access
  warn_docker_group_refresh
  docker_cmd compose version >/dev/null 2>&1 || die "Docker installation finished but 'docker compose' is still unavailable."
}

ensure_prerequisites() {
  local missing=() installable=() manual=() pkg_mgr="" need_docker=0
  local cmd

  ensure_supabase_cli_on_path

  for cmd in git curl jq openssl docker psql supabase; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if command -v docker >/dev/null 2>&1; then
    if docker_cmd compose version >/dev/null 2>&1; then
      COMPOSE_CMD=(docker_cmd compose)
    elif command -v docker-compose >/dev/null 2>&1; then
      COMPOSE_CMD=(docker-compose)
    else
      missing+=("docker-compose")
    fi
  fi

  [ "${#missing[@]}" -gt 0 ] || return 0

  log "Missing prerequisites: ${missing[*]}"

  case "$(uname -s 2>/dev/null || true)" in
    Darwin*) pkg_mgr="brew" ;;
    Linux*) pkg_mgr="apt" ;;
  esac

  for cmd in "${missing[@]}"; do
    case "$cmd" in
      git|curl|jq|openssl|docker-compose|psql|supabase)
        installable+=("$cmd")
        ;;
      docker)
        if [ "$pkg_mgr" = "apt" ]; then
          need_docker=1
        else
          manual+=("$cmd")
        fi
        ;;
    esac
  done

  if { [ "${#installable[@]}" -gt 0 ] || [ "$need_docker" = "1" ]; } && [ -n "$pkg_mgr" ] && [ -t 0 ] && [ -r /dev/tty ]; then
    local pretty=()
    for cmd in "${installable[@]}"; do
      case "$pkg_mgr:$cmd" in
        brew:openssl) pretty+=("openssl@3") ;;
        brew:git|apt:git) pretty+=("git") ;;
        brew:psql) pretty+=("libpq") ;;
        apt:docker-compose) pretty+=("docker-compose-plugin") ;;
        apt:psql) pretty+=("postgresql-client") ;;
        brew:supabase) pretty+=("supabase/tap/supabase") ;;
        *) pretty+=("$cmd") ;;
      esac
    done
    if [ "$need_docker" = "1" ]; then
      pretty+=("docker (engine + compose)")
    fi
    if prompt_yes_no "Install missing prerequisites via $pkg_mgr: ${pretty[*]}?"; then
      CURRENT_PHASE="installing prerequisites"
      if [ "${#installable[@]}" -gt 0 ]; then
        if ! install_prereq_packages "$pkg_mgr" "${installable[@]}"; then
          die "Could not install prerequisites via $pkg_mgr"
        fi
      fi
      if [ "$need_docker" = "1" ]; then
        if ! install_docker_linux; then
          die "Could not install Docker via $pkg_mgr"
        fi
      fi
      log "Prerequisites installed"
      if [ "$pkg_mgr" = "brew" ]; then
        local formula prefix
        for formula in "${pretty[@]}"; do
          prefix="$(brew --prefix "$formula" 2>/dev/null || true)"
          if [ -n "$prefix" ] && [ -d "$prefix/bin" ]; then
            PATH="$prefix/bin:$PATH"
          fi
        done
        export PATH
      fi
      missing=()
      for cmd in curl jq openssl docker psql supabase; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
      done
      if command -v docker >/dev/null 2>&1; then
        if docker_cmd compose version >/dev/null 2>&1; then
          COMPOSE_CMD=(docker_cmd compose)
        elif command -v docker-compose >/dev/null 2>&1; then
          COMPOSE_CMD=(docker-compose)
        else
          missing+=("docker-compose")
        fi
      fi
    fi
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    die "Missing prerequisites: ${missing[*]}. Install them and re-run."
  fi
}

ensure_prerequisites

PORTAINER_URL="${PORTAINER_URL:-http://127.0.0.1:9000}"
NPM_URL="${NPM_URL:-http://127.0.0.1:81}"
PORTAINER_STACK_NAME="${PORTAINER_STACK_NAME:-portainer-bootstrap}"
NPM_STACK_NAME="${NPM_STACK_NAME:-npm-bootstrap}"
APP_STACK_NAME="${APP_STACK_NAME:-daiana-app}"
DAIANA_REGISTRY_NAME="${DAIANA_REGISTRY_NAME:-dockerhub-prod-sdr}"
PORTAINER_ADMIN_USER="${PORTAINER_ADMIN_USER:-admin}"

CREATED_ENV=0
RESTORED_ENV=0
if [ ! -f .env ]; then
  if [ -f .env.old ]; then
    log "Restoring .env from .env.old"
    cp .env.old .env
    CREATED_ENV=1
    RESTORED_ENV=1
  elif [ -f .env.example ]; then
    log "Creating .env from .env.example"
    cp .env.example .env
    CREATED_ENV=1
  else
    die ".env not found"
  fi
fi

load_dotenv() {
  local file="$1"
  local force="${2:-0}"
  local line key value xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*)
        key="${line%%=*}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        value="${line#*=}"
        case "$key" in
          *PASS*|*TOKEN*|*SECRET*|*KEY*|*PAT*|*BEARER*|*COOKIE*|*AUTH*) : ;;
          *) : ;;
        esac
        if [[ "$value" == \"*\" && "$value" == *\" ]]; then
          value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
          value="${value:1:${#value}-2}"
        fi
        if [ "$force" != "1" ] && [ -n "${!key+x}" ]; then
          continue
        fi
        printf -v "$key" '%s' "$value"
        export "${key?}"
        ;;
    esac
  done < "$file"
  if (( xtrace_was_enabled )); then set -x; fi
  return 0
}

load_dotenv .env 0
LOCAL_PROVISION_IMAGES="${LOCAL_PROVISION_IMAGES:-0}"
case "$LOCAL_PROVISION_IMAGES" in
  0|1) ;;
  *) die "LOCAL_PROVISION_IMAGES must be 0 or 1" ;;
esac
export LOCAL_PROVISION_IMAGES
if [ "$CREATED_ENV" = "1" ]; then
  log "Created a fresh .env; checking which values must be prompted, generated, or derived."
else
  log "Loaded existing .env; checking for missing values."
fi

persist_env_value() {
  (
    case "$-" in *x*) set +x ;; esac
    local key="$1" value="$2" tmp value_file
    tmp="$(mktemp)"
    value_file="$(mktemp)"
    chmod 600 "$value_file"
    printf '%s' "$value" > "$value_file"
    if ! awk -v key="$key" -v value_file="$value_file" '
      BEGIN { done = 0 }
      BEGIN { done = 0; if ((getline value < value_file) < 0) exit 1 }
      $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" { print key "=" value; done = 1; next }
      { print }
      END { if (done == 0) print key "=" value }
    ' .env > "$tmp"; then
      rm -f "$tmp" "$value_file"
      return 1
    fi
    rm -f "$value_file"
    if ! mv "$tmp" .env; then
      rm -f "$tmp"
      return 1
    fi
  )
}

seed_supabase_env() {
  log "Checking Supabase core values"
  local missing_core=0
  local var
  for var in JWT_SECRET ANON_KEY SERVICE_ROLE_KEY PG_META_CRYPTO_KEY DASHBOARD_PASSWORD SECRET_KEY_BASE VAULT_ENC_KEY MINIO_ROOT_PASSWORD POSTGRES_PASSWORD LOGFLARE_PUBLIC_ACCESS_TOKEN LOGFLARE_PRIVATE_ACCESS_TOKEN S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET; do
    if [ -z "${!var:-}" ]; then
      log "Missing Supabase key: $var"
      missing_core=1
    fi
  done

  if [ "$CREATED_ENV" = "1" ] || [ "$missing_core" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log "Dry-run: would run sh utils/generate-keys.sh --update-env and sh utils/add-new-auth-keys.sh --update-env"
      return 0
    fi

    CURRENT_PHASE="generating Supabase keys"
    if [ "$CREATED_ENV" = "1" ]; then
      log "Fresh .env detected; generating Supabase keys from scratch"
    else
      log "Missing core Supabase keys; generating them from scratch"
    fi
    log "Running sh utils/generate-keys.sh --update-env"
    if ! sh utils/generate-keys.sh --update-env >/dev/null; then
      die "Failed to generate core Supabase keys"
    fi

    CURRENT_PHASE="generating asymmetric auth keys"
    log "Running bash utils/add-new-auth-keys.sh --update-env"
    if ! bash utils/add-new-auth-keys.sh --update-env >/dev/null; then
      die "Failed to generate Supabase asymmetric auth keys"
    fi

    load_dotenv .env 1
  fi
}

CURRENT_PHASE="seeding Supabase env"
seed_supabase_env

BASE_DOMAIN="${BASE_DOMAIN:-}"
NPM_ADMIN_EMAIL="${NPM_ADMIN_EMAIL:-}"
DAIANA_LOCAL_INSTALL="${DAIANA_LOCAL_INSTALL:-0}"
secret_init_xtrace_was_enabled=0
case "$-" in *x*) secret_init_xtrace_was_enabled=1; set +x ;; esac
NPM_ADMIN_PASS="${NPM_ADMIN_PASS:-}"
PORTAINER_ADMIN_PASS="${PORTAINER_ADMIN_PASS:-${NPM_ADMIN_PASS:-}}"
if (( secret_init_xtrace_was_enabled )); then set -x; fi

prompt() {
  (
    case "$-" in *x*) set +x ;; esac
    local label="$1" default_value="${2:-}" reply=""
    if [ -t 0 ] && [ -r /dev/tty ]; then
      if [ -n "$default_value" ]; then
        printf '%s [%s]: ' "$label" "$default_value" >&2
      else
        printf '%s: ' "$label" >&2
      fi
      read -r reply </dev/tty
    fi
    if [ -z "$reply" ]; then reply="$default_value"; fi
    printf '%s' "$reply"
  )
}

prompt_secret() {
  (
    case "$-" in *x*) set +x ;; esac
    local label="$1" reply="" stty_state=""
    if [ -t 0 ] && [ -r /dev/tty ]; then
      printf '%s: ' "$label" >&2
      stty_state="$(stty -g </dev/tty 2>/dev/null || true)"
      stty -echo </dev/tty 2>/dev/null || true
      read -r reply </dev/tty
      if [ -n "$stty_state" ]; then
        stty "$stty_state" </dev/tty 2>/dev/null || true
      fi
      printf '\n' >&2
    fi
    printf '%s' "$reply"
  )
}

detect_local_ipv4() {
  local interface="" address=""

  case "$(uname -s 2>/dev/null || true)" in
    Darwin*)
      interface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
      [ -n "$interface" ] && address="$(ipconfig getifaddr "$interface" 2>/dev/null || true)"
      ;;
    Linux*)
      address="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
      ;;
  esac

  case "$address" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) printf '%s' "$address" ;;
    *) return 1 ;;
  esac
}

if [ "$DAIANA_LOCAL_INSTALL" = "1" ]; then
  local_ipv4="$(detect_local_ipv4 || true)"
  [ -n "$local_ipv4" ] || die "Could not detect a private IPv4 address for local installation"
  BASE_DOMAIN="${local_ipv4}.nip.io"
  WEBUI_ALLOW_INSECURE_LOCAL_ORIGIN="true"
  export BASE_DOMAIN WEBUI_ALLOW_INSECURE_LOCAL_ORIGIN
  if [ "$DRY_RUN" != "1" ]; then
    persist_env_value BASE_DOMAIN "$BASE_DOMAIN"
  fi
  for public_var in STUDIO_BASE_URL SUPABASE_PUBLIC_URL API_EXTERNAL_URL SITE_URL WEBUI_BASE_URL BACKEND_BASE_URL WS_BASE_URL MS_BASE_URL VANNA_BASE_URL QDRANT_BASE_URL CORS_ALLOW_ORIGIN NEXT_PUBLIC_APP_URL; do
    unset "$public_var"
  done
  log "Local installation detected; using BASE_DOMAIN=$BASE_DOMAIN"
fi

if [ -z "$BASE_DOMAIN" ] && [ ! -t 0 ]; then
  die "BASE_DOMAIN is required. Run in an interactive terminal or export BASE_DOMAIN=your.domain before launching."
fi
if [ -t 0 ] && [ -r /dev/tty ]; then
  log "Interactive mode detected; missing values will be prompted one by one."
fi
prompt_missing() {
  local var="$1"
  local default_value="${2:-}"
  local value="${!var:-}"
  if [ -z "$value" ]; then
    if [ -t 0 ]; then
      value="$(prompt "$var" "$default_value")"
    elif [ -n "$default_value" ]; then
      value="$default_value"
    else
      die "$var is required. Export it or run the installer interactively."
    fi
  fi
  printf -v "$var" '%s' "$value"
      export "${var?}"
}

PORTAINER_PASSWORD_MIN=12

generate_password() {
  local length="${1:-20}"
  [ "$length" -lt "$PORTAINER_PASSWORD_MIN" ] && length="$PORTAINER_PASSWORD_MIN"
  local body_len=$((length - 4))
  [ "$body_len" -lt 8 ] && body_len=8
  local upper lower digit special body
  upper="$( (set +o pipefail; LC_ALL=C tr -dc '[:upper:]' </dev/urandom | head -c 1) )"
  lower="$( (set +o pipefail; LC_ALL=C tr -dc '[:lower:]' </dev/urandom | head -c 1) )"
  digit="$( (set +o pipefail; LC_ALL=C tr -dc '0-9' </dev/urandom | head -c 1) )"
  special="$( (set +o pipefail; LC_ALL=C tr -dc '!@#$%^&*_=+?-' </dev/urandom | head -c 1) )"
  body="$( (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$body_len") )"
  printf '%s%s%s%s%s' "$body" "$upper" "$lower" "$digit" "$special"
}

generate_secret() {
  local length="${1:-48}"
  (set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length")
}

prompt_optional() {
  local xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  local var="$1"
  local label="$2"
  local default_value="${3:-}"
  local value="${!var:-}"
  case "$var:$value" in
    OPENAI_API_KEY:sk-proj-xxxxxxxx) value="" ;;
    SMTP_ADMIN_EMAIL:admin@example.com) value="" ;;
    SMTP_HOST:supabase-mail) value="" ;;
    SMTP_PORT:2500) value="" ;;
    SMTP_USER:fake_mail_user) value="" ;;
    SMTP_PASS:fake_mail_password) value="" ;;
    SMTP_SENDER_NAME:fake_sender) value="" ;;
  esac
  if [ -z "$value" ] && [ -t 0 ] && [ -r /dev/tty ]; then
    value="$(prompt "$label" "$default_value")"
  elif [ -z "$value" ] && [ -n "$default_value" ]; then
    value="$default_value"
  fi
  printf -v "$var" '%s' "$value"
      export "${var?}"
  if [ "$DRY_RUN" != "1" ] && [ -n "$value" ]; then
    persist_env_value "$var" "$value"
  fi
  if (( xtrace_was_enabled )); then set -x; fi
}

prompt_required() {
  local xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  local var="$1"
  local label="$2"
  local value="${!var:-}"
  case "$var:$value" in
    SMTP_HOST:supabase-mail) value="" ;;
    SMTP_USER:fake_mail_user) value="" ;;
    SMTP_PASS:fake_mail_password) value="" ;;
  esac
  while [ -z "$value" ]; do
    if [ -t 0 ] && [ -r /dev/tty ]; then
      value="$(prompt "$label" "")"
    else
      if (( xtrace_was_enabled )); then set -x; fi
      die "$var is required. Export it or run the installer interactively."
    fi
  done
  printf -v "$var" '%s' "$value"
      export "${var?}"
  if [ "$DRY_RUN" != "1" ]; then
    persist_env_value "$var" "$value"
  fi
  if (( xtrace_was_enabled )); then set -x; fi
}

seed_daiana_env() {
  log "Checking Daiana-specific values"
  local changed=0
  local public_scheme="https"
  case "${BASE_DOMAIN:-}" in
    *.nip.io) public_scheme="http" ;;
  esac
  log "Public URL scheme for BASE_DOMAIN is $public_scheme"
  ensure_default() {
    local var="$1"
    local value="$2"
    if [ -z "${!var:-}" ]; then
      printf -v "$var" '%s' "$value"
      export "${var?}"
      if [ "$DRY_RUN" != "1" ]; then
        persist_env_value "$var" "$value"
      fi
      log "Defaulted $var"
      changed=1
    fi
  }
ensure_secret() {
    local function_xtrace_was_enabled=0
    case "$-" in *x*) function_xtrace_was_enabled=1; set +x ;; esac
    local var="$1"
    local length="${2:-64}"
    if [ -z "${!var:-}" ]; then
      local value
      if ! value="$(generate_secret "$length")"; then
        if (( function_xtrace_was_enabled )); then set -x; fi
        return 1
      fi
      printf -v "$var" '%s' "$value"
      export "${var?}"
      if [ "$DRY_RUN" != "1" ]; then
        if ! persist_env_value "$var" "$value"; then
          if (( function_xtrace_was_enabled )); then set -x; fi
          return 1
        fi
      fi
      log "Generated $var"
      changed=1
    fi
    if (( function_xtrace_was_enabled )); then set -x; fi
  }
  ensure_derived() {
    local var="$1"
    local value="$2"
    if [ -z "${!var:-}" ]; then
      printf -v "$var" '%s' "$value"
      export "${var?}"
      if [ "$DRY_RUN" != "1" ]; then
        persist_env_value "$var" "$value"
      fi
      log "Derived $var"
      changed=1
    fi
  }

  log "Deriving public URLs from BASE_DOMAIN"
  ensure_derived STUDIO_BASE_URL "${public_scheme}://studio.${BASE_DOMAIN}"
  ensure_derived SUPABASE_PUBLIC_URL "${public_scheme}://supa.${BASE_DOMAIN}"
  ensure_derived API_EXTERNAL_URL "${public_scheme}://supa.${BASE_DOMAIN}/auth/v1"
  ensure_derived SITE_URL "${public_scheme}://daiana.${BASE_DOMAIN}"
  ensure_derived WEBUI_BASE_URL "${public_scheme}://webui.${BASE_DOMAIN}"
  ensure_derived BACKEND_BASE_URL "${public_scheme}://api.${BASE_DOMAIN}"
  ensure_derived WS_BASE_URL "${public_scheme}://whatsapp.${BASE_DOMAIN}"
  ensure_derived MS_BASE_URL "${public_scheme}://msteams.${BASE_DOMAIN}"
  ensure_derived VANNA_BASE_URL "${public_scheme}://vanna.${BASE_DOMAIN}"
  ensure_derived QDRANT_BASE_URL "${public_scheme}://qdrant.${BASE_DOMAIN}"
  ensure_derived CORS_ALLOW_ORIGIN "${public_scheme}://daiana.${BASE_DOMAIN}"
  ensure_derived NEXT_PUBLIC_APP_URL "${public_scheme}://daiana.${BASE_DOMAIN}"
  ensure_default FORWARDED_ALLOW_IPS "*"
  ensure_default SMTP_SECURE "true"
  ensure_default SMTP_HOST ""
  ensure_default SMTP_USER ""
  ensure_default SMTP_PASS ""
  ensure_default LICENSE_ACTIVATION_BASE_URL ""
  ensure_default DEFAULT_LOCALE "en"
  log "Applying app defaults (press Enter to skip prompts above)"
  ensure_default OPENAI_API_KEY ""
  ensure_default GPTMODEL "gpt-4o-mini"
  ensure_default OPENAI_EMBEDDING_MODEL "text-embedding-3-small"
  ensure_default GEMINI_API_KEY ""
  ensure_default CREDENTIAL_YT ""
  ensure_default GOOGLE_TYPE "service_account"
  ensure_default GOOGLE_PROJECT_ID ""
  ensure_default GOOGLE_PRIVATE_KEY_ID ""
  ensure_default GOOGLE_PRIVATE_KEY ""
  ensure_default GOOGLE_CLIENT_EMAIL ""
  ensure_default GOOGLE_CLIENT_ID ""
  ensure_default GOOGLE_AUTH_URI "https://accounts.google.com/o/oauth2/auth"
  ensure_default GOOGLE_TOKEN_URI "https://oauth2.googleapis.com/token"
  ensure_default GOOGLE_AUTH_PROVIDER_X509_CERT_URL "https://www.googleapis.com/oauth2/v1/certs"
  ensure_default GOOGLE_CLIENT_X509_CERT_URL ""
  ensure_default GOOGLE_DRIVE_CREDENTIALS ""
  ensure_default GOOGLE_MODEL ""
  ensure_default GOOGLE_EMBEDDING_MODEL ""
  ensure_default GOOGLE_UNIVERSE_DOMAIN "googleapis.com"
  ensure_default GOOGLE_SECRET ""
  ensure_secret FLOWISE_SECRETKEY_OVERWRITE 64
  ensure_secret EXPRESS_SESSION_SECRET 64
  ensure_secret JWT_AUTH_TOKEN_SECRET 64
  ensure_secret JWT_REFRESH_TOKEN_SECRET 64
  ensure_secret WEBUI_SECRET_KEY 64
  ensure_secret WEBUI_AUTH_HANDOFF_SECRET 64
  ensure_secret WHATSAPP_SECRET_KEY 64
  ensure_secret BOT_SECRET_KEY 64
  ensure_secret AUTH_KEY 64

  if [ "$changed" = "1" ]; then
    CURRENT_PHASE="refreshing env after Daiana defaults"
    log "Refreshing .env in memory after applying Daiana defaults"
    load_dotenv .env 1
  fi
}

prompt_missing BASE_DOMAIN
[ -n "$BASE_DOMAIN" ] || die "BASE_DOMAIN is required"
prompt_missing NPM_ADMIN_EMAIL 'admin@example.com'

secret_generation_xtrace_was_enabled=0
case "$-" in *x*) secret_generation_xtrace_was_enabled=1; set +x ;; esac
if [ -z "$NPM_ADMIN_PASS" ]; then
  if [ -t 0 ]; then
    NPM_ADMIN_PASS="$(prompt 'NPM_ADMIN_PASS' "$(generate_password 20)")"
  else
    NPM_ADMIN_PASS="$(generate_password 20)"
    log "Generated NPM_ADMIN_PASS automatically (non-interactive)"
  fi
fi
if [ -z "$PORTAINER_ADMIN_PASS" ]; then
  if [ -t 0 ]; then
    PORTAINER_ADMIN_PASS="$(prompt 'PORTAINER_ADMIN_PASS' "$(generate_password 28)")"
  else
    PORTAINER_ADMIN_PASS="$(generate_password 28)"
    log "Generated PORTAINER_ADMIN_PASS automatically (non-interactive)"
  fi
fi
if (( secret_generation_xtrace_was_enabled )); then set -x; fi

log "Prompting SMTP settings"
prompt_optional SMTP_ADMIN_EMAIL 'SMTP_ADMIN_EMAIL (optional)' "$NPM_ADMIN_EMAIL"
prompt_optional SMTP_PORT 'SMTP_PORT (optional)' '587'
prompt_optional SMTP_SENDER_NAME 'SMTP_SENDER_NAME (optional)' 'Daiana'
prompt_required SMTP_HOST 'SMTP_HOST'
prompt_required SMTP_USER 'SMTP_USER'
prompt_required SMTP_PASS 'SMTP_PASS'

log "Prompting Google SSO"
if [ "$CREATED_ENV" = "1" ] && [ "$RESTORED_ENV" = "0" ]; then
  if prompt_yes_no "Enable Google SSO? (y/N)" "n"; then
    GOOGLE_ENABLED="true"
    export GOOGLE_ENABLED
    if [ "$DRY_RUN" != "1" ]; then
      persist_env_value GOOGLE_ENABLED "$GOOGLE_ENABLED"
    fi
    prompt_required GOOGLE_CLIENT_ID 'GOOGLE_CLIENT_ID'
    prompt_required GOOGLE_SECRET 'GOOGLE_SECRET'
  else
    GOOGLE_ENABLED="false"
    export GOOGLE_ENABLED
    if [ "$DRY_RUN" != "1" ]; then
      persist_env_value GOOGLE_ENABLED "$GOOGLE_ENABLED"
    fi
  fi
else
  log "Reinstall detected; keeping existing Google SSO settings without prompting"
fi

log "Prompting optional integrations"
prompt_optional OPENAI_API_KEY 'OPENAI_API_KEY (optional)'
prompt_optional GEMINI_API_KEY 'GEMINI_API_KEY (optional)'
prompt_optional CREDENTIAL_YT 'CREDENTIAL_YT (optional)'
prompt_optional LICENSE_ACTIVATION_BASE_URL 'LICENSE_ACTIVATION_BASE_URL (optional)' 'https://license.example.com'
CURRENT_PHASE="seeding Daiana env"
seed_daiana_env
if [ "$CREATED_ENV" = "1" ] && [ "$RESTORED_ENV" = "0" ] && [ -n "${GOOGLE_CLIENT_ID:-}" ] && [ -n "${GOOGLE_SECRET:-}" ]; then
  if [ "${GOOGLE_ENABLED:-false}" != "true" ]; then
    GOOGLE_ENABLED="true"
    export GOOGLE_ENABLED
    if [ "$DRY_RUN" != "1" ]; then
      persist_env_value GOOGLE_ENABLED "$GOOGLE_ENABLED"
    fi
    log "Enabled Google SSO because both Google credentials were provided"
  fi
fi

export BASE_DOMAIN NPM_ADMIN_EMAIL NPM_ADMIN_PASS PORTAINER_ADMIN_USER PORTAINER_ADMIN_PASS STUDIO_BASE_URL EXPRESS_SESSION_SECRET JWT_AUTH_TOKEN_SECRET JWT_REFRESH_TOKEN_SECRET SMTP_ADMIN_EMAIL SMTP_PORT SMTP_SENDER_NAME SMTP_HOST SMTP_USER SMTP_PASS GOOGLE_CLIENT_ID GOOGLE_SECRET GOOGLE_ENABLED

if [ "$DRY_RUN" != "1" ]; then
  persist_secret_xtrace_was_enabled=0
  case "$-" in *x*) persist_secret_xtrace_was_enabled=1; set +x ;; esac
  persist_env_value BASE_DOMAIN "$BASE_DOMAIN"
  [ -n "${WEBUI_ALLOW_INSECURE_LOCAL_ORIGIN:-}" ] && persist_env_value WEBUI_ALLOW_INSECURE_LOCAL_ORIGIN "$WEBUI_ALLOW_INSECURE_LOCAL_ORIGIN"
  persist_env_value NPM_ADMIN_EMAIL "$NPM_ADMIN_EMAIL"
  persist_env_value NPM_ADMIN_PASS "$NPM_ADMIN_PASS"
  persist_env_value PORTAINER_ADMIN_USER "$PORTAINER_ADMIN_USER"
  persist_env_value PORTAINER_ADMIN_PASS "$PORTAINER_ADMIN_PASS"
  persist_env_value STUDIO_BASE_URL "$STUDIO_BASE_URL"
  [ -n "${SMTP_ADMIN_EMAIL:-}" ] && persist_env_value SMTP_ADMIN_EMAIL "$SMTP_ADMIN_EMAIL"
  [ -n "${SMTP_PORT:-}" ] && persist_env_value SMTP_PORT "$SMTP_PORT"
  [ -n "${SMTP_SENDER_NAME:-}" ] && persist_env_value SMTP_SENDER_NAME "$SMTP_SENDER_NAME"
  [ -n "${SMTP_HOST:-}" ] && persist_env_value SMTP_HOST "$SMTP_HOST"
  [ -n "${SMTP_USER:-}" ] && persist_env_value SMTP_USER "$SMTP_USER"
  [ -n "${SMTP_PASS:-}" ] && persist_env_value SMTP_PASS "$SMTP_PASS"
  [ -n "${GOOGLE_CLIENT_ID:-}" ] && persist_env_value GOOGLE_CLIENT_ID "$GOOGLE_CLIENT_ID"
  [ -n "${GOOGLE_SECRET:-}" ] && persist_env_value GOOGLE_SECRET "$GOOGLE_SECRET"
  [ -n "${GOOGLE_ENABLED:-}" ] && persist_env_value GOOGLE_ENABLED "$GOOGLE_ENABLED"
  [ -n "${SUPABASE_PUBLIC_URL:-}" ] && persist_env_value SUPABASE_PUBLIC_URL "$SUPABASE_PUBLIC_URL"
  [ -n "${API_EXTERNAL_URL:-}" ] && persist_env_value API_EXTERNAL_URL "$API_EXTERNAL_URL"
  [ -n "${SITE_URL:-}" ] && persist_env_value SITE_URL "$SITE_URL"
  [ -n "${WEBUI_BASE_URL:-}" ] && persist_env_value WEBUI_BASE_URL "$WEBUI_BASE_URL"
  [ -n "${LICENSE_ACTIVATION_BASE_URL:-}" ] && persist_env_value LICENSE_ACTIVATION_BASE_URL "$LICENSE_ACTIVATION_BASE_URL"
  [ -n "${SAML_EXTERNAL_URL:-}" ] && persist_env_value SAML_EXTERNAL_URL "$SAML_EXTERNAL_URL"
  persist_env_value EXPRESS_SESSION_SECRET "$EXPRESS_SESSION_SECRET"
  persist_env_value JWT_AUTH_TOKEN_SECRET "$JWT_AUTH_TOKEN_SECRET"
  persist_env_value JWT_REFRESH_TOKEN_SECRET "$JWT_REFRESH_TOKEN_SECRET"
  if (( persist_secret_xtrace_was_enabled )); then set -x; fi
fi

render_compose() {
  local output_file="$1"
  shift
  local args=()
  local file
  for file in "$@"; do
    args+=( -f "$file" )
  done
  "${COMPOSE_CMD[@]}" "${args[@]}" config --no-interpolate > "$output_file"
}

compose_service_image() {
  local compose_file="$1"
  local service_name="$2"
  awk -v service="$service_name" '
    $0 ~ "^  " service ":$" { in_service=1; next }
    in_service && $0 ~ /^  [A-Za-z0-9_-]+:$/ { in_service=0 }
    in_service && $1 == "image:" { print $2; exit }
  ' "$compose_file"
}

configure_local_provision_compose() {
  [ "$LOCAL_PROVISION_IMAGES" = "1" ] || return 0
  local override_file="$ROOT_DIR/docker-compose.local-provision.yml"
  [ -f "$override_file" ] || die "Local provisioning mode requires $override_file"
  APP_DEPLOY_COMPOSE_FILES+=("$override_file")
  log "Local provisioning mode enabled; using local Daiana image override"
}

validate_local_provision_images() {
  [ "$LOCAL_PROVISION_IMAGES" = "1" ] || return 0
  local tag
  for tag in daiana-local:studio-provision daianastudio-local:account-provision; do
    log "Checking local provisioning image: $tag"
    if [ "$DRY_RUN" = "1" ]; then
      log "Dry-run: would verify local Docker image tag $tag"
    elif ! docker_cmd image inspect "$tag" >/dev/null 2>&1; then
      die "Required local image $tag is missing. Build it locally before running the installer (see docker-compose.local-provision.yml)."
    fi
  done
}

normalize_daiana_version() {
  local version="$1"
  [ -n "$version" ] || return 0
  case "$version" in
    v*) printf '%s' "$version" ;;
    *) printf 'v%s' "$version" ;;
  esac
}

prompt_version() {
  local label="$1"
  local default_value="$2"
  local variable_value="${3:-}"
  local value=""
  if [ -n "$variable_value" ]; then
    value="$variable_value"
  else
    value="$(prompt "$label" "$default_value")"
  fi
  printf '%s' "$value"
}

write_update_compose_override() {
  local output_file="$1"
  shift
  {
    printf 'services:\n'
    while [ "$#" -gt 0 ]; do
      printf '  %s:\n' "$1"
      printf '    image: %s\n' "$2"
      shift 2
    done
  } > "$output_file"
}

prepare_update_app_compose_files() {
  if [ "$ROLLBACK_MODE" = "1" ]; then
    prepare_rollback_app_compose_files
    return 0
  fi

  if [ -n "${DAIANA_DEPLOYMENT_BUNDLE:-}" ]; then
    [ "$ACTION" = "update" ] || die "Deployment bundles may only be selected during update"
    load_deployment_bundle "$DAIANA_DEPLOYMENT_BUNDLE"
    UPDATE_COMPOSE_OVERRIDE_FILE="$(mktemp)"
    write_deployment_bundle_override "$UPDATE_COMPOSE_OVERRIDE_FILE"
    APP_DEPLOY_COMPOSE_FILES=("${APP_COMPOSE_FILES[@]}" "$UPDATE_COMPOSE_OVERRIDE_FILE")
    log "Validated complete deployment bundle sha256:$BUNDLE_SHA256"
    return 0
  fi

  [ "$ACTION" = "update" ] || return 0

  local default_daiana_version target_daiana_version
  local webui_version studio_version qdrant_version
  default_daiana_version="$(image_tag "$(compose_service_image docker-compose.app.yml daiananext)")"
  [ -n "$default_daiana_version" ] || die "Could not detect current Daiana app version from docker-compose.app.yml"

  target_daiana_version="$(prompt_version 'Target Daiana app version' "$default_daiana_version" "${DAIANA_TARGET_VERSION:-}")"
  target_daiana_version="$(normalize_daiana_version "$target_daiana_version")"
  [ -n "$target_daiana_version" ] || target_daiana_version="$default_daiana_version"

  webui_version="$(image_tag "$(compose_service_image docker-compose.app.yml daianawebui)")"
  studio_version="$(image_tag "$(compose_service_image docker-compose.app.yml daianastudio)")"
  qdrant_version="$(image_tag "$(compose_service_image docker-compose.app.yml daianaqdrant)")"

  if [ -n "${DAIANA_WEBUI_TARGET_VERSION:-}" ]; then
    webui_version="$(normalize_daiana_version "$DAIANA_WEBUI_TARGET_VERSION")"
  fi
  if [ -n "${DAIANA_STUDIO_TARGET_VERSION:-}" ]; then
    studio_version="$(normalize_daiana_version "$DAIANA_STUDIO_TARGET_VERSION")"
  fi
  if [ -n "${QDRANT_TARGET_VERSION:-}" ]; then
    qdrant_version="$QDRANT_TARGET_VERSION"
  elif prompt_yes_no 'Update independently versioned images?' 'N'; then
    webui_version="$(normalize_daiana_version "$(prompt 'Target WebUI version' "$webui_version")")"
    studio_version="$(normalize_daiana_version "$(prompt 'Target Studio version' "$studio_version")")"
    qdrant_version="$(prompt 'Target Qdrant version' "$qdrant_version")"
  fi

  UPDATE_COMPOSE_OVERRIDE_FILE="$(mktemp)"
  write_update_compose_override "$UPDATE_COMPOSE_OVERRIDE_FILE" \
    daiananext "cloudseidoranalytics/daiana:$target_daiana_version" \
    daianapython "cloudseidoranalytics/daianapython:$target_daiana_version" \
    daianavanna "cloudseidoranalytics/daianavanna:$target_daiana_version" \
    daianamsteams "cloudseidoranalytics/daianamsteams:$target_daiana_version" \
    daianawhatsapp "cloudseidoranalytics/daianawhatsapp:$target_daiana_version" \
    daianawebui "cloudseidoranalytics/daianawebui:$webui_version" \
    daianastudio "cloudseidoranalytics/daianastudio:$studio_version" \
    daianaqdrant "qdrant/qdrant:$qdrant_version"

  APP_DEPLOY_COMPOSE_FILES=("${APP_COMPOSE_FILES[@]}" "$UPDATE_COMPOSE_OVERRIDE_FILE")
  log "Using Daiana app image version $target_daiana_version for update"
  log "Using independently versioned images: webui=$webui_version studio=$studio_version qdrant=$qdrant_version"
}

preserve_bundle_services_from_snapshot() {
  [ "${BUNDLE_ACTIVE:-0}" = "1" ] || return 0
  local snapshot_compose preserved_override service image
  local -a preserved_services
  case "${BUNDLE_SCHEMA_VERSION:-}" in
    2) preserved_services=(daianavanna daianawhatsapp daianawebui daianaqdrant) ;;
    3) preserved_services=(daianastudio daianawebui daianaqdrant) ;;
    *) return 0 ;;
  esac
  local -a override_args=()
  snapshot_compose="$LAST_UPDATE_SNAPSHOT_DIR/docker-compose.before.yml"
  [ -s "$snapshot_compose" ] || die "Cannot preserve bundle services: missing exact update snapshot compose"

  for service in "${preserved_services[@]}"; do
    image="$(compose_service_image "$snapshot_compose" "$service")"
    [ -n "$image" ] || {
      die "Cannot preserve bundle service $service: no image reference in exact update snapshot"
      # shellcheck disable=SC2317
      return 1
    }
    override_args+=("$service" "$image")
  done

  preserved_override="$(mktemp)" || die "Could not create bundle preservation compose override"
  write_update_compose_override "$preserved_override" "${override_args[@]}"
  BUNDLE_PRESERVED_COMPOSE_OVERRIDE_FILE="$preserved_override"
  APP_DEPLOY_COMPOSE_FILES+=("$preserved_override")
  log "Preserving omitted bundle services from exact update snapshot"
}

list_update_snapshots() {
  local history_dir="${UPDATE_HISTORY_DIR:-./volumes/daiana/update-history}"
  [ -d "$history_dir" ] || return 0
  find "$history_dir" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -r
}

latest_update_snapshot() {
  list_update_snapshots | head -n1
}

prepare_rollback_app_compose_files() {
  local history_dir="${UPDATE_HISTORY_DIR:-./volumes/daiana/update-history}"
  local snapshot_id="$ROLLBACK_ID"
  local snapshot_dir=""

  if [ "$ROLLBACK_LIST" = "1" ]; then
    list_update_snapshots
    exit 0
  fi

  if [ -z "$snapshot_id" ]; then
    snapshot_id="$(latest_update_snapshot)"
  fi
  [ -n "$snapshot_id" ] || die "No update rollback snapshots found in $history_dir"

  snapshot_dir="$history_dir/$snapshot_id"
  [ -f "$snapshot_dir/docker-compose.before.yml" ] || die "Rollback snapshot is missing docker-compose.before.yml: $snapshot_dir"
  ROLLBACK_STACK_ENV_JSON="$(read_snapshot_env "$snapshot_dir/portainer-env.before.json")" \
    || die "Could not load saved Portainer Env"

  log "Selected rollback snapshot: $snapshot_id"
  if [ -f "$snapshot_dir/versions.before.txt" ]; then
    sed 's/^/  /' "$snapshot_dir/versions.before.txt" >&2 || true
  fi
  if ! prompt_yes_no "Rollback Daiana app stack to snapshot $snapshot_id?" "N"; then
    die "Rollback cancelled"
  fi

  ROLLBACK_SNAPSHOT_DIR="$snapshot_dir"
  APP_DEPLOY_COMPOSE_FILES=("$snapshot_dir/docker-compose.before.yml")
}

save_update_snapshot() {
  [ "$ACTION" = "update" ] || return 0
  [ "$ROLLBACK_MODE" != "1" ] || return 0
  [ "$DRY_RUN" != "1" ] || return 0

  local history_dir="${UPDATE_HISTORY_DIR:-./volumes/daiana/update-history}"
  local snapshot_id snapshot_dir stack_id
  snapshot_id="$(date -u +%Y%m%d-%H%M%S)"
  snapshot_dir="$history_dir/$snapshot_id"
  LAST_UPDATE_SNAPSHOT_DIR="$snapshot_dir"
  mkdir -p "$snapshot_dir"
  chmod 700 "$snapshot_dir"

  stack_id="$(portainer_stack_id "$APP_STACK_NAME" || true)"
  [ -n "$stack_id" ] && [ "$stack_id" != "null" ] || die "Cannot snapshot missing Portainer stack: $APP_STACK_NAME"
  portainer_request_json GET "/api/stacks/$stack_id/file?endpointId=$PORTAINER_ENDPOINT_ID" \
    | jq -jer '.StackFileContent // .stackFileContent // empty' > "$snapshot_dir/docker-compose.before.yml" \
    || die "Could not capture exact Portainer stack content"
  [ -s "$snapshot_dir/docker-compose.before.yml" ] || die "Portainer returned empty stack content"
  install -m 600 /dev/null "$snapshot_dir/portainer-env.before.json"
  portainer_request_json GET "/api/stacks/$stack_id?endpointId=$PORTAINER_ENDPOINT_ID" \
    | jq -ce '.Env // .env' > "$snapshot_dir/portainer-env.before.json" \
    || die "Could not capture Portainer stack Env"
  read_snapshot_env "$snapshot_dir/portainer-env.before.json" >/dev/null \
    || die "Could not validate Portainer stack Env"

  report_daiana_versions "$snapshot_dir/docker-compose.before.yml" > "$snapshot_dir/versions.before.txt" 2>&1 || true
  jq -n \
    --arg id "$snapshot_id" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg stack "$APP_STACK_NAME" \
    --arg source "portainer-exact-stack" \
    --arg env_sha256 "$(deployment_bundle_sha256 "$(<"$snapshot_dir/portainer-env.before.json")")" \
    --argjson selected_bundle "$(deployment_bundle_metadata_json)" \
    '{id:$id, created_at:$created_at, stack:$stack, type:"image-orchestration-rollback", source:$source,
      portainer_env_sha256:$env_sha256, selected_bundle:$selected_bundle,
      note:"Restores compose/images only; does not roll back databases, migrations, or volumes."}' \
    > "$snapshot_dir/metadata.json"

  log "Saved update rollback snapshot: $snapshot_dir"
}

extract_compose_vars() {
  local tmp
  tmp="$(mktemp)"
  for file in "$@"; do
    [ -f "$file" ] || continue
    grep -hoE '\$\{[A-Za-z_][A-Za-z0-9_]*(:-[^}]*)?\}' "$file" \
      | sed -E 's/^\$\{([A-Za-z_][A-Za-z0-9_]*)(:-[^}]*)?\}$/\1/' >> "$tmp" || true
  done
  awk '!seen[$0]++' "$tmp"
  rm -f "$tmp"
}

stack_env_json() {
  local wanted_json
  wanted_json="$(extract_compose_vars "$@" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  jq -Rn --argjson wanted "$wanted_json" '
    [inputs
      | select(test("^[A-Za-z_][A-Za-z0-9_]*=.*"))
      | capture("^(?<name>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.*)$")
      | . as $env
      | select($wanted | index($env.name))
      | $env
    ]
  ' < .env
}

wait_for_http() {
  local url="$1"
  local label="${2:-$1}"
  local max_tries="${3:-120}"
  local delay="${4:-2}"
  local accept_redirect="${5:-0}"
  local log_response_body="${6:-1}"
  local i=1
  local response status body
  while [ "$i" -le "$max_tries" ]; do
    response="$(curl -sS "$url" -w '\n%{http_code}' || true)"
    status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    case "$status" in
      2*)
        log "$label ready"
        return 0
        ;;
      3*)
        if [ "$accept_redirect" = "1" ]; then
          log "$label ready"
          return 0
        fi
        ;;
    esac
    if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
      log "Waiting for $label... ($i/$max_tries) [HTTP $status]"
      [ "$log_response_body" = "1" ] && [ -n "$body" ] && log "Last response: ${body:0:160}"
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  return 1
}

portainer_temp_cleanup() {
  local file status=0
  for file in "${PORTAINER_TEMP_FILES[@]:-}"; do
    if [ -n "$file" ] && ! rm -f -- "$file" >/dev/null 2>&1; then
      status=1
    fi
  done
  return "$status"
}

portainer_run_saved_trap() {
  local specification="$1" signal="$2" action
  [ -n "$specification" ] || return 0
  specification="${specification#trap -- }"
  specification="${specification% "$signal"}"
  eval "action=$specification"
  eval "$action"
}

portainer_restore_temp_traps() {
  local depth="${PORTAINER_TEMP_SCOPE_DEPTH:-0}" status=0
  if [ -n "${PORTAINER_PREVIOUS_EXIT_TRAPS[$depth]:-}" ]; then
    eval "${PORTAINER_PREVIOUS_EXIT_TRAPS[$depth]}" || status=1
  else
    trap - EXIT || status=1
  fi
  if [ -n "${PORTAINER_PREVIOUS_INT_TRAPS[$depth]:-}" ]; then
    eval "${PORTAINER_PREVIOUS_INT_TRAPS[$depth]}" || status=1
  else
    trap - INT || status=1
  fi
  if [ -n "${PORTAINER_PREVIOUS_TERM_TRAPS[$depth]:-}" ]; then
    eval "${PORTAINER_PREVIOUS_TERM_TRAPS[$depth]}" || status=1
  else
    trap - TERM || status=1
  fi
  if [ -n "${PORTAINER_PREVIOUS_HUP_TRAPS[$depth]:-}" ]; then
    eval "${PORTAINER_PREVIOUS_HUP_TRAPS[$depth]}" || status=1
  else
    trap - HUP || status=1
  fi
  return "$status"
}

portainer_isolate_child_traps() {
  # A request subshell owns its temp scope; never inherit its caller's handlers.
  trap - EXIT INT TERM HUP
}

portainer_temp_trap() {
  local signal="$1" status=$? previous_trap="" cleanup_status=0 restore_status=0 previous_status=0
  case "$signal" in
    INT) status=130 ;;
    TERM) status=143 ;;
    HUP) status=129 ;;
  esac
  portainer_temp_cleanup || cleanup_status=$?
  portainer_restore_temp_traps || restore_status=$?
  case "$signal" in
    EXIT)
      portainer_run_saved_trap "${PORTAINER_PREVIOUS_EXIT_TRAPS[${PORTAINER_TEMP_SCOPE_DEPTH:-0}]:-}" EXIT || previous_status=$?
      [ "$cleanup_status" -eq 0 ] || printf 'WARNING: Portainer temporary-file cleanup failed\n' >&2
      [ "$restore_status" -eq 0 ] || printf 'WARNING: Portainer trap restoration failed\n' >&2
      [ "$previous_status" -eq 0 ] || return "$previous_status"
      [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
      [ "$restore_status" -eq 0 ] || return "$restore_status"
      return "$status"
      ;;
    *)
      case "$signal" in
         INT) previous_trap="${PORTAINER_PREVIOUS_INT_TRAPS[${PORTAINER_TEMP_SCOPE_DEPTH:-0}]:-}" ;;
         TERM) previous_trap="${PORTAINER_PREVIOUS_TERM_TRAPS[${PORTAINER_TEMP_SCOPE_DEPTH:-0}]:-}" ;;
         HUP) previous_trap="${PORTAINER_PREVIOUS_HUP_TRAPS[${PORTAINER_TEMP_SCOPE_DEPTH:-0}]:-}" ;;
       esac
      portainer_run_saved_trap "$previous_trap" "$signal" || previous_status=$?
      [ "$cleanup_status" -eq 0 ] || printf 'WARNING: Portainer temporary-file cleanup failed\n' >&2
      [ "$restore_status" -eq 0 ] || printf 'WARNING: Portainer trap restoration failed\n' >&2
      [ "$previous_status" -eq 0 ] || status="$previous_status"
      [ "$cleanup_status" -eq 0 ] || status="$cleanup_status"
      [ "$restore_status" -eq 0 ] || status="$restore_status"
      exit "$status"
      ;;
  esac
}

portainer_begin_temp_scope() {
  local depth="${PORTAINER_TEMP_SCOPE_DEPTH:--1}"
  depth=$((depth + 1))
  PORTAINER_TEMP_SCOPE_DEPTH="$depth"
  PORTAINER_PREVIOUS_EXIT_TRAPS[depth]="$(trap -p EXIT)"
  PORTAINER_PREVIOUS_INT_TRAPS[depth]="$(trap -p INT)"
  PORTAINER_PREVIOUS_TERM_TRAPS[depth]="$(trap -p TERM)"
  PORTAINER_PREVIOUS_HUP_TRAPS[depth]="$(trap -p HUP)"
  trap 'portainer_temp_trap EXIT' EXIT
  trap 'portainer_temp_trap INT' INT
  trap 'portainer_temp_trap TERM' TERM
  trap 'portainer_temp_trap HUP' HUP
}

portainer_end_temp_scope() {
  local status=$?
  local cleanup_status=0 restore_status=0
  portainer_temp_cleanup || cleanup_status=$?
  portainer_restore_temp_traps || restore_status=$?
  [ "$cleanup_status" -eq 0 ] || printf 'WARNING: Portainer temporary-file cleanup failed\n' >&2
  [ "$restore_status" -eq 0 ] || printf 'WARNING: Portainer trap restoration failed\n' >&2
  PORTAINER_TEMP_SCOPE_DEPTH=$((PORTAINER_TEMP_SCOPE_DEPTH - 1))
  [ "$status" -eq 0 ] || return "$status"
  [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
  [ "$restore_status" -eq 0 ] || return "$restore_status"
  return "$status"
}

portainer_temp_create() {
  local variable="$1" file="" allocator_status=0
  file="$(mktemp)" || allocator_status=$?
  # Some adversarial/test allocators create and print a path before returning
  # failure. Register that path before propagating the allocator status.
  if [ -n "$file" ]; then
    PORTAINER_TEMP_FILES+=("$file")
  fi
  [ "$allocator_status" -eq 0 ] || return "$allocator_status"
  [ -n "$file" ] || return 1
  chmod 600 "$file" || return $?
  printf -v "$variable" '%s' "$file" || return 1
}

portainer_request_json() {
  (
    case "$-" in *x*) set +x ;; esac
    portainer_isolate_child_traps
    local method="$1" path="$2" data="${3:-}" tmp
    local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
    local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
    portainer_begin_temp_scope
    portainer_temp_create tmp || return $?
    printf '%s' "$data" > "$tmp" || return $?
    portainer_request_json_file "$method" "$path" "$tmp" || return $?
  )
}

portainer_request_json_file() {
  (
    case "$-" in *x*) set +x ;; esac
    portainer_isolate_child_traps
    local method="$1" path="$2" data_file="${3:-}" allowed_status="${4:-}" response status body config curl_status=0
    local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
    local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
    portainer_begin_temp_scope
    portainer_temp_create config || return $?
    {
      printf 'silent\nshow-error\nrequest = "%s"\nurl = "%s"\n' "$method" "$PORTAINER_URL$path" || return $?
      printf 'header = "Content-Type: application/json"\n' || return $?
      if [ -n "${PORTAINER_TOKEN:-}" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$PORTAINER_TOKEN" || return $?
      fi
      if [ -n "$data_file" ]; then
        printf 'data-binary = "@%s"\n' "$data_file" || return $?
      fi
    } > "$config" || return $?
    response="$(curl --config "$config" -w '\n%{http_code}')" || curl_status=$?
    if [ "$curl_status" -ne 0 ]; then
      echo "Portainer $method $path failed (HTTP ${response##*$'\n'})" >&2
      return "$curl_status"
    fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2* && "$status" != "$allowed_status" ]]; then
    if [ -n "$allowed_status" ]; then
      printf '%s\n%s' "$body" "$status"
    else
      echo "Portainer $method $path failed (HTTP $status)" >&2
    fi
    return 1
  fi
  if [ -n "$allowed_status" ]; then
    printf '%s\n%s' "$body" "$status" || return $?
  else
    printf '%s' "$body" || return $?
  fi
  )
}

portainer_request_json_file_with_status() {
  local allowed_status="${4:-}"
  local response body status request_status=0
  if response="$(portainer_request_json_file "$1" "$2" "$3" "$allowed_status")"; then
    :
  else
    request_status=$?
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  printf '%s\n%s' "$body" "$status"
  return "$request_status"
}

portainer_request_form() {
  (
    case "$-" in *x*) set +x ;; esac
    portainer_isolate_child_traps
    local method="$1" path="$2" response status body config curl_status=0
    local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
    local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
    portainer_begin_temp_scope
    shift 2
    portainer_temp_create config || return $?
    {
      printf 'silent\nshow-error\nrequest = "%s"\nurl = "%s"\n' "$method" "$PORTAINER_URL$path" || return $?
      if [ -n "${PORTAINER_TOKEN:-}" ]; then
        printf 'header = "Authorization: Bearer %s"\n' "$PORTAINER_TOKEN" || return $?
      fi
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --form) printf 'form = "%s"\n' "$2" || return $?; shift 2 ;;
          *) printf 'url = "%s"\n' "$1" || return $?; shift ;;
        esac
      done
    } > "$config" || return $?
    response="$(curl --config "$config" -w '\n%{http_code}')" || curl_status=$?
    if [ "$curl_status" -ne 0 ]; then
      echo "Portainer $method $path failed (HTTP ${response##*$'\n'})" >&2
      return "$curl_status"
    fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "Portainer $method $path failed (HTTP $status)" >&2
    return 1
  fi
  printf '%s' "$body" || return $?
  )
}

portainer_admin_init() (
  portainer_isolate_child_traps
  local response status body payload user_file pass_file xtrace_was_enabled=0 request_status=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
  local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
  portainer_begin_temp_scope
  portainer_temp_create payload || return $?
  portainer_temp_create user_file || return $?
  portainer_temp_create pass_file || return $?
  printf '%s' "$PORTAINER_ADMIN_USER" > "$user_file" || return $?
  printf '%s' "$PORTAINER_ADMIN_PASS" > "$pass_file" || return $?
  jq -n --rawfile u "$user_file" --rawfile p "$pass_file" '{Username:$u,Password:$p}' > "$payload" || return $?
  response="$(portainer_request_json_file_with_status POST /api/users/admin/init "$payload" 409)" || request_status=$?
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [ "$status" = "409" ]; then
    log "Portainer admin already initialized"
    if (( xtrace_was_enabled )); then set -x; fi
    return 0
  fi
  if [[ "$status" != 2* ]]; then
    echo "Portainer POST /api/users/admin/init failed (HTTP $status)" >&2
    if (( xtrace_was_enabled )); then set -x; fi
    return 1
  fi
  [ "$request_status" -eq 0 ] || return "$request_status"
  if (( xtrace_was_enabled )); then set -x; fi
)

portainer_token() (
  portainer_isolate_child_traps
  local saved_token token xtrace_was_enabled=0 payload user_file pass_file token_status=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
  local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
  portainer_begin_temp_scope
  saved_token="${PORTAINER_TOKEN:-}"
  PORTAINER_TOKEN=""
  portainer_temp_create payload || return $?
  portainer_temp_create user_file || return $?
  portainer_temp_create pass_file || return $?
  printf '%s' "$PORTAINER_ADMIN_USER" > "$user_file" || return $?
  printf '%s' "$PORTAINER_ADMIN_PASS" > "$pass_file" || return $?
  jq -n --rawfile u "$user_file" --rawfile p "$pass_file" '{Username:$u,Password:$p}' > "$payload" || return $?
  token="$(portainer_request_json_file POST /api/auth "$payload" | jq -er '(.jwt // .JWT) | select(type == "string" and length > 0)')" || token_status=$?
  PORTAINER_TOKEN="$saved_token"
  [ "$token_status" -eq 0 ] || return "$token_status"
  printf '%s' "$token" || return $?
  if (( xtrace_was_enabled )); then set -x; fi
)

portainer_get() {
  local path="$1"
  portainer_request_json GET "$path"
}

portainer_registry_id() {
  local registry_name="$1"
  local response body status registry_id
  if ! response="$(portainer_request_json_file_with_status GET /api/registries '' 404)"; then
    return 1
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [ "$status" = "404" ]; then
    return 0
  fi
  [[ "$status" == 2* ]] || return 1
   if ! printf '%s' "$body" | jq -e '
     (if type == "object" and has("data") then .data else . end)
     | type == "array"
   ' >/dev/null
   then
     return 1
   fi
   if ! registry_id="$(printf '%s' "$body" | jq -r --arg name "$registry_name" '
     (if type == "object" and has("data") then .data else . end)
     | first(.[] | select(.Name == $name or .Name == "daiana-images" or ((.URL == "docker.io" or .URL == "registry-1.docker.io") and .Type == 6)) | (.Id // .id)) // empty
   ')"; then
    return 1
  fi
  if [ -n "$registry_id" ] && ! [[ "$registry_id" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s' "$registry_id"
}

portainer_validate_registry_creation_response() {
  local response="$1" registry_id raw_id
  if ! registry_id="$(printf '%s' "$response" | jq -e -r -s '
    if length != 1 then error("expected exactly one JSON value")
    elif (.[0] | type) != "object" then error("expected a JSON object")
    else
      (.[0].Id // .[0].id) as $id
      | if ($id | type) != "number" then error("registry ID is not numeric")
        elif ($id | isfinite | not) or ($id != ($id | floor)) then error("registry ID is not an integer")
        elif $id <= 0 or $id > 9007199254740991 then error("registry ID is outside the safe range")
        else ($id | tostring)
        end
      end
  ')"; then
    return 1
  fi
  if [[ "$response" =~ \"Id\"[[:space:]]*:[[:space:]]*([^,\}[:space:]]+) ]]; then
    raw_id="${BASH_REMATCH[1]}"
  elif [[ "$response" =~ \"id\"[[:space:]]*:[[:space:]]*([^,\}[:space:]]+) ]]; then
    raw_id="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  [ "$raw_id" = "$registry_id" ] || return 1
  [[ "$registry_id" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s' "$registry_id"
}

portainer_ensure_private_registry() {
  local xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  local registry_name="$DAIANA_REGISTRY_NAME"
  local registry_id=""
  if ! registry_id="$(portainer_registry_id "$registry_name")"; then
    if (( xtrace_was_enabled )); then set -x; fi
    # shellcheck disable=SC2317 # test doubles may return from die.
    die 'Could not look up Portainer private registry' || return $?
  fi
  if [ -n "$registry_id" ] && [ "$registry_id" != "null" ]; then
    # shellcheck disable=SC2034 # consumed through Bash 3.2 indirect expansion
    PORTAINER_DAIA_REGISTRIES_JSON="[$registry_id]"
    if (( xtrace_was_enabled )); then set -x; fi
    return 0
  fi

   local registry_user="${DAIANA_REGISTRY_USERNAME:-}"
   local registry_pat="${DAIANA_REGISTRY_PAT:-}"
  if [ -z "$registry_user" ]; then
    registry_user="$(prompt 'Docker Hub username for private Daiana images' '')"
  fi
  if [ -z "$registry_pat" ]; then
    registry_pat="$(prompt_secret 'Docker Hub PAT for private Daiana images')"
  fi
   [ -n "$registry_user" ] || { if (( xtrace_was_enabled )); then set -x; fi; die 'Docker Hub username is required for private Daiana images'; }
   [ -n "$registry_pat" ] || { if (( xtrace_was_enabled )); then set -x; fi; die 'Docker Hub PAT is required for private Daiana images'; }
   # Keep prompted credentials separate from caller variables.  The callers
   # below pass these values only while xtrace is disabled.
   PORTAINER_PRIVATE_REGISTRY_USERNAME="$registry_user"
   PORTAINER_PRIVATE_REGISTRY_PAT="$registry_pat"

  local body user_file pat_file name_file
  local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
  local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
  portainer_begin_temp_scope
  local status=0 cleanup_status=0
  while :; do
    portainer_temp_create body || { status=$?; break; }
    portainer_temp_create user_file || { status=$?; break; }
    portainer_temp_create pat_file || { status=$?; break; }
    portainer_temp_create name_file || { status=$?; break; }
    printf '%s' "$registry_name" > "$name_file" || { status=$?; break; }
    printf '%s' "$registry_user" > "$user_file" || { status=$?; break; }
    printf '%s' "$registry_pat" > "$pat_file" || { status=$?; break; }
    # shellcheck disable=SC2031 # body is written and consumed inside the same protected scope.
    jq -n --rawfile name "$name_file" --rawfile username "$user_file" --rawfile password "$pat_file" \
      '{Name:$name, URL:"docker.io", Type:6, Authentication:true, Username:$username, Password:$password}' > "$body" \
      || { status=$?; break; }
    # shellcheck disable=SC2031 # body is written and consumed inside the same protected scope.
    local creation_response
    creation_response="$(portainer_request_json_file POST /api/registries "$body")" \
      || { status=$?; break; }
    if ! registry_id="$(portainer_validate_registry_creation_response "$creation_response")"; then
      if (( xtrace_was_enabled )); then set -x; fi
      # shellcheck disable=SC2317 # die exits in production; test doubles may return.
      die 'Could not create Portainer registry for private Daiana images' || status=$?
      # shellcheck disable=SC2317 # reachable when the test double for die returns.
      break
    fi
    # shellcheck disable=SC2034 # consumed through Bash 3.2 indirect expansion
    PORTAINER_DAIA_REGISTRIES_JSON="[$registry_id]"
    break
  done
  portainer_end_temp_scope || cleanup_status=$?
  if (( xtrace_was_enabled )); then set -x; fi
  [ "$status" -eq 0 ] || return "$status"
  [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
  return 0
}

docker_login_private_registry() {
  (
  portainer_isolate_child_traps
  case "$-" in *x*) set +x ;; esac
  local registry_user="${1:-${PORTAINER_PRIVATE_REGISTRY_USERNAME:-${DAIANA_REGISTRY_USERNAME:-}}}"
  local registry_pat="${2:-${PORTAINER_PRIVATE_REGISTRY_PAT:-${DAIANA_REGISTRY_PAT:-}}}"
  [ -n "$registry_user" ] || return 0
  [ -n "$registry_pat" ] || return 0

  log "Authenticating local Docker client to Docker Hub for private Daiana images"
  printf '%s' "$registry_pat" | docker_cmd login docker.io --username "$registry_user" --password-stdin >/dev/null
  )
}

prepull_daiana_images() (
  portainer_isolate_child_traps
  # Use a subshell so the caller's xtrace state is restored even when a mock
  # or command below returns early.  Disable xtrace before expanding any
  # credential-bearing argument or default.
  local xtrace_was_enabled=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  local registry_user="${1:-${PORTAINER_PRIVATE_REGISTRY_USERNAME:-${DAIANA_REGISTRY_USERNAME:-}}}"
  local registry_pat="${2:-${PORTAINER_PRIVATE_REGISTRY_PAT:-${DAIANA_REGISTRY_PAT:-}}}"
  log "Pre-pulling private Daiana images"
  docker_login_private_registry "$registry_user" "$registry_pat"
  if (( xtrace_was_enabled )); then set -x; fi
  local args=()
  local file
  for file in "${APP_DEPLOY_COMPOSE_FILES[@]}"; do
    args+=( -f "$file" )
  done
  "${COMPOSE_CMD[@]}" "${args[@]}" pull
)

portainer_endpoint_id() {
  portainer_get '/api/endpoints' | jq -r '
    (if type == "object" and has("data") then .data else . end)
    | .[]?
    | select(.Name == "local-docker" or .URL == "unix:///var/run/docker.sock")
    | .Id
  ' | head -n1
}

portainer_ensure_endpoint() {
  local endpoint_id
  endpoint_id="$(portainer_endpoint_id || true)"
  if [ -n "$endpoint_id" ] && [ "$endpoint_id" != "null" ]; then
    printf '%s' "$endpoint_id"
    return 0
  fi

  log "Creating Portainer local Docker endpoint"
  endpoint_id="$(portainer_request_form POST /api/endpoints \
    --form 'Name=local-docker' \
    --form 'URL=unix:///var/run/docker.sock' \
    --form 'EndpointCreationType=1' | jq -r '.Id')"
  if [ -z "$endpoint_id" ] || [ "$endpoint_id" = "null" ]; then
    die "Could not create Portainer endpoint"
  fi
  printf '%s' "$endpoint_id"
}

portainer_stack_id() {
  local stack_name="$1"
  portainer_get '/api/stacks' | jq -r --arg name "$stack_name" '
    (if type == "object" and has("data") then .data else . end)
    | .[]?
    | select(.Name == $name)
    | .Id
  ' | head -n1
}

portainer_upsert_stack() (
  portainer_isolate_child_traps
  case "$-" in *x*) set +x ;; esac
  local stack_name="$1"
  local stack_env_file="$2"
  local stack_registries_file="${3:-}"
  shift 3
  local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
  local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
  portainer_begin_temp_scope
  local stack_file
  portainer_temp_create stack_file || return $?
  render_compose "$stack_file" "$@" || return $?
  portainer_submit_stack_file "$stack_name" "$stack_env_file" "$stack_registries_file" "$stack_file" || return $?
)

portainer_upsert_stack_from_vars() (
  portainer_isolate_child_traps
  case "$-" in *x*) set +x ;; esac
  local stack_name="$1" env_var="$2" registry_var="$3"
  shift 3
  local env_file registry_file
  local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
  local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
  portainer_begin_temp_scope
  portainer_temp_create env_file || return $?
  portainer_temp_create registry_file || return $?
  printf '%s' "${!env_var}" > "$env_file" || return $?
  printf '%s' "${!registry_var:-}" > "$registry_file" || return $?
  portainer_upsert_stack "$stack_name" "$env_file" "$registry_file" "$@" || return $?
)

portainer_submit_stack_file() (
  portainer_isolate_child_traps
  case "$-" in *x*) set +x ;; esac
  local stack_name="$1"
  local stack_env_file="$2"
  local stack_registries_file="${3:-}"
  local stack_file="$4"
  local body
  local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
  local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
  portainer_begin_temp_scope
  if ! body="$(jq -Rs --arg name "$stack_name" --slurpfile env "$stack_env_file" --rawfile registries "$stack_registries_file" '
    {Name:$name, StackFileContent:., Env:$env[0]}
    + (if $registries != "" then {Registries:$registries} else {} end)
  ' < "$stack_file")"; then
    printf 'Portainer stack payload generation failed\n' >&2
    return 1
  fi
  local stack_id
  stack_id="$(portainer_stack_id "$stack_name" || true)"

  if [ -n "$stack_id" ] && [ "$stack_id" != "null" ]; then
    log "Updating Portainer stack: $stack_name (id=$stack_id)"
    local body_file
    portainer_temp_create body_file || return $?
    printf '%s' "$body" > "$body_file" || return $?
    portainer_request_json_file PUT "/api/stacks/$stack_id?endpointId=$PORTAINER_ENDPOINT_ID" "$body_file" >/dev/null || return $?
  else
    log "Creating Portainer stack: $stack_name"
    local body_file
    portainer_temp_create body_file || return $?
    printf '%s' "$body" > "$body_file" || return $?
    portainer_request_json_file POST "/api/stacks/create/standalone/string?endpointId=$PORTAINER_ENDPOINT_ID" "$body_file" >/dev/null || return $?
  fi
)

portainer_rollback_stack() (
  portainer_isolate_child_traps
  case "$-" in *x*) set +x ;; esac
  local stack_name="$1" env_var="$2" registry_var="$3" stack_file="$4"
  local env_file registry_file stack_temp_file
  local PORTAINER_TEMP_FILES=() PORTAINER_TEMP_SCOPE_DEPTH=-1
  local PORTAINER_PREVIOUS_EXIT_TRAPS=() PORTAINER_PREVIOUS_INT_TRAPS=() PORTAINER_PREVIOUS_TERM_TRAPS=() PORTAINER_PREVIOUS_HUP_TRAPS=()
  portainer_begin_temp_scope
  portainer_temp_create env_file || return $?
  portainer_temp_create registry_file || return $?
  portainer_temp_create stack_temp_file || return $?
  printf '%s' "${!env_var}" > "$env_file" || return $?
  printf '%s' "${!registry_var:-}" > "$registry_file" || return $?
  cat "$stack_file" > "$stack_temp_file" || return $?
  portainer_submit_stack_file "$stack_name" "$env_file" "$registry_file" "$stack_temp_file" || return $?
)

ensure_network() {
  if ! docker_cmd network inspect daiana-mgmt >/dev/null 2>&1; then
    log "Creating shared network daiana-mgmt"
    docker_cmd network create daiana-mgmt >/dev/null
  fi
}

ensure_app_storage_directories() {
  local root="./volumes/daiana"
  local dirs=(
    "$root/static"
    "$root/qdrant/storage"
    "$root/whatsapp/log"
    "$root/flowise"
    "$root/flowise/logs"
    "$root/webui/data"
  )
  local dir os_name owner

  os_name="$(uname -s 2>/dev/null || true)"
  owner="$(id -u):$(id -g)"

  if ! mkdir -p "$root" 2>/dev/null; then
    case "$os_name" in
      Darwin*)
        if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
          sudo mkdir -p "$root" || die "Could not create $root"
          sudo chown -R "$owner" "$root" || die "Could not set ownership on $root"
        else
          die "Could not create $root"
        fi
        ;;
      *)
        if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
          sudo mkdir -p "$root" || die "Could not create $root"
        else
          die "Could not create $root"
        fi
        ;;
    esac
  fi

  for dir in "${dirs[@]}"; do
    if mkdir -p "$dir" 2>/dev/null; then
      continue
    fi
    if [ "$os_name" = "Darwin" ] && command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
      sudo chown -R "$owner" "$root" 2>/dev/null || true
      if mkdir -p "$dir" 2>/dev/null; then
        continue
      fi
      sudo mkdir -p "$dir" || die "Could not create $dir"
      sudo chown -R "$owner" "$root" || die "Could not set ownership on $root"
      continue
    fi
    if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
      sudo mkdir -p "$dir" || die "Could not create $dir"
      continue
    fi
    die "Could not create $dir"
  done
}

ensure_flowise_storage_permissions() {
  local flowise_root="./volumes/daiana"
  local flowise_dir="$flowise_root/flowise"
  local flowise_logs_dir="$flowise_dir/logs"
  local desired_owner="1000:1000"

  case "$(uname -s 2>/dev/null || true)" in
    Darwin*) desired_owner="$(id -u):$(id -g)" ;;
  esac

  if mkdir -p "$flowise_logs_dir" 2>/dev/null; then
    :
  else
    log "Cannot create $flowise_logs_dir"
    if [ "$ACTION" = "install" ]; then
      if prompt_yes_no "Fix Flowise permissions with sudo chown -R $desired_owner $flowise_root now?" "y"; then
        if command -v sudo >/dev/null 2>&1 && [ "$(id -u)" -ne 0 ]; then
          sudo chown -R "$desired_owner" "$flowise_root"
        else
          chown -R "$desired_owner" "$flowise_root"
        fi
        mkdir -p "$flowise_logs_dir" || die "Could not create $flowise_logs_dir even after fixing permissions"
      else
        die "Cannot continue until $flowise_logs_dir is writable"
      fi
    else
      if [ "$(id -u)" -eq 0 ]; then
        chown -R "$desired_owner" "$flowise_root"
      elif command -v sudo >/dev/null 2>&1; then
        sudo chown -R "$desired_owner" "$flowise_root"
      fi
      mkdir -p "$flowise_logs_dir" || die "Could not create $flowise_logs_dir; fix permissions and retry"
    fi
  fi
  if [ "$ACTION" = "install" ]; then
    if [ "${DAIANA_LOCAL_INSTALL:-0}" = "1" ] && [ "$(uname -s 2>/dev/null || true)" = "Darwin" ] && [ -w "$flowise_logs_dir" ]; then
      return
    fi
    if [ "$(id -u)" -eq 0 ]; then
      chown -R "$desired_owner" "$flowise_root"
    elif command -v sudo >/dev/null 2>&1; then
      sudo chown -R "$desired_owner" "$flowise_root"
    else
      log "Skipping ownership change for $flowise_root (no sudo available)"
    fi
  fi
}

bootstrap_portainer() {
  log "Starting Portainer bootstrap container"
  "${COMPOSE_CMD[@]}" -f docker-compose.portainer.yml up -d
  log "Waiting for Portainer API"
  wait_for_http "$PORTAINER_URL/api/status" "Portainer API" 180 2 || die "Portainer API did not become ready"

  if ! portainer_admin_init; then
    log "Portainer admin password rejected; generating a stronger one and retrying"
    PORTAINER_ADMIN_PASS="$(generate_password 28)"
    persist_env_value PORTAINER_ADMIN_PASS "$PORTAINER_ADMIN_PASS"
    export PORTAINER_ADMIN_PASS
    portainer_admin_init
  fi

  portainer_token_status=0
  portainer_token_xtrace_was_enabled=0
  case "$-" in *x*) portainer_token_xtrace_was_enabled=1; set +x ;; esac
  if PORTAINER_TOKEN="$(portainer_token)"; then
    portainer_token_status=0
  else
    portainer_token_status=$?
  fi
  [ "$portainer_token_status" -eq 0 ] || { if (( portainer_token_xtrace_was_enabled )); then set -x; fi; die "Could not authenticate to Portainer"; }
  [ -n "$PORTAINER_TOKEN" ] || { if (( portainer_token_xtrace_was_enabled )); then set -x; fi; die "Could not authenticate to Portainer"; }
  if (( portainer_token_xtrace_was_enabled )); then set -x; fi
  PORTAINER_ENDPOINT_ID="$(portainer_ensure_endpoint)"
  [ -n "$PORTAINER_ENDPOINT_ID" ] || die "Could not determine Portainer endpoint id"
}

SUPABASE_COMPOSE_FILES=(docker-compose.yml)
APP_COMPOSE_FILES=(docker-compose.yml docker-compose.app.yml)
APP_DEPLOY_COMPOSE_FILES=("${APP_COMPOSE_FILES[@]}")
EMPTY_REGISTRIES_VAR=""
UPDATE_COMPOSE_OVERRIDE_FILE=""
BUNDLE_PRESERVED_COMPOSE_OVERRIDE_FILE=""
UPDATE_HISTORY_DIR="${UPDATE_HISTORY_DIR:-./volumes/daiana/update-history}"
ROLLBACK_SNAPSHOT_DIR=""
ROLLBACK_STACK_ENV_JSON=""
LAST_UPDATE_SNAPSHOT_DIR=""

cleanup_update_compose_overrides() {
  local file
  for file in "$UPDATE_COMPOSE_OVERRIDE_FILE" "$BUNDLE_PRESERVED_COMPOSE_OVERRIDE_FILE"; do
    [ -n "$file" ] && rm -f -- "$file"
  done
  return 0
}
trap cleanup_update_compose_overrides EXIT

SUPABASE_CORE_CONTAINERS=(
  supabase-studio
  supabase-kong
  supabase-auth
  supabase-rest
  realtime-dev.supabase-realtime
  supabase-storage
  supabase-imgproxy
  supabase-meta
  supabase-edge-functions
  supabase-db
  supabase-pooler
)

container_health_status() {
  local name="$1"
  docker_cmd inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{if .State.Running}}running{{else}}{{.State.Status}}{{end}}{{end}}' "$name" 2>/dev/null || true
}

wait_for_supabase_ready() {
  local max_tries="${1:-240}"
  local delay="${2:-2}"
  local i=1
  while [ "$i" -le "$max_tries" ]; do
    local pending=() name status
    for name in "${SUPABASE_CORE_CONTAINERS[@]}"; do
      status="$(container_health_status "$name")"
      case "$status" in
        healthy|running) ;;
        "") pending+=("$name:missing") ;;
        *) pending+=("$name:$status") ;;
      esac
    done
    if [ "${#pending[@]}" -eq 0 ]; then
      log "Supabase core is ready"
      return 0
    fi
    if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
      log "Waiting for Supabase core... ($i/$max_tries)"
      log "Pending: ${pending[*]}"
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  return 1
}

psql_with_password() {
  local db_user="$1"
  shift
  local xtrace_was_enabled=0 psql_status=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  { printf '%s\n' "$POSTGRES_PASSWORD"; } | docker_cmd exec -i supabase-db \
    sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql "$@"' sh \
    -h 127.0.0.1 -U "$db_user" -d "$POSTGRES_DB" "$@" || psql_status=$?
  if (( xtrace_was_enabled )); then set -x; fi
  return "$psql_status"
}

psql_file_with_password() {
  local db_user="$1"
  local file="$2"
  shift 2
  local xtrace_was_enabled=0 psql_status=0
  case "$-" in *x*) xtrace_was_enabled=1; set +x ;; esac
  { printf '%s\n' "$POSTGRES_PASSWORD"; cat "$file"; } | docker_cmd exec -i supabase-db \
    sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql "$@"' sh \
    -h 127.0.0.1 -U "$db_user" -d "$POSTGRES_DB" "$@" -v ON_ERROR_STOP=1 -f /dev/stdin || psql_status=$?
  if (( xtrace_was_enabled )); then set -x; fi
  return "$psql_status"
}

psql_scalar() {
  local db_user="$1"
  local query="$2"
  local output
  if output="$(psql_with_password "$db_user" -Atqc "$query" 2>&1)"; then
    :
  else
    printf '__PSQL_ERROR__:%s' "$output"
    return 0
  fi
  printf '%s' "$output"
}

wait_for_supabase_auth_migrations() {
  local max_tries="${1:-120}"
  local delay="${2:-2}"
  local i=1
  local expected_auth_migration_version="20260302000000"
  local required_tables="('auth.schema_migrations'), ('auth.users'), ('auth.identities'), ('auth.sessions'), ('auth.refresh_tokens'), ('auth.audit_log_entries'), ('auth.instances')"

  command -v docker >/dev/null 2>&1 || die "docker is required to verify Supabase Auth migrations"

  while [ "$i" -le "$max_tries" ]; do
    local missing migration_count latest_migration_ready
    missing="$(psql_scalar supabase_auth_admin "WITH required(name) AS (VALUES $required_tables) SELECT COALESCE(string_agg(name, ', '), '') FROM required WHERE to_regclass(name) IS NULL;")"

    if [[ "$missing" != __PSQL_ERROR__:* ]] && [ -z "$missing" ]; then
      latest_migration_ready="$(psql_scalar supabase_auth_admin "SELECT EXISTS (SELECT 1 FROM auth.schema_migrations WHERE version = '$expected_auth_migration_version');")"
      migration_count="$(psql_scalar supabase_auth_admin "SELECT count(*) FROM auth.schema_migrations;")"

      if [ "$latest_migration_ready" = "t" ]; then
        log "Supabase Auth migrations are ready ($migration_count migrations recorded; latest=$expected_auth_migration_version)"
        return 0
      fi
    fi

    if [ "$i" -eq 1 ] || [ $((i % 10)) -eq 0 ]; then
      log "Waiting for Supabase Auth migrations... ($i/$max_tries)"
      if [[ "${missing:-}" == __PSQL_ERROR__:* ]]; then
        log "Auth object readiness query failed: ${missing#__PSQL_ERROR__:}"
      elif [ -n "${missing:-}" ]; then
        log "Missing Auth objects: $missing"
      elif [[ "${latest_migration_ready:-}" == __PSQL_ERROR__:* ]]; then
        log "Auth latest-migration query failed: ${latest_migration_ready#__PSQL_ERROR__:}"
      elif [[ "${migration_count:-}" == __PSQL_ERROR__:* ]]; then
        log "Auth migration count query failed: ${migration_count#__PSQL_ERROR__:}"
      elif [ -n "${migration_count:-}" ]; then
        log "Auth migration rows observed: $migration_count; waiting for migration $expected_auth_migration_version"
      else
        log "Auth migration history is not readable yet"
      fi
    fi

    sleep "$delay"
    i=$((i + 1))
  done

  return 1
}

schema_tables_for_truncate_query() {
  local schema="$1"
  printf "SELECT string_agg(format('%%I.%%I', schemaname, tablename), ', ') FROM pg_tables WHERE schemaname = '%s' AND tablename <> 'schema_migrations';" "$schema"
}

run_psql_file() {
  local schema="$1"
  local db_user="$2"
  local file="$3"
  shift 3
  local tables=""
  local psql_vars=()

  command -v docker >/dev/null 2>&1 || die "docker is required to run Supabase init SQL"

  while [ "$#" -gt 0 ]; do
    psql_vars+=( -v "$1=$2" )
    shift 2
  done

  if [ "$schema" != "-" ] && [ -n "$schema" ]; then
    tables="$(psql_with_password "$db_user" -Atqc "$(schema_tables_for_truncate_query "$schema")")"
    if [ -n "$tables" ]; then
      psql_with_password "$db_user" -v ON_ERROR_STOP=1 -c "TRUNCATE $tables RESTART IDENTITY CASCADE"
    fi
  fi
  if [ "${#psql_vars[@]}" -gt 0 ]; then
    psql_file_with_password "$db_user" "$file" "${psql_vars[@]}"
  else
    psql_file_with_password "$db_user" "$file"
  fi
}

run_supabase_init_sql() {
  local sentinel=".atl/install-daiana.init-sql.done"
  local entry schema file
  if [ -f "$sentinel" ]; then
    log "Supabase data seed SQL already applied; skipping"
    return 0
  fi

  wait_for_supabase_auth_migrations 120 2 || die "Supabase Auth migrations did not finish before data seed SQL"
  local sql_files=(
    "auth:supabase_admin:volumes/db/init/auth.sql"
    "public:supabase_admin:volumes/db/init/public.sql"
    "studio:supabase_admin:volumes/db/init/studio.sql"
    "webui:supabase_admin:volumes/db/init/webui.sql"
    "-:supabase_admin:volumes/db/init/vault.sql"
  )

  mkdir -p .atl
  CURRENT_PHASE="running Supabase data seed SQL"
  log "Running data seeds against the healthy Supabase tenant connection"
  for entry in "${sql_files[@]}"; do
    schema="${entry%%:*}"
    entry="${entry#*:}"
    db_user="${entry%%:*}"
    file="${entry#*:}"
    [ -f "$file" ] || die "Missing SQL file: $file"
    log "Applying $file"
    case "$file" in
      *vault.sql)
        local -a vault_psql_vars=(
          supabase_public_url "$SUPABASE_PUBLIC_URL"
          backend_base_url "$BACKEND_BASE_URL"
          vanna_base_url "$VANNA_BASE_URL"
          qdrant_base_url "$QDRANT_BASE_URL"
          ms_base_url "$MS_BASE_URL"
          ws_base_url "$WS_BASE_URL"
          studio_base_url "$STUDIO_BASE_URL"
          webui_base_url "$WEBUI_BASE_URL"
          next_public_app_url "$NEXT_PUBLIC_APP_URL"
          cors_allow_origin "$CORS_ALLOW_ORIGIN"
        )
        run_psql_file "$schema" "$db_user" "$file" "${vault_psql_vars[@]}"
        ;;
      *)
        run_psql_file "$schema" "$db_user" "$file"
        ;;
    esac
  done
  : > "$sentinel"
}

if [ "$ACTION" = "install" ] && [ "$DRY_RUN" = "1" ]; then
  cat <<EOF
DRY RUN ONLY
Would:
- create shared network: daiana-mgmt
- start Portainer bootstrap container from docker-compose.portainer.yml
- initialize/authenticate Portainer admin
- create/update Portainer stack: $NPM_STACK_NAME from docker-compose.npm.yml
- create/update Portainer stack: $APP_STACK_NAME from ${SUPABASE_COMPOSE_FILES[*]}
- local provisioning mode: $([ "$LOCAL_PROVISION_IMAGES" = "1" ] && printf 'enabled' || printf 'disabled')
- local provisioning image checks: $([ "$LOCAL_PROVISION_IMAGES" = "1" ] && printf 'daiana-local:studio-provision, daianastudio-local:account-provision' || printf 'skipped')
- authenticate Portainer to the private Daiana image registry when needed (production mode only)
- wait for core Supabase to become healthy
- wait for Supabase Auth migrations to finish
- wait for PostgreSQL entrypoint structural init, then run post-start seeds: auth, public, studio, webui, vault
- verify/apply ordered Daiana database migrations before app deployment
- create/update Portainer stack: $APP_STACK_NAME from ${APP_COMPOSE_FILES[*]}$([ "$LOCAL_PROVISION_IMAGES" = "1" ] && printf ' docker-compose.local-provision.yml' || true)
- wait for NPM at $NPM_URL/api
- create proxy hosts without TLS:
  - port.$BASE_DOMAIN
  - nginx.$BASE_DOMAIN
EOF
  exit 0
fi

if [ "$ACTION" = "update" ] && [ "$DRY_RUN" = "1" ]; then
  cat <<EOF
DRY RUN ONLY
Would:
- validate git repository sync with the configured upstream
- validate current Daiana container image versions
- create a rollback snapshot before a normal update
- check for missing/new env vars
- local provisioning mode: $([ "$LOCAL_PROVISION_IMAGES" = "1" ] && printf 'enabled' || printf 'disabled')
- local provisioning image checks: $([ "$LOCAL_PROVISION_IMAGES" = "1" ] && printf 'daiana-local:studio-provision, daianastudio-local:account-provision' || printf 'skipped')
- skip private registry authentication and Daiana image pre-pulls in local mode
- wait for Supabase, verify/apply Daiana database migrations, then update app images
- wait for NPM at $NPM_URL/api
EOF
  exit 0
fi

report_daiana_versions() {
  log "Checking Daiana image versions"
  local stack_file service container label target current
  local compose_files=("$@")
  if [ "${#compose_files[@]}" -eq 0 ]; then
    compose_files=("${APP_DEPLOY_COMPOSE_FILES[@]}")
  fi
  stack_file="$(mktemp)"
  render_compose "$stack_file" "${compose_files[@]}"
  while IFS='|' read -r service container label; do
    target="$(compose_service_image "$stack_file" "$service")"
    current="$(docker_cmd inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)"
    [ -n "$current" ] || current="missing"
    log "$label: current=$current target=$target"
  done <<'EOF'
daiananext|daiana-next|daiana-next
daianapython|daiana-python|daiana-python
daianavanna|daiana-vanna|daiana-vanna
daianamsteams|daiana-msteams|daiana-msteams
daianawhatsapp|daiana-whatsapp|daiana-whatsapp
daianaqdrant|daiana-qdrant|daiana-qdrant
daianastudio|daiana-studio|daiana-studio
daianawebui|daiana-webui|daiana-webui
EOF
  rm -f "$stack_file"
}

CURRENT_PHASE="preparing update image versions"
prepare_update_app_compose_files

CURRENT_PHASE="building stack envs"
if [ "$ROLLBACK_MODE" = "1" ]; then
  NPM_STACK_ENV_JSON='[]'
  APP_STACK_ENV_JSON="$ROLLBACK_STACK_ENV_JSON"
else
  # shellcheck disable=SC2034 # consumed through Bash 3.2 indirect expansion
  NPM_STACK_ENV_JSON="$(stack_env_json docker-compose.npm.yml)"
  # shellcheck disable=SC2034 # consumed through Bash 3.2 indirect expansion
  APP_STACK_ENV_JSON="$(stack_env_json "${APP_DEPLOY_COMPOSE_FILES[@]}")"
fi

if [ "$ACTION" = "update" ]; then
  CURRENT_PHASE="validating current versions"
  report_daiana_versions
  CURRENT_PHASE="connecting to Portainer"
  wait_for_http "$PORTAINER_URL/api/status" "Portainer API" 180 2 || die "Portainer API did not become ready"
  portainer_token_status=0
  portainer_token_xtrace_was_enabled=0
  case "$-" in *x*) portainer_token_xtrace_was_enabled=1; set +x ;; esac
  if PORTAINER_TOKEN="$(portainer_token)"; then
    portainer_token_status=0
  else
    portainer_token_status=$?
  fi
  [ "$portainer_token_status" -eq 0 ] || { if (( portainer_token_xtrace_was_enabled )); then set -x; fi; die "Could not authenticate to Portainer"; }
  [ -n "$PORTAINER_TOKEN" ] || { if (( portainer_token_xtrace_was_enabled )); then set -x; fi; die "Could not authenticate to Portainer"; }
  if (( portainer_token_xtrace_was_enabled )); then set -x; fi
  PORTAINER_ENDPOINT_ID="$(portainer_ensure_endpoint)"
  [ -n "$PORTAINER_ENDPOINT_ID" ] || die "Could not determine Portainer endpoint id"
  if [ "$ROLLBACK_MODE" = "1" ]; then
    if [ "$LOCAL_PROVISION_IMAGES" != "1" ]; then
      log "Preparing private registry access for Daiana images"
      portainer_ensure_private_registry
      CURRENT_PHASE="pre-pulling rollback images"
      prepull_status=0
      prepull_xtrace_was_enabled=0
      case "$-" in *x*) prepull_xtrace_was_enabled=1; set +x ;; esac
      prepull_daiana_images "${PORTAINER_PRIVATE_REGISTRY_USERNAME:-${DAIANA_REGISTRY_USERNAME:-}}" "${PORTAINER_PRIVATE_REGISTRY_PAT:-${DAIANA_REGISTRY_PAT:-}}" || prepull_status=$?
      if (( prepull_xtrace_was_enabled )); then set -x; fi
      [ "$prepull_status" -eq 0 ] || warn "Could not pre-pull rollback images; Portainer may still require registry access"
    else
      log "Local provisioning mode: skipping private registry setup and rollback image pre-pull"
    fi
    configure_local_provision_compose
    validate_local_provision_images
    log "Rolling back Daiana app stack via Portainer"
    if [ "$LOCAL_PROVISION_IMAGES" = "1" ]; then
      portainer_rollback_stack "$APP_STACK_NAME" APP_STACK_ENV_JSON EMPTY_REGISTRIES_VAR "$ROLLBACK_SNAPSHOT_DIR/docker-compose.before.yml"
    else
      portainer_rollback_stack "$APP_STACK_NAME" APP_STACK_ENV_JSON PORTAINER_DAIA_REGISTRIES_JSON "$ROLLBACK_SNAPSHOT_DIR/docker-compose.before.yml"
    fi
    cat <<EOF

Rollback complete.
- Restored snapshot: ${ROLLBACK_SNAPSHOT_DIR:-unknown}
- Scope: compose/images only; databases, migrations, and volumes were not rolled back.
EOF
    exit 0
  fi
  CURRENT_PHASE="saving update rollback snapshot"
  save_update_snapshot
  preserve_bundle_services_from_snapshot
else
  CURRENT_PHASE="bootstrapping Portainer"
  ensure_network
  bootstrap_portainer
fi

configure_local_provision_compose
validate_local_provision_images

log "Deploying NPM stack via Portainer"
portainer_upsert_stack_from_vars "$NPM_STACK_NAME" NPM_STACK_ENV_JSON EMPTY_REGISTRIES_VAR docker-compose.npm.yml

if [ "$ACTION" = "install" ]; then
  log "Deploying core Supabase stack via Portainer"
  portainer_upsert_stack_from_vars "$APP_STACK_NAME" APP_STACK_ENV_JSON EMPTY_REGISTRIES_VAR "${SUPABASE_COMPOSE_FILES[@]}"
  CURRENT_PHASE="waiting for core Supabase"
  wait_for_supabase_ready 240 2 || die "Supabase core did not become ready"
  run_supabase_init_sql
else
  CURRENT_PHASE="waiting for currently deployed Supabase"
  wait_for_supabase_ready 240 2 || die "Existing Supabase core did not become ready"
fi

CURRENT_PHASE="running Daiana database migrations"
run_daiana_migrations

log "Preparing app storage directories"
ensure_app_storage_directories

log "Applying Flowise storage ownership"
ensure_flowise_storage_permissions

if [ "$LOCAL_PROVISION_IMAGES" != "1" ]; then
  log "Preparing private registry access for Daiana images"
  portainer_ensure_private_registry

  CURRENT_PHASE="pre-pulling Daiana images"
  if [ "${BUNDLE_ACTIVE:-0}" = "1" ]; then
    prepull_deployment_bundle_images
  else
    prepull_status=0
    prepull_xtrace_was_enabled=0
    case "$-" in *x*) prepull_xtrace_was_enabled=1; set +x ;; esac
    prepull_daiana_images "${PORTAINER_PRIVATE_REGISTRY_USERNAME:-${DAIANA_REGISTRY_USERNAME:-}}" "${PORTAINER_PRIVATE_REGISTRY_PAT:-${DAIANA_REGISTRY_PAT:-}}" || prepull_status=$?
    if (( prepull_xtrace_was_enabled )); then set -x; fi
    [ "$prepull_status" -eq 0 ] || warn "Could not pre-pull Daiana images; Portainer may still require registry access"
  fi
else
  log "Local provisioning mode: skipping private registry setup and Daiana image pre-pull"
fi

log "Deploying Daiana app stack via Portainer"
if [ "${BUNDLE_ACTIVE:-0}" = "1" ]; then
  log "Complete deployment bundle replacement start: sha256:$BUNDLE_SHA256; rollback snapshot=$LAST_UPDATE_SNAPSHOT_DIR"
fi
if [ "$LOCAL_PROVISION_IMAGES" = "1" ]; then
  portainer_upsert_stack_from_vars "$APP_STACK_NAME" APP_STACK_ENV_JSON EMPTY_REGISTRIES_VAR "${APP_DEPLOY_COMPOSE_FILES[@]}"
else
  portainer_upsert_stack_from_vars "$APP_STACK_NAME" APP_STACK_ENV_JSON PORTAINER_DAIA_REGISTRIES_JSON "${APP_DEPLOY_COMPOSE_FILES[@]}"
fi
if [ "${BUNDLE_ACTIVE:-0}" = "1" ]; then
  log "Complete deployment bundle replacement finish: sha256:$BUNDLE_SHA256"
fi

if [ "$ACTION" = "update" ]; then
  CURRENT_PHASE="verifying updated Daiana services"
  verify_update_services || die "Updated Daiana services did not become ready; update is incomplete"
fi

log "Waiting for NPM API"
wait_for_http "$NPM_URL/api" "NPM API" 180 2 1 || die "NPM API did not become ready"

if [ "$ACTION" = "install" ]; then
  log "Creating proxy hosts without TLS"
  bootstrap_status=0
  bootstrap_xtrace_was_enabled=0
  case "$-" in
    *x*) bootstrap_xtrace_was_enabled=1; set +x ;;
  esac
  if BASE_DOMAIN="$BASE_DOMAIN" NPM_ADMIN_EMAIL="$NPM_ADMIN_EMAIL" NPM_ADMIN_PASS="$NPM_ADMIN_PASS" \
    TLS_MODE=none ENSURE_PROXY_HOSTS=1 \
      bash utils/npm_ssl_bootstrap.sh; then
    bootstrap_status=0
  else
    bootstrap_status=$?
  fi
  if (( bootstrap_xtrace_was_enabled )); then
    set -x
  fi
  [ "$bootstrap_status" -eq 0 ] || exit "$bootstrap_status"

  cat <<EOF

Done.
- Portainer: $PORTAINER_URL
- NPM: $NPM_URL
- Domains:
  - port.$BASE_DOMAIN
  - nginx.$BASE_DOMAIN
- TLS: pendiente; ejecuta bash apply-certs.sh cuando quieras certificados
EOF
else
  cat <<EOF

Update complete.
- Portainer: $PORTAINER_URL
- NPM: $NPM_URL
EOF
fi
