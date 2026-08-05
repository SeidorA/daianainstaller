#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

for repo in daianamsteams daianastudio; do
  workflow="$ROOT_DIR/../$repo/.github/workflows/sha-candidate-image.yml"
  [ -f "$workflow" ] || fail "missing candidate workflow: $workflow"
  grep -Eq '^  workflow_dispatch:' "$workflow" || fail "$repo is not manual-only"
  grep -Eq 'IMAGE_NAME: cloudseidoranalytics/'"$repo"'$' "$workflow" || fail "$repo image repository is not approved"
  grep -Eq '^[[:space:]]+platforms: linux/amd64,linux/arm64$|platform: linux/amd64|platform: linux/arm64' "$workflow" || fail "$repo is not multi-arch"
  grep -Eq 'merge-base --is-ancestor.*origin/develop' "$workflow" || fail "$repo does not enforce develop ancestry"
  grep -Eq 'sha256:\[0-9a-f\]\{64\}' "$workflow" || fail "$repo does not validate digest references"
  grep -Eq 'org\.opencontainers\.image\.revision' "$workflow" || fail "$repo lacks source revision annotation"
  grep -Eq 'refusing to overwrite|Refusing to overwrite|already exists' "$workflow" || fail "$repo does not reject tag overwrite"
  if grep -Eq ':[[:space:]]*latest|:v?[0-9]+\.[0-9]+\.[0-9]+' "$workflow"; then
    fail "$repo candidate workflow contains a release/latest tag"
  fi
done
pass "Teams and Studio candidate workflows are source-bound and digest-authoritative"
