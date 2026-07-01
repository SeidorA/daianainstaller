#!/bin/sh
#
# Manage the self-hosted Supabase docker compose stack.
#
# Override files are layered via docker compose's native COMPOSE_FILE env
# var in .env. Format: colon-separated list with docker-compose.yml first.
#
# Examples in .env:
#   COMPOSE_FILE=docker-compose.yml
#   COMPOSE_FILE=docker-compose.yml:docker-compose.pg17.yml
#
# Preferred daily workflow: use the Makefile (`make up`, `make down`, `make bootstrap`).
# Manage compose overrides with: sh run.sh config add <name> | config remove <name>
# (accepts either a short name like 'pg17' or 'docker-compose.pg17.yml')
#
# Usage:
#   sh run.sh start                  # docker compose up -d --wait
#   (preferred daily workflow: use Makefile targets instead)
#   sh run.sh stop                   # docker compose down
#   sh run.sh restart [service]      # restart the stack (or named services)
#   sh run.sh restart --except <svc>...  # restart all services except the named ones
#   sh run.sh recreate [service]     # stop then start (or force-recreate one service)
#   sh run.sh recreate --except <svc>...  # force-recreate all services except the named ones
#   sh run.sh status                 # docker compose ps
#   sh run.sh logs [service]         # follow logs (all or one service)
#   sh run.sh inspect <service>      # docker inspect on a service's container
#   sh run.sh printenv <service>     # print a service's environment variables
#   sh run.sh pull                   # pull images
#   sh run.sh config                 # show the active COMPOSE_FILE list
#   sh run.sh config add <name>      # add an override to COMPOSE_FILE in .env
#   sh run.sh config remove <name>   # remove an override from COMPOSE_FILE in .env
#   sh run.sh compose-config         # dump fully-resolved docker compose config
#   sh run.sh secrets                # print key passwords and API keys from .env
#

set -e

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD="docker-compose"
else
    COMPOSE_CMD="docker compose"
fi

cd "$(dirname "$0")"

if [ ! -f docker-compose.yml ]; then
    echo "ERROR: docker-compose.yml not found in $(pwd)" >&2
    exit 1
fi

# Normalize an override argument:
#   pg17                       -> docker-compose.pg17.yml
#   docker-compose.pg17.yml    -> docker-compose.pg17.yml
#   ./docker-compose.pg17.yml  -> docker-compose.pg17.yml
#   docker-compose.yml         -> error (base file, always implicit)
normalize_override() {
    arg="${1#./}"
    case "$arg" in
        docker-compose.yml)
            echo "ERROR: docker-compose.yml is the base file, always included" >&2
            return 1
            ;;
        docker-compose.*.yml)
            echo "$arg"
            ;;
        *)
            echo "docker-compose.${arg}.yml"
            ;;
    esac
}

# Read COMPOSE_FILE from .env (stripping quotes and CR).
read_compose_file() {
    [ -f .env ] || return 0
    grep '^COMPOSE_FILE=' .env | head -n1 | cut -d= -f2- | tr -d "\r\"'"
}

# Pretty-print the effective compose file list.
print_config() {
    val="$1"
    [ -z "$val" ] && val="docker-compose.yml"
    echo "COMPOSE_FILE=$val"
    echo "compose files:"
    OLD_IFS=$IFS
    IFS=:
    for f in $val; do
        echo "  $f"
    done
    IFS=$OLD_IFS
    echo ""
}

# Update or append COMPOSE_FILE in .env.
write_compose_file() {
    new_value="$1"
    if [ ! -f .env ]; then
        echo "ERROR: .env not found in $(pwd)" >&2
        exit 1
    fi
    new_line="COMPOSE_FILE=$new_value"
    if grep -q '^COMPOSE_FILE=' .env; then
        sed -i.old -e "s|^COMPOSE_FILE=.*$|$new_line|" .env
        rm -f .env.old
    else
        cat >> .env <<EOF

############
# Docker compose override files to layer on top of docker-compose.yml.
# Colon-separated list. Manage with: sh run.sh config add|remove <name>.
#
# Examples:
#   COMPOSE_FILE=docker-compose.yml
#   COMPOSE_FILE=docker-compose.yml:docker-compose.pg17.yml
############
$new_line
EOF
    fi
}

# Echoes the list of services (one per line) minus those passed as args.
# Warns on unknown names; returns 1 if no services remain.
services_except() {
    all_services=$($COMPOSE_CMD config --services)
    filtered="$all_services"
    for ex in "$@"; do
        echo "$all_services" | grep -qFx "$ex" \
            || echo "Warning: '$ex' is not a service in this project" >&2
        filtered=$(echo "$filtered" | grep -vFx "$ex" || true)
    done
    if [ -z "$filtered" ]; then
        echo "No services left after applying --except" >&2
        return 1
    fi
    printf '%s\n' "$filtered"
}

CMD="${1:-help}"
[ "$#" -gt 0 ] && shift

case "$CMD" in
    start|up)
        exec $COMPOSE_CMD up -d --wait "$@"
        ;;
    stop|down)
        exec $COMPOSE_CMD down "$@"
        ;;
    restart)
        if [ "${1:-}" = "--except" ]; then
            shift
            [ $# -eq 0 ] && { echo "Usage: $(basename "$0") restart --except <svc>..." >&2; exit 1; }
            services=$(services_except "$@") || exit 1
            # shellcheck disable=SC2086
            exec $COMPOSE_CMD restart $services
        fi
        exec $COMPOSE_CMD restart "$@"
        ;;
    recreate)
        if [ "${1:-}" = "--except" ]; then
            shift
            [ $# -eq 0 ] && { echo "Usage: $(basename "$0") recreate --except <svc>..." >&2; exit 1; }
            services=$(services_except "$@") || exit 1
            # shellcheck disable=SC2086
            exec $COMPOSE_CMD up -d --wait --force-recreate --no-deps $services
        fi
        if [ $# -eq 0 ]; then
            $COMPOSE_CMD down
            exec $COMPOSE_CMD up -d --wait
        fi
        # Single-service recreate: force-recreate the named services only,
        # leave their dependencies running.
        exec $COMPOSE_CMD up -d --wait --force-recreate --no-deps "$@"
        ;;
    status|ps)
        exec $COMPOSE_CMD ps "$@"
        ;;
    logs)
        exec $COMPOSE_CMD logs -f "$@"
        ;;
    inspect)
        [ $# -eq 0 ] && { echo "Usage: $(basename "$0") inspect <service> [docker-inspect-args]" >&2; exit 1; }
        svc="$1"; shift
        cid=$($COMPOSE_CMD ps -q "$svc")
        [ -z "$cid" ] && { echo "Service '$svc' is not running" >&2; exit 1; }
        exec docker inspect "$cid" "$@"
        ;;
    printenv)
        [ $# -eq 0 ] && { echo "Usage: $(basename "$0") printenv <service>" >&2; exit 1; }
        svc="$1"
        cid=$($COMPOSE_CMD ps -q "$svc")
        [ -z "$cid" ] && { echo "Service '$svc' is not running" >&2; exit 1; }
        exec docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$cid"
        ;;
    pull)
        exec $COMPOSE_CMD pull "$@"
        ;;
    compose-config)
        exec $COMPOSE_CMD config "$@"
        ;;
    config)
        sub="${1:-show}"
        [ "$#" -gt 0 ] && shift
        current=$(read_compose_file)
        case "$sub" in
            show)
                print_config "$current"
                ;;
            add)
                [ $# -eq 0 ] && { echo "Usage: $(basename "$0") config add <name>..." >&2; exit 1; }
                new_value="${current:-docker-compose.yml}"
                changed=false
                for arg in "$@"; do
                    file=$(normalize_override "$arg") || exit 1
                    if [ ! -f "$file" ]; then
                        echo "ERROR: $file not found" >&2
                        exit 1
                    fi
                    case ":$new_value:" in
                        *":$file:"*) echo "Already present: $file" ;;
                        *) new_value="$new_value:$file"; changed=true ;;
                    esac
                done
                [ "$changed" = true ] && write_compose_file "$new_value"
                print_config "$new_value"
                ;;
            remove|rm)
                [ $# -eq 0 ] && { echo "Usage: $(basename "$0") config remove <name>..." >&2; exit 1; }
                new_value="${current:-docker-compose.yml}"
                changed=false
                for arg in "$@"; do
                    file=$(normalize_override "$arg") || exit 1
                    case ":$new_value:" in
                        *":$file:"*)
                            # Drop $file by rebuilding the colon list
                            tmp=""
                            OLD_IFS=$IFS
                            IFS=:
                            for tok in $new_value; do
                                [ "$tok" = "$file" ] || tmp="${tmp:+$tmp:}$tok"
                            done
                            IFS=$OLD_IFS
                            new_value="$tmp"
                            changed=true
                            ;;
                        *)  echo "Not present: $file" ;;
                    esac
                done
                [ "$changed" = true ] && write_compose_file "$new_value"
                print_config "$new_value"
                ;;
            *)
                echo "Unknown config subcommand: $sub" >&2
                echo "Use: config | config add <name>... | config remove <name>..." >&2
                exit 1
                ;;
        esac
        ;;
        secrets)
            if [ ! -f .env ]; then
                echo "ERROR: .env not found in $(pwd)" >&2
                exit 1
            fi

            print_secret_group() {
                local title="$1"
                shift
                echo "[$title]"
                for var in "$@"; do
                    line=$(grep "^${var}=" .env | head -n1)
                    if [ -n "$line" ]; then
                        echo "$line"
                    else
                        echo "${var}="
                    fi
                done
                echo ""
            }

            print_secret_group "Supabase" \
                POSTGRES_PASSWORD DASHBOARD_PASSWORD \
                SUPABASE_PUBLISHABLE_KEY SUPABASE_SECRET_KEY \
                S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET

            print_secret_group "Nginx Proxy Manager" \
                NPM_ADMIN_EMAIL NPM_ADMIN_PASS

            print_secret_group "Portainer" \
                PORTAINER_ADMIN_USER PORTAINER_ADMIN_PASS
            ;;
        help|-h|--help)
        cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  start                 Start the stack (docker compose up -d --wait)
  stop                  Stop the stack (docker compose down)
  restart [service]     Restart the stack (or named services)
  restart --except <svc>...
                        Restart all services except the named ones
  recreate [service]    Stop then start, or force-recreate one service (--no-deps)
  recreate --except <svc>...
                        Force-recreate all services except the named ones (--no-deps)
  status                Show service status
  logs [service]        Follow logs (optionally for a single service)
  inspect <service>     Inspect a service's container (forwards extra args to docker inspect)
  printenv <service>    Print a service's environment variables (one per line)
  pull                  Pull all images
  config                Show the active COMPOSE_FILE list
  config add <name>     Add an override to COMPOSE_FILE in .env (short name or full filename)
  config remove <name>  Remove an override from COMPOSE_FILE in .env
  compose-config        Dump the fully-resolved docker compose config
  secrets               Show key passwords and API keys from .env

EOF
        ;;
    *)
        echo "Unknown command: $CMD" >&2
        echo "Run '$0 help' for usage." >&2
        exit 1
        ;;
esac
