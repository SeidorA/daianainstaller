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
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
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
}

load_dotenv .env 0
if [ "$CREATED_ENV" = "1" ]; then
  log "Created a fresh .env; checking which values must be prompted, generated, or derived."
else
  log "Loaded existing .env; checking for missing values."
fi

persist_env_value() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { done = 0 }
    $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" { print key "=" value; done = 1; next }
    { print }
    END { if (done == 0) print key "=" value }
  ' .env > "$tmp"
  mv "$tmp" .env
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
NPM_ADMIN_PASS="${NPM_ADMIN_PASS:-}"
PORTAINER_ADMIN_PASS="${PORTAINER_ADMIN_PASS:-${NPM_ADMIN_PASS:-}}"

prompt() {
  local label="$1"
  local default_value="${2:-}"
  local reply=""
  if [ -t 0 ] && [ -r /dev/tty ]; then
    if [ -n "$default_value" ]; then
      printf '%s [%s]: ' "$label" "$default_value" >&2
    else
      printf '%s: ' "$label" >&2
    fi
    read -r reply </dev/tty
  fi
  if [ -z "$reply" ]; then
    reply="$default_value"
  fi
  printf '%s' "$reply"
}

prompt_secret() {
  local label="$1"
  local reply="" stty_state=""
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
}

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
}

prompt_required() {
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
      die "$var is required. Export it or run the installer interactively."
    fi
  done
  printf -v "$var" '%s' "$value"
      export "${var?}"
  if [ "$DRY_RUN" != "1" ]; then
    persist_env_value "$var" "$value"
  fi
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
    local var="$1"
    local length="${2:-64}"
    if [ -z "${!var:-}" ]; then
      local value
      value="$(generate_secret "$length")"
      printf -v "$var" '%s' "$value"
      export "${var?}"
      if [ "$DRY_RUN" != "1" ]; then
        persist_env_value "$var" "$value"
      fi
      log "Generated $var"
      changed=1
    fi
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
  persist_env_value BASE_DOMAIN "$BASE_DOMAIN"
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

image_tag() {
  local image="$1"
  printf '%s' "${image##*:}"
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
  [ "$ACTION" = "update" ] || return 0
  if [ "$ROLLBACK_MODE" = "1" ]; then
    prepare_rollback_app_compose_files
    return 0
  fi

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
  local snapshot_id snapshot_dir stack_id stack_content
  snapshot_id="$(date -u +%Y%m%d-%H%M%S)"
  snapshot_dir="$history_dir/$snapshot_id"
  mkdir -p "$snapshot_dir"

  stack_id="$(portainer_stack_id "$APP_STACK_NAME" || true)"
  stack_content=""
  if [ -n "$stack_id" ] && [ "$stack_id" != "null" ]; then
    stack_content="$(portainer_request_json GET "/api/stacks/$stack_id/file?endpointId=$PORTAINER_ENDPOINT_ID" | jq -r '.StackFileContent // .stackFileContent // empty' || true)"
  fi

  if [ -n "$stack_content" ]; then
    printf '%s\n' "$stack_content" > "$snapshot_dir/docker-compose.before.yml"
  else
    render_compose "$snapshot_dir/docker-compose.before.yml" "${APP_COMPOSE_FILES[@]}"
  fi

  report_daiana_versions "$snapshot_dir/docker-compose.before.yml" > "$snapshot_dir/versions.before.txt" 2>&1 || true
  jq -n \
    --arg id "$snapshot_id" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg stack "$APP_STACK_NAME" \
    --arg source "portainer-or-local-render" \
    '{id:$id, created_at:$created_at, stack:$stack, type:"image-orchestration-rollback", source:$source, note:"Restores compose/images only; does not roll back databases, migrations, or volumes."}' \
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
  local i=1
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
      [ -n "$body" ] && log "Last response: ${body:0:160}"
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  return 1
}

portainer_request_json() {
  local method="$1"
  local path="$2"
  local data="${3:-}"
  local response status body
  local args=( -sS -X "$method" "$PORTAINER_URL$path" -H 'Content-Type: application/json' )
  if [ -n "${PORTAINER_TOKEN:-}" ]; then
    args+=( -H "Authorization: Bearer $PORTAINER_TOKEN" )
  fi
  if [ -n "$data" ]; then
    args+=( -d "$data" )
  fi
  response="$(curl "${args[@]}" -w '\n%{http_code}' || true)"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "Portainer $method $path failed (HTTP $status):" >&2
    echo "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

portainer_request_form() {
  local method="$1"
  local path="$2"
  shift 2
  local response status body
  local args=( -sS -X "$method" "$PORTAINER_URL$path" )
  if [ -n "${PORTAINER_TOKEN:-}" ]; then
    args+=( -H "Authorization: Bearer $PORTAINER_TOKEN" )
  fi
  response="$(curl "${args[@]}" "$@" -w '\n%{http_code}' || true)"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "Portainer $method $path failed (HTTP $status):" >&2
    echo "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

portainer_admin_init() {
  local response status body
  response="$(curl -sS -X POST "$PORTAINER_URL/api/users/admin/init" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg u "$PORTAINER_ADMIN_USER" --arg p "$PORTAINER_ADMIN_PASS" '{Username:$u,Password:$p}')" \
    -w '\n%{http_code}' || true)"
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [ "$status" = "409" ]; then
    log "Portainer admin already initialized"
    return 0
  fi
  if [[ "$status" != 2* ]]; then
    echo "Portainer POST /api/users/admin/init failed (HTTP $status):" >&2
    echo "$body" >&2
    return 1
  fi
}

portainer_token() {
  local saved_token="${PORTAINER_TOKEN:-}"
  PORTAINER_TOKEN=""
  local token
  token="$(portainer_request_json POST /api/auth "$(jq -n --arg u "$PORTAINER_ADMIN_USER" --arg p "$PORTAINER_ADMIN_PASS" '{Username:$u,Password:$p}')" | jq -r '.jwt // .JWT // empty')"
  PORTAINER_TOKEN="$saved_token"
  printf '%s' "$token"
}

portainer_get() {
  local path="$1"
  portainer_request_json GET "$path"
}

portainer_registry_id() {
  local registry_name="$1"
  portainer_get '/api/registries' | jq -r --arg name "$registry_name" '
    (if type == "object" and has("data") then .data else . end)
    | .[]?
    | select(.Name == $name or .Name == "daiana-images" or ((.URL == "docker.io" or .URL == "registry-1.docker.io") and .Type == 6))
    | .Id
  ' | head -n1
}

portainer_ensure_private_registry() {
  local registry_name="$DAIANA_REGISTRY_NAME"
  local registry_id=""
  registry_id="$(portainer_registry_id "$registry_name" || true)"
  if [ -n "$registry_id" ] && [ "$registry_id" != "null" ]; then
    printf '[%s]' "$registry_id"
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
  [ -n "$registry_user" ] || die 'Docker Hub username is required for private Daiana images'
  [ -n "$registry_pat" ] || die 'Docker Hub PAT is required for private Daiana images'

  DAIANA_REGISTRY_USERNAME="$registry_user"
  DAIANA_REGISTRY_PAT="$registry_pat"

  local body
  body="$(jq -n \
    --arg name "$registry_name" \
    --arg username "$registry_user" \
    --arg password "$registry_pat" \
    '{Name:$name, URL:"docker.io", Type:6, Authentication:true, Username:$username, Password:$password}')"
  registry_id="$(portainer_request_json POST /api/registries "$body" | jq -r '.Id // .id // empty')"
  [ -n "$registry_id" ] || die 'Could not create Portainer registry for private Daiana images'
  printf '[%s]' "$registry_id"
}

docker_login_private_registry() {
  local registry_user="${DAIANA_REGISTRY_USERNAME:-}"
  local registry_pat="${DAIANA_REGISTRY_PAT:-}"
  [ -n "$registry_user" ] || return 0
  [ -n "$registry_pat" ] || return 0

  log "Authenticating local Docker client to Docker Hub for private Daiana images"
  printf '%s' "$registry_pat" | docker_cmd login docker.io --username "$registry_user" --password-stdin >/dev/null
}

prepull_daiana_images() {
  log "Pre-pulling private Daiana images"
  docker_login_private_registry
  local args=()
  local file
  for file in "${APP_DEPLOY_COMPOSE_FILES[@]}"; do
    args+=( -f "$file" )
  done
  "${COMPOSE_CMD[@]}" "${args[@]}" pull
}

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

portainer_upsert_stack() {
  local stack_name="$1"
  local stack_env_json="$2"
  local stack_registries_json="${3:-}"
  shift 3
  local stack_file
  stack_file="$(mktemp)"
  render_compose "$stack_file" "$@"

  local body
  body="$(jq -Rs --arg name "$stack_name" --argjson env "$stack_env_json" --arg registries "$stack_registries_json" '
    {Name:$name, StackFileContent:., Env:$env}
    + (if $registries != "" then {Registries:$registries} else {} end)
  ' < "$stack_file")"
  local stack_id
  stack_id="$(portainer_stack_id "$stack_name" || true)"

  if [ -n "$stack_id" ] && [ "$stack_id" != "null" ]; then
    log "Updating Portainer stack: $stack_name (id=$stack_id)"
    portainer_request_json PUT "/api/stacks/$stack_id?endpointId=$PORTAINER_ENDPOINT_ID" "$body" >/dev/null
  else
    log "Creating Portainer stack: $stack_name"
    portainer_request_json POST "/api/stacks/create/standalone/string?endpointId=$PORTAINER_ENDPOINT_ID" "$body" >/dev/null
  fi

  rm -f "$stack_file"
}

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

  PORTAINER_TOKEN="$(portainer_token)"
  [ -n "$PORTAINER_TOKEN" ] || die "Could not authenticate to Portainer"
  PORTAINER_ENDPOINT_ID="$(portainer_ensure_endpoint)"
  [ -n "$PORTAINER_ENDPOINT_ID" ] || die "Could not determine Portainer endpoint id"
}

SUPABASE_COMPOSE_FILES=(docker-compose.yml)
APP_COMPOSE_FILES=(docker-compose.yml docker-compose.app.yml)
APP_DEPLOY_COMPOSE_FILES=("${APP_COMPOSE_FILES[@]}")
UPDATE_COMPOSE_OVERRIDE_FILE=""
UPDATE_HISTORY_DIR="${UPDATE_HISTORY_DIR:-./volumes/daiana/update-history}"
ROLLBACK_SNAPSHOT_DIR=""

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

postgres_connection_uri() {
  [ -n "${POOLER_TENANT_ID:-}" ] || die "POOLER_TENANT_ID is required to run init SQL"
  [ -n "${POSTGRES_PASSWORD:-}" ] || die "POSTGRES_PASSWORD is required to run init SQL"
  [ -n "${POSTGRES_PORT:-}" ] || die "POSTGRES_PORT is required to run init SQL"
  [ -n "${POSTGRES_DB:-}" ] || die "POSTGRES_DB is required to run init SQL"
  local host="${SUPABASE_DB_HOST:-supabase-pooler}"
  [ -n "$host" ] || die "Could not determine the Supabase DB host for init SQL"
  printf 'postgresql://postgres.%s:%s@%s:%s/%s' "$POOLER_TENANT_ID" "$POSTGRES_PASSWORD" "$host" "$POSTGRES_PORT" "$POSTGRES_DB"
}

psql_scalar() {
  local db_user="$1"
  local query="$2"
  local output
  if ! output="$(docker_cmd exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" supabase-db psql -h 127.0.0.1 -U "$db_user" -d "$POSTGRES_DB" -Atqc "$query" 2>&1)"; then
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
  local uri="$4"
  shift 4
  local tables=""
  local psql_vars=()

  command -v docker >/dev/null 2>&1 || die "docker is required to run Supabase init SQL"

  while [ "$#" -gt 0 ]; do
    psql_vars+=( -v "$1=$2" )
    shift 2
  done

  if [ "$schema" != "-" ] && [ -n "$schema" ]; then
    tables="$(docker_cmd exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" supabase-db psql -h 127.0.0.1 -U "$db_user" -d "$POSTGRES_DB" -Atqc "$(schema_tables_for_truncate_query "$schema")")"
    if [ -n "$tables" ]; then
      docker_cmd exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" supabase-db psql -h 127.0.0.1 -U "$db_user" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "TRUNCATE $tables RESTART IDENTITY CASCADE"
    fi
  fi
  if [ "${#psql_vars[@]}" -gt 0 ]; then
    docker_cmd exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" supabase-db psql -h 127.0.0.1 -U "$db_user" -d "$POSTGRES_DB" "${psql_vars[@]}" -v ON_ERROR_STOP=1 -f /dev/stdin < "$file"
  else
    docker_cmd exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" supabase-db psql -h 127.0.0.1 -U "$db_user" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /dev/stdin < "$file"
  fi
}

run_supabase_init_sql() {
  local sentinel=".atl/install-daiana.init-sql.done"
  local uri entry schema file
  if [ -f "$sentinel" ]; then
    log "Supabase data seed SQL already applied; skipping"
    return 0
  fi

  uri="$(postgres_connection_uri)"
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
        run_psql_file "$schema" "$db_user" "$file" "$uri" "${vault_psql_vars[@]}"
        ;;
      *)
        run_psql_file "$schema" "$db_user" "$file" "$uri"
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
- authenticate Portainer to the private Daiana image registry when needed
- wait for core Supabase to become healthy
- wait for Supabase Auth migrations to finish
- wait for PostgreSQL entrypoint structural init, then run post-start seeds: auth, public, studio, webui, vault
- verify/apply ordered Daiana database migrations before app deployment
- create/update Portainer stack: $APP_STACK_NAME from ${APP_COMPOSE_FILES[*]}
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
NPM_STACK_ENV_JSON="$(stack_env_json docker-compose.npm.yml)"
APP_STACK_ENV_JSON="$(stack_env_json "${APP_DEPLOY_COMPOSE_FILES[@]}")"

if [ "$ACTION" = "update" ]; then
  CURRENT_PHASE="validating current versions"
  report_daiana_versions
  CURRENT_PHASE="connecting to Portainer"
  wait_for_http "$PORTAINER_URL/api/status" "Portainer API" 180 2 || die "Portainer API did not become ready"
  PORTAINER_TOKEN="$(portainer_token)"
  [ -n "$PORTAINER_TOKEN" ] || die "Could not authenticate to Portainer"
  PORTAINER_ENDPOINT_ID="$(portainer_ensure_endpoint)"
  [ -n "$PORTAINER_ENDPOINT_ID" ] || die "Could not determine Portainer endpoint id"
  if [ "$ROLLBACK_MODE" = "1" ]; then
    log "Preparing private registry access for Daiana images"
    PORTAINER_DAIA_REGISTRIES_JSON="$(portainer_ensure_private_registry)"
    CURRENT_PHASE="pre-pulling rollback images"
    prepull_daiana_images || warn "Could not pre-pull rollback images; Portainer may still require registry access"
    log "Rolling back Daiana app stack via Portainer"
    portainer_upsert_stack "$APP_STACK_NAME" "$APP_STACK_ENV_JSON" "$PORTAINER_DAIA_REGISTRIES_JSON" "${APP_DEPLOY_COMPOSE_FILES[@]}"
    cat <<EOF

Rollback complete.
- Restored snapshot: ${ROLLBACK_SNAPSHOT_DIR:-unknown}
- Scope: compose/images only; databases, migrations, and volumes were not rolled back.
EOF
    exit 0
  fi
  CURRENT_PHASE="saving update rollback snapshot"
  save_update_snapshot
else
  CURRENT_PHASE="bootstrapping Portainer"
  ensure_network
  bootstrap_portainer
fi

log "Deploying NPM stack via Portainer"
portainer_upsert_stack "$NPM_STACK_NAME" "$NPM_STACK_ENV_JSON" "" docker-compose.npm.yml

if [ "$ACTION" = "install" ]; then
  log "Deploying core Supabase stack via Portainer"
  portainer_upsert_stack "$APP_STACK_NAME" "$APP_STACK_ENV_JSON" "" "${SUPABASE_COMPOSE_FILES[@]}"
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

log "Preparing private registry access for Daiana images"
PORTAINER_DAIA_REGISTRIES_JSON="$(portainer_ensure_private_registry)"

CURRENT_PHASE="pre-pulling Daiana images"
prepull_daiana_images || warn "Could not pre-pull Daiana images; Portainer may still require registry access"

log "Deploying Daiana app stack via Portainer"
portainer_upsert_stack "$APP_STACK_NAME" "$APP_STACK_ENV_JSON" "$PORTAINER_DAIA_REGISTRIES_JSON" "${APP_DEPLOY_COMPOSE_FILES[@]}"

log "Waiting for NPM API"
wait_for_http "$NPM_URL/api" "NPM API" 180 2 1 || die "NPM API did not become ready"

if [ "$ACTION" = "install" ]; then
  log "Creating proxy hosts without TLS"
  BASE_DOMAIN="$BASE_DOMAIN" NPM_ADMIN_EMAIL="$NPM_ADMIN_EMAIL" NPM_ADMIN_PASS="$NPM_ADMIN_PASS" \
  TLS_MODE=none ENSURE_PROXY_HOSTS=1 \
    bash utils/npm_ssl_bootstrap.sh

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
