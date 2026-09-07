#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

compose_file="$ROOT_DIR/docker-compose.portainer.yml"
portainer_image="$(awk '
  /^  portainer:$/ { in_portainer=1; next }
  in_portainer && /^  [A-Za-z0-9_-]+:$/ { exit }
  in_portainer && $1 == "image:" { print $2; exit }
' "$compose_file")"

[[ "$portainer_image" == 'portainer/portainer-ce:2.45.0' ]] \
  || fail "Portainer image is not pinned to portainer/portainer-ce:2.45.0: $portainer_image"
! grep -Fq 'portainer/portainer-ce:lts' "$compose_file" \
  || fail 'Portainer floating lts tag is still present'
pass 'Portainer compose uses the stable 2.45.0 image pin'

printf 'Portainer image pin tests passed\n'
