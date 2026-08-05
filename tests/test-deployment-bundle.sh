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
digest_d="sha256:$(printf 'd%.0s' {1..64})"
commit_a="$(printf '1%.0s' {1..40})"
commit_b="$(printf '2%.0s' {1..40})"
commit_c="$(printf '3%.0s' {1..40})"
commit_d="$(printf '4%.0s' {1..40})"

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

qa_bundle="$TMP_DIR/qa-bundle.json"
jq -n \
  --arg next "registry.example.com/next@$digest_a" \
  --arg python "registry.example.com/python@$digest_b" \
  --arg msteams "registry.example.com/msteams@$digest_c" \
  --arg studio "registry.example.com/studio@$digest_d" \
  --arg da "$digest_a" --arg db "$digest_b" --arg dc "$digest_c" --arg dd "$digest_d" \
  --arg ca "$commit_a" --arg cb "$commit_b" --arg cc "$commit_c" --arg cd "$commit_d" \
  '{schema_version:2,deployment_mode:"complete-stack-replacement",images:{
    next:{reference:$next,index_digest:$da,source_commit:$ca},
    python:{reference:$python,index_digest:$db,source_commit:$cb},
    msteams:{reference:$msteams,index_digest:$dc,source_commit:$cc},
    studio:{reference:$studio,index_digest:$dd,source_commit:$cd}}}' > "$qa_bundle"
load_deployment_bundle "$ROOT_DIR/releases/qa-candidate.example.json" || fail "checked-in QA bundle example rejected"
[[ "$BUNDLE_MSTEAMS_IMAGE" == cloudseidoranalytics/daianamsteams@sha256:* ]] || fail "checked-in QA example omitted Teams"
load_deployment_bundle "$qa_bundle" || fail "valid four-image QA bundle rejected"
[[ "$BUNDLE_MSTEAMS_IMAGE" = "registry.example.com/msteams@$digest_c" ]] || fail "Teams reference was not captured"
write_deployment_bundle_override "$override"
[[ "$(jq '.services | length' "$override")" -eq 4 ]] || fail "QA override is not exactly four services"
[[ "$(jq -r '.services.daianamsteams.image' "$override")" = "registry.example.com/msteams@$digest_c" ]] || fail "Teams reference changed"
pass "four-image QA bundle includes digest-bound Teams provenance"

assert_checked_in_bundle() {
  local name="$1" file="$2" expected_hash="$3"
  local expected_next="$4" expected_python="$5" expected_studio="$6"
  local checked_override="$TMP_DIR/${name}.override.json"

  load_deployment_bundle "$file" || fail "$name bundle rejected"
  [[ "$BUNDLE_SHA256" = "$expected_hash" ]] || fail "$name bundle checksum mismatch"
  [[ "$BUNDLE_NEXT_IMAGE" = "$expected_next" ]] || fail "$name Next reference mismatch"
  [[ "$BUNDLE_PYTHON_IMAGE" = "$expected_python" ]] || fail "$name Python reference mismatch"
  [[ "$BUNDLE_STUDIO_IMAGE" = "$expected_studio" ]] || fail "$name Studio reference mismatch"
  jq -e '
    .schema_version == 1 and
    .deployment_mode == "complete-stack-replacement" and
    (.images | keys == ["next", "python", "studio"]) and
    ([.images[].reference] | all(test("@sha256:[0-9a-f]{64}$")))
  ' <<<"$BUNDLE_DOCUMENT" >/dev/null || fail "$name bundle contract mismatch"

  write_deployment_bundle_override "$checked_override"
  [[ "$(jq '.services | length' "$checked_override")" -eq 3 ]] || fail "$name override is incomplete"
  [[ "$(jq -r '.services.daiananext.image' "$checked_override")" = "$expected_next" ]] || fail "$name override changed Next"
  [[ "$(jq -r '.services.daianapython.image' "$checked_override")" = "$expected_python" ]] || fail "$name override changed Python"
  [[ "$(jq -r '.services.daianastudio.image' "$checked_override")" = "$expected_studio" ]] || fail "$name override changed Studio"
}

assert_checked_in_bundle \
  historical-candidate "$ROOT_DIR/releases/shared-message-quota.json" \
  b9d166f1a398f4a84588dc7b8a66c3e8d63de183416b7ef9a43916093495700b \
  cloudseidoranalytics/daiananext@sha256:3a4e41032300e57287b8b6a303a5b5639cd50430b6854942261e9d55dd6d440d \
  cloudseidoranalytics/daianapython@sha256:1a3ce01cec523cc648e0a440371f606a44505420cae06375cf7a660003267147 \
  cloudseidoranalytics/daianastudio@sha256:ffa2bcca921bb5a921cf61d6535ab197b74082052a9f2448585f6d5ff3840609
assert_checked_in_bundle \
  official-v2.2.0 "$ROOT_DIR/releases/v2.2.0.json" \
  4c8ac82c5b61ce8d83b293dbaac33060124231365a5bf1b4abfe9feff816154e \
  cloudseidoranalytics/daiana@sha256:9889e14b52230c52f428007ac52e665f695482caa993b2f2271eb7a06e46c173 \
  cloudseidoranalytics/daianapython@sha256:fe60febd128657e50ee9cd61bc848d7f05e3faf15cb605977d8c81946a3431b6 \
  cloudseidoranalytics/daianastudio@sha256:18a49d2177a8c648cc451043b554df1a66536f2acf268105e76dc0380d0a46a4
pass "historical candidate and official v2.2.0 bundles are exact, immutable, and complete"
load_deployment_bundle "$ROOT_DIR/releases/v2.2.0.json"
write_deployment_bundle_override "$override"

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

for filter in \
  'del(.images.msteams)' \
  '.images.msteams.source_commit = "1234"' \
  '.images.msteams.index_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
  '.images.msteams.reference = "registry.example.com/msteams:v1"' \
  '.images.extra = .images.msteams'; do
  jq "$filter" <<<"$(<"$qa_bundle")" > "$invalid"
  document="$(<"$invalid")"
  if validate_deployment_bundle "$document"; then fail "invalid four-image bundle accepted: $filter"; fi
done
pass "missing or invalid Teams image data fails closed"
if grep -Eq 'BUNDLE_SCOPE|rollout_order' "$ROOT_DIR/utils/deployment-bundle.sh" "$ROOT_DIR/install-daiana.sh" "$ROOT_DIR/docs/update.md"; then
  fail "obsolete partial scope or rollout contract remains"
fi
grep -q '^    image: cloudseidoranalytics/daiana:v2.1.9$' "$ROOT_DIR/docker-compose.app.yml" || fail "Next default pin changed"
grep -q '^    image: cloudseidoranalytics/daianapython:v2.1.9$' "$ROOT_DIR/docker-compose.app.yml" || fail "Python default pin changed"
grep -q '^    image: cloudseidoranalytics/daianastudio:v3.1.3$' "$ROOT_DIR/docker-compose.app.yml" || fail "Studio default pin changed"
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
[[ "$(printf '%b' "$PULL_LOG" | wc -l | tr -d ' ')" -eq 3 ]] || fail "backward-compatible bundle did not pull three images"
pass "historical three-image bundles retain their pull behavior"
load_deployment_bundle "$qa_bundle" || fail "QA bundle could not be reloaded"
write_deployment_bundle_override "$override"
PULL_LOG=""
prepull_deployment_bundle_images || fail "complete QA pre-pull failed"
[[ "$(printf '%b' "$PULL_LOG" | wc -l | tr -d ' ')" -eq 4 ]] || fail "not all four images were pulled"
pass "all four QA pulls are required before the Portainer boundary"
pull_line="$(grep -n '  prepull_deployment_bundle_images$' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
start_line="$(grep -n 'Complete deployment bundle replacement start' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
submit_line="$(grep -n 'portainer_upsert_stack_from_vars .*APP_DEPLOY_COMPOSE_FILES' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
finish_line="$(grep -n 'Complete deployment bundle replacement finish' "$ROOT_DIR/install-daiana.sh" | cut -d: -f1)"
[[ "$pull_line" -lt "$start_line" && "$start_line" -lt "$submit_line" && "$submit_line" -lt "$finish_line" ]] \
  || fail "bundle start/finish do not bracket only the Portainer update"
pass "bundle boundary begins after pulls and finishes after submission"

snapshot_env="$TMP_DIR/portainer-env.before.json"
printf '%s\n' '[{"name":"SECRET","value":"saved-value"}]' > "$snapshot_env"
saved_env="$(read_snapshot_env "$snapshot_env")" || fail "valid snapshot Env rejected"
printf '%s\n' '[{"name":"SECRET"}]' > "$snapshot_env"
if read_snapshot_env "$snapshot_env" >/dev/null 2>&1; then fail "malformed snapshot Env accepted"; fi
rm "$snapshot_env"
if read_snapshot_env "$snapshot_env" >/dev/null 2>&1; then fail "missing snapshot Env accepted"; fi
awk '/^CURRENT_PHASE="building stack envs"/,/^if \[ "\$ACTION" = "update" \]/' "$ROOT_DIR/install-daiana.sh" \
  | sed '$d' > "$TMP_DIR/build-stack-envs.sh"
stack_env_json() { fail "rollback read hostile current .env"; }
# shellcheck source=/dev/null
ROLLBACK_MODE=1 ROLLBACK_STACK_ENV_JSON="$saved_env" source "$TMP_DIR/build-stack-envs.sh"
[[ "$APP_STACK_ENV_JSON" = "$saved_env" ]] || fail "rollback changed saved Env"
pass "snapshot Env validation fails closed"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  final_stack="$TMP_DIR/final-stack.yml"
  docker compose --env-file "$ROOT_DIR/.env.example" -f "$ROOT_DIR/docker-compose.yml" -f "$ROOT_DIR/docker-compose.app.yml" -f "$override" \
    config --no-interpolate > "$final_stack"
  images="$(docker compose --env-file "$ROOT_DIR/.env.example" -f "$final_stack" config --images)"
  for reference in "$BUNDLE_NEXT_IMAGE" "$BUNDLE_PYTHON_IMAGE" "$BUNDLE_MSTEAMS_IMAGE" "$BUNDLE_STUDIO_IMAGE"; do
    grep -Fxq "$reference" <<<"$images" || fail "final stack omitted exact ref: $reference"
  done
  awk '/^portainer_temp_cleanup\(\)/,/^ensure_network\(\)/ { if ($0 !~ /^ensure_network\(\)/) print }' \
    "$ROOT_DIR/install-daiana.sh" > "$TMP_DIR/portainer-submit.sh"
  # shellcheck source=/dev/null
  source "$TMP_DIR/portainer-submit.sh"
  log() { :; }
  portainer_stack_id() { printf '7'; }
  CAPTURE_FILE="$TMP_DIR/captured.json"
  portainer_request_json_file() { cp "$3" "$CAPTURE_FILE"; }
  CAPTURED_PAYLOAD=""
  env_file="$TMP_DIR/env.json"
  registry_file="$TMP_DIR/registries.json"
  printf '%s' '[]' > "$env_file"
  printf '%s' '[2]' > "$registry_file"
  PORTAINER_ENDPOINT_ID=1 portainer_submit_stack_file daiana-app "$env_file" "$registry_file" "$final_stack"
  CAPTURED_PAYLOAD="$(<"$CAPTURE_FILE")"
  jq -jr '.StackFileContent' <<<"$CAPTURED_PAYLOAD" > "$TMP_DIR/submitted-stack.yml"
  cmp -s "$final_stack" "$TMP_DIR/submitted-stack.yml" || fail "Portainer payload changed stack bytes"
  for reference in "$BUNDLE_NEXT_IMAGE" "$BUNDLE_PYTHON_IMAGE" "$BUNDLE_MSTEAMS_IMAGE" "$BUNDLE_STUDIO_IMAGE"; do
    grep -Fq "$reference" "$TMP_DIR/submitted-stack.yml" || fail "Portainer payload omitted exact ref"
  done
  cp "$final_stack" "$TMP_DIR/docker-compose.before.yml"
  CAPTURED_PAYLOAD=""
  printf '%s' "$saved_env" > "$env_file"
  PORTAINER_ENDPOINT_ID=1 portainer_submit_stack_file daiana-app "$env_file" "$registry_file" "$TMP_DIR/docker-compose.before.yml"
  CAPTURED_PAYLOAD="$(<"$CAPTURE_FILE")"
  jq -jr '.StackFileContent' <<<"$CAPTURED_PAYLOAD" > "$TMP_DIR/rollback-submitted.yml"
  cmp -s "$TMP_DIR/docker-compose.before.yml" "$TMP_DIR/rollback-submitted.yml" || fail "rollback re-rendered stored stack"
  jq -e --argjson saved "$saved_env" '.Env == $saved' <<<"$CAPTURED_PAYLOAD" >/dev/null \
    || fail "rollback payload changed saved Env"
  pass "submitted stack and rollback retain exact stack and saved Env"
else
  printf 'SKIP: Docker Compose unavailable\n'
fi
