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

for reference in 'repo/app:v1' "registry.example.com:5000/team/app@$digest_a" "repo/app:v1@$digest_a"; do
  validate_oci_reference "$reference" || fail "valid OCI reference rejected: $reference"
done
for reference in 'repo/app:bad tag' 'repo/app@sha256:abc' $'repo/app:v1\nservices:'; do
  if validate_oci_reference "$reference"; then fail "invalid OCI reference accepted"; fi
done
[[ "$(image_tag "registry.example.com:5000/team/app:v1@$digest_a")" = v1 ]] || fail "tag@digest parsing failed"
[[ -z "$(image_tag "registry.example.com:5000/team/app@$digest_a")" ]] || fail "registry port parsed as tag"
pass "OCI validation is single-line and digest-aware"

bundle="$TMP_DIR/bundle.json"
jq -n \
  --arg next "registry.example.com/next:v1@$digest_a" \
  --arg python "registry.example.com/python@$digest_b" \
  --arg studio "registry.example.com/studio:v2@$digest_c" \
  --arg da "$digest_a" --arg db "$digest_b" --arg dc "$digest_c" \
  --arg ca "$commit_a" --arg cb "$commit_b" --arg cc "$commit_c" \
  '{schema_version:1,deployment_mode:"complete-stack-replacement",images:{
    next:{reference:$next,index_digest:$da,source_commit:$ca},
    python:{reference:$python,index_digest:$db,source_commit:$cb},
    studio:{reference:$studio,index_digest:$dc,source_commit:$cc}}}' > "$bundle"

original="$(<"$bundle")"
load_deployment_bundle "$bundle" || fail "valid complete bundle rejected"
expected_hash="$(deployment_bundle_sha256 "$original")"
[[ "$BUNDLE_SHA256" = "$expected_hash" ]] || fail "captured bytes hash mismatch"
printf '{"schema_version":0}\n' > "$bundle"
override="$TMP_DIR/override.json"
write_deployment_bundle_override "$override"
[[ "$BUNDLE_SHA256" = "$expected_hash" ]] || fail "bundle hash changed after source mutation"
[[ "$(jq -r '.services.daiananext.image' "$override")" = "registry.example.com/next:v1@$digest_a" ]] || fail "captured Next ref changed"
[[ "$(jq -r '.services.daianapython.image' "$override")" = "registry.example.com/python@$digest_b" ]] || fail "captured Python ref changed"
[[ "$(jq -r '.services.daianastudio.image' "$override")" = "registry.example.com/studio:v2@$digest_c" ]] || fail "captured Studio ref changed"
[[ "$(jq '.services | length' "$override")" -eq 3 ]] || fail "override is not exactly three services"
pass "bundle is read once and emits one complete JSON override"

invalid="$TMP_DIR/invalid.json"
for filter in \
  'del(.images.python)' \
  '.images.next.source_commit = "1234"' \
  ".images.next.index_digest = \"$digest_b\"" \
  '.images.studio.reference = "registry.example.com/studio:v2"' \
  '.images.extra = .images.next'; do
  jq "$filter" <<<"$original" > "$invalid"
  document="$(<"$invalid")"
  if validate_deployment_bundle "$document"; then fail "invalid or partial bundle accepted: $filter"; fi
done
pass "partial, mutable, mismatched, and non-strict bundles fail closed"
if grep -Eq 'BUNDLE_SCOPE|rollout_order' "$ROOT_DIR/utils/deployment-bundle.sh" "$ROOT_DIR/install-daiana.sh" "$ROOT_DIR/docs/update.md"; then
  fail "obsolete partial scope or rollout contract remains"
fi
grep -q '^    image: cloudseidoranalytics/daiana:v2.1.9$' "$ROOT_DIR/docker-compose.app.yml" || fail "Next default pin changed"
grep -q '^    image: cloudseidoranalytics/daianapython:v2.1.9$' "$ROOT_DIR/docker-compose.app.yml" || fail "Python default pin changed"
grep -q '^    image: cloudseidoranalytics/daianastudio:v3.1.2$' "$ROOT_DIR/docker-compose.app.yml" || fail "Studio default pin changed"
pass "partial scopes are absent and default pins remain literal"

PULL_LOG=""
PULL_FAIL_IMAGE="$BUNDLE_NEXT_IMAGE"
docker_cmd() {
  PULL_LOG="${PULL_LOG}${2}\n"
  [ "$2" != "$PULL_FAIL_IMAGE" ]
}
PORTAINER_CALLED=0
prepull_deployment_bundle_images && PORTAINER_CALLED=1 || true
[[ "$PORTAINER_CALLED" -eq 0 ]] || fail "Portainer boundary crossed after pull failure"
[[ "$PULL_LOG" == *"$BUNDLE_PYTHON_IMAGE"*"$BUNDLE_NEXT_IMAGE"* ]] || fail "pull order incomplete"
[[ "$PULL_LOG" != *"$BUNDLE_STUDIO_IMAGE"* ]] || fail "pull continued after failure"
PULL_FAIL_IMAGE=""
PULL_LOG=""
prepull_deployment_bundle_images || fail "complete pre-pull failed"
[[ "$(printf '%b' "$PULL_LOG" | wc -l | tr -d ' ')" -eq 3 ]] || fail "not all three images were pulled"
pass "all three pulls are required before the Portainer boundary"
pull_line="$(grep -n '  prepull_deployment_bundle_images$' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
start_line="$(grep -n 'Complete deployment bundle replacement start' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
submit_line="$(grep -n '^portainer_upsert_stack .*APP_DEPLOY_COMPOSE_FILES' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
finish_line="$(grep -n 'Complete deployment bundle replacement finish' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
[[ "$pull_line" -lt "$start_line" && "$start_line" -lt "$submit_line" && "$submit_line" -lt "$finish_line" ]] \
  || fail "bundle start/finish do not bracket only the Portainer update"
pass "bundle boundary begins after pulls and finishes after submission"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  final_stack="$TMP_DIR/final-stack.yml"
  docker compose --env-file "$ROOT_DIR/.env.example" -f "$ROOT_DIR/docker-compose.yml" -f "$ROOT_DIR/docker-compose.app.yml" -f "$override" \
    config --no-interpolate > "$final_stack"
  images="$(docker compose --env-file "$ROOT_DIR/.env.example" -f "$final_stack" config --images)"
  for reference in "$BUNDLE_NEXT_IMAGE" "$BUNDLE_PYTHON_IMAGE" "$BUNDLE_STUDIO_IMAGE"; do
    grep -Fxq "$reference" <<<"$images" || fail "final stack omitted exact ref: $reference"
  done
  awk '/^portainer_submit_stack_file\(\)/,/^}/' "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/portainer-submit.sh"
  # shellcheck source=/dev/null
  source "$TMP_DIR/portainer-submit.sh"
  log() { :; }
  portainer_stack_id() { printf '7'; }
  portainer_request_json() { CAPTURED_PAYLOAD="$3"; }
  CAPTURED_PAYLOAD=""
  PORTAINER_ENDPOINT_ID=1 portainer_submit_stack_file daiana-app '[]' '[2]' "$final_stack"
  jq -jr '.StackFileContent' <<<"$CAPTURED_PAYLOAD" > "$TMP_DIR/submitted-stack.yml"
  cmp -s "$final_stack" "$TMP_DIR/submitted-stack.yml" || fail "Portainer payload changed stack bytes"
  for reference in "$BUNDLE_NEXT_IMAGE" "$BUNDLE_PYTHON_IMAGE" "$BUNDLE_STUDIO_IMAGE"; do
    grep -Fq "$reference" "$TMP_DIR/submitted-stack.yml" || fail "Portainer payload omitted exact ref"
  done
  cp "$final_stack" "$TMP_DIR/docker-compose.before.yml"
  CAPTURED_PAYLOAD=""
  DAIANA_NEXT_IMAGE=hostile DAIANA_PYTHON_IMAGE=hostile DAIANA_STUDIO_IMAGE=hostile \
    PORTAINER_ENDPOINT_ID=1 portainer_submit_stack_file daiana-app '[]' '[2]' "$TMP_DIR/docker-compose.before.yml"
  jq -jr '.StackFileContent' <<<"$CAPTURED_PAYLOAD" > "$TMP_DIR/rollback-submitted.yml"
  cmp -s "$TMP_DIR/docker-compose.before.yml" "$TMP_DIR/rollback-submitted.yml" || fail "rollback re-rendered stored stack"
  pass "submitted stack and rollback retain all exact literal refs"
else
  printf 'SKIP: Docker Compose unavailable\n'
fi
