#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

# shellcheck source=utils/deployment-bundle.sh
source "$ROOT_DIR/utils/deployment-bundle.sh"

digest_a="sha256:$(printf 'a%.0s' {1..64})"
digest_b="sha256:$(printf 'b%.0s' {1..64})"
digest_c="sha256:$(printf 'c%.0s' {1..64})"
commit_a="$(printf '1%.0s' {1..40})"
commit_b="$(printf '2%.0s' {1..40})"
commit_c="$(printf '3%.0s' {1..40})"

for reference in \
  'registry.example.com/team/app:v1.2.3' \
  "registry.example.com:5000/team/app@$digest_a" \
  "registry.example.com/team/app:v1.2.3@$digest_a"; do
  validate_oci_reference "$reference" || fail "valid OCI reference rejected: $reference"
done
for reference in \
  'registry.example.com/team/app:bad tag' \
  'registry.example.com/team/app@sha256:abc' \
  'Registry.example.com/team/app:v1'; do
  if validate_oci_reference "$reference"; then
    fail "invalid OCI reference accepted: $reference"
  fi
done
[[ "$(image_tag "registry.example.com:5000/team/app:v1.2.3@$digest_a")" = v1.2.3 ]] || fail "tag@digest parsing corrupted the tag"
[[ -z "$(image_tag "registry.example.com:5000/team/app@$digest_a")" ]] || fail "registry port was parsed as a tag"
pass "OCI references preserve tags, registry ports, and digest suffixes"

bundle="$TMP_DIR/bundle.json"
jq -n \
  --arg next "registry.example.com/daiana/next:v1@$digest_a" \
  --arg python "registry.example.com/daiana/python@$digest_b" \
  --arg studio "registry.example.com/daiana/studio:v2@$digest_c" \
  --arg da "$digest_a" --arg db "$digest_b" --arg dc "$digest_c" \
  --arg ca "$commit_a" --arg cb "$commit_b" --arg cc "$commit_c" \
  '{schema_version:1, rollout_order:["daianapython","daiananext","daianastudio"], images:{
    next:{reference:$next,index_digest:$da,source_commit:$ca},
    python:{reference:$python,index_digest:$db,source_commit:$cb},
    studio:{reference:$studio,index_digest:$dc,source_commit:$cc}}}' > "$bundle"

validate_deployment_bundle "$bundle" || fail "valid bundle rejected"
DAIANA_BUNDLE_SCOPE=all load_deployment_bundle "$bundle"
override="$TMP_DIR/override.yml"
write_deployment_bundle_override "$override" all
grep -q "image: registry.example.com/daiana/next:v1@$digest_a" "$override" || fail "tag@digest was corrupted"
grep -q "image: registry.example.com/daiana/python@$digest_b" "$override" || fail "Python digest reference missing"
grep -q "image: registry.example.com/daiana/studio:v2@$digest_c" "$override" || fail "Studio digest reference missing"
pass "valid bundle renders complete full references"

write_deployment_bundle_override "$override" pair
grep -q '^  daiananext:' "$override" || fail "pair omitted Next"
grep -q '^  daianapython:' "$override" || fail "pair omitted Python"
if grep -q '^  daianastudio:' "$override"; then fail "pair unexpectedly included Studio"; fi
if DAIANA_BUNDLE_SCOPE=next load_deployment_bundle "$bundle"; then
  fail "partial pair scope accepted"
fi
pass "Next and Python are selectable only as one pair"

invalid="$TMP_DIR/invalid.json"
jq 'del(.images.python)' "$bundle" > "$invalid"
if validate_deployment_bundle "$invalid"; then fail "partial bundle accepted"; fi
jq '.images.next.source_commit = "1234"' "$bundle" > "$invalid"
if validate_deployment_bundle "$invalid"; then fail "invalid source SHA accepted"; fi
jq ".images.next.index_digest = \"$digest_b\"" "$bundle" > "$invalid"
if validate_deployment_bundle "$invalid"; then fail "mismatched index digest accepted"; fi
jq '.rollout_order = ["daiananext","daianapython","daianastudio"]' "$bundle" > "$invalid"
if validate_deployment_bundle "$invalid"; then fail "invalid rollout order accepted"; fi
pass "bundle validation fails closed on structure and provenance"

DAIANA_BUNDLE_SCOPE=all load_deployment_bundle "$bundle"
metadata="$(deployment_bundle_metadata_json)"
[[ "$(jq -r '.sha256' <<<"$metadata")" = "$BUNDLE_SHA256" ]] || fail "rollback metadata hash missing"
[[ "$(jq -r '.scope' <<<"$metadata")" = all ]] || fail "rollback metadata scope missing"
pass "rollback metadata identifies the selected bundle"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  DAIANA_NEXT_IMAGE="registry.example.com/daiana/next:v1@$digest_a" \
  DAIANA_PYTHON_IMAGE="registry.example.com/daiana/python@$digest_b" \
  DAIANA_STUDIO_IMAGE="registry.example.com/daiana/studio:v2@$digest_c" \
    docker compose -f "$ROOT_DIR/docker-compose.app.yml" config --images > "$TMP_DIR/compose-images.txt"
  grep -Fxq "registry.example.com/daiana/next:v1@$digest_a" "$TMP_DIR/compose-images.txt" || fail "Compose corrupted tag@digest"
  grep -Fxq "registry.example.com/daiana/python@$digest_b" "$TMP_DIR/compose-images.txt" || fail "Compose corrupted digest reference"
  pass "Compose interpolation preserves digest-bound references"
else
  printf 'SKIP: Docker Compose unavailable\n'
fi
