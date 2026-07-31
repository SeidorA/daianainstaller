#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
harness="$ROOT_DIR/utils/private-chat-harness.sh"
front_repo="$TMP_DIR/front"
python_repo="$TMP_DIR/python"
msteams_repo="$TMP_DIR/msteams"
studio_repo="$TMP_DIR/studio"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name harness-test
  : > "$repo/file"
  git -C "$repo" add file
  git -C "$repo" commit -q -m initial
  git -C "$repo" branch -M develop
  git -C "$repo" rev-parse develop
}

front_sha="$(make_repo "$front_repo")"
python_sha="$(make_repo "$python_repo")"
msteams_sha="$(make_repo "$msteams_repo")"
studio_sha="$(make_repo "$studio_repo")"
git -C "$studio_repo" checkout -q -b feat/daiana-313
printf 'studio quota baseline\n' > "$studio_repo/file"
git -C "$studio_repo" add file
git -C "$studio_repo" commit -q -m 'studio quota baseline'
studio_sha="$(git -C "$studio_repo" rev-parse feat/daiana-313)"
normal_next="cloudseidoranalytics/daiana:sha-$front_sha"
normal_python="cloudseidoranalytics/daianapython:sha-$python_sha"
normal_msteams="cloudseidoranalytics/daianamsteams:sha-$msteams_sha"
normal_studio="cloudseidoranalytics/daianastudio:sha-$studio_sha"
local_guard=(DAIANA_HARNESS_MODE=local-candidate DAIANA_HARNESS_OPERATION=candidate DAIANA_DEPLOYMENT_MODE=local-candidate DAIANA_HARNESS_NO_PUSH=1 DAIANA_HARNESS_NO_PUBLICATION=1 DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1)
normal_env=(DAIANA_FRONT_REPO="$front_repo" DAIANA_PYTHON_REPO="$python_repo" DAIANA_MSTEAMS_REPO="$msteams_repo" DAIANA_STUDIO_REPO="$studio_repo" DAIANA_CANDIDATE_NEXT_IMAGE="$normal_next" DAIANA_CANDIDATE_PYTHON_IMAGE="$normal_python" DAIANA_CANDIDATE_MSTEAMS_IMAGE="$normal_msteams" DAIANA_CANDIDATE_STUDIO_IMAGE="$normal_studio" "${local_guard[@]}")
env "${normal_env[@]}" bash "$harness" validate-source-refs >/dev/null || fail "normal ancestry path rejected"
pass "normal ancestry uses Front, Python, and Teams develop plus Studio feat/daiana-313"

approved_next='cloudseidoranalytics/daiana:sha-90bd701c3eec30f7d3b56fb230050f7e46fd98bf'
approved_python='cloudseidoranalytics/daianapython:sha-3ebc16d029b06efd2a0cd6b02980c45324948150'
approved_msteams='cloudseidoranalytics/daianamsteams:sha-c31a2262eb5720707861ac79a8d4cd55311c730e'
approved_studio='cloudseidoranalytics/daianastudio:sha-ed872073e7f359e7b8c88c6c2a26f55c46582c69'
approved_env=(DAIANA_FRONT_REPO="$ROOT_DIR/../daiananext" DAIANA_PYTHON_REPO="$ROOT_DIR/../daianapython" DAIANA_MSTEAMS_REPO="$ROOT_DIR/../daianamsteams" DAIANA_STUDIO_REPO="$ROOT_DIR/../daianastudio" DAIANA_CANDIDATE_NEXT_IMAGE="$approved_next" DAIANA_CANDIDATE_PYTHON_IMAGE="$approved_python" DAIANA_CANDIDATE_MSTEAMS_IMAGE="$approved_msteams" DAIANA_CANDIDATE_STUDIO_IMAGE="$approved_studio" DAIANA_APPROVED_NEXT_SOURCE_SHA=90bd701c3eec30f7d3b56fb230050f7e46fd98bf DAIANA_APPROVED_PYTHON_SOURCE_SHA=3ebc16d029b06efd2a0cd6b02980c45324948150 DAIANA_APPROVED_MSTEAMS_SOURCE_SHA=c31a2262eb5720707861ac79a8d4cd55311c730e DAIANA_APPROVED_STUDIO_SOURCE_SHA=ed872073e7f359e7b8c88c6c2a26f55c46582c69)
local_guard=(ALLOW_LOCAL_FEATURE_REFS=1 "${local_guard[@]}")
env "${approved_env[@]}" "${local_guard[@]}" bash "$harness" validate-source-refs >/dev/null || fail "approved refs with opt-in rejected"
pass "exact approved full SHAs pass only with local opt-in and guards"

expect_reject() {
  if env "$@" bash "$harness" validate-source-refs >/dev/null 2>&1; then fail "invalid source-ref case was accepted"; fi
}

expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_CANDIDATE_NEXT_IMAGE='local/daiana-next:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_CANDIDATE_NEXT_IMAGE='local/daiana-next:sha-90bd701'
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_CANDIDATE_NEXT_IMAGE='cloudseidoranalytics/daiananext:sha-90bd701c3eec30f7d3b56fb230050f7e46fd98bf'
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_CANDIDATE_PYTHON_IMAGE='cloudseidoranalytics/daianapython:sha-90bd701c3eec30f7d3b56fb230050f7e46fd98bf'
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_APPROVED_PYTHON_SOURCE_SHA=90bd701c3eec30f7d3b56fb230050f7e46fd98bf
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_APPROVED_STUDIO_SOURCE_SHA=90bd701c3eec30f7d3b56fb230050f7e46fd98bf
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_CANDIDATE_NEXT_IMAGE='attacker/daiana:sha-90bd701c3eec30f7d3b56fb230050f7e46fd98bf'
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_CANDIDATE_MSTEAMS_IMAGE='cloudseidoranalytics/daianamsteams:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' DAIANA_APPROVED_MSTEAMS_SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_APPROVED_MSTEAMS_SOURCE_SHA= DAIANA_APPROVED_STUDIO_SOURCE_SHA=
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_APPROVED_PYTHON_SOURCE_SHA=
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_APPROVED_STUDIO_SOURCE_SHA=
expect_reject "${approved_env[@]}" ALLOW_LOCAL_FEATURE_REFS=0 DAIANA_CANDIDATE_NEXT_IMAGE="$approved_next" DAIANA_CANDIDATE_PYTHON_IMAGE="$approved_python"
expect_reject "${approved_env[@]}" ALLOW_LOCAL_FEATURE_REFS=1 DAIANA_CANDIDATE_NEXT_IMAGE="$approved_next" DAIANA_CANDIDATE_PYTHON_IMAGE="$approved_python"
for guard in DAIANA_HARNESS_MODE DAIANA_HARNESS_OPERATION DAIANA_DEPLOYMENT_MODE DAIANA_HARNESS_NO_PUSH DAIANA_HARNESS_NO_PUBLICATION DAIANA_HARNESS_NO_REGISTRY_PUBLISH; do
  expect_reject "${approved_env[@]}" ALLOW_LOCAL_FEATURE_REFS=1 "${local_guard[@]}" "$guard="
done
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_MODE=production
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_DEPLOYMENT_MODE=production
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_OPERATION=release
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_OPERATION=publish
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_OPERATION=update
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_OPERATION=publication
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_DEPLOYMENT_MODE=production
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_NO_PUSH=0
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_NO_PUBLICATION=0
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_NO_REGISTRY_PUBLISH=0
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_PUSH=1
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_PUBLISH=1
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_HARNESS_REGISTRY_PUBLISH=1
expect_reject "${approved_env[@]}" "${local_guard[@]}" DAIANA_FEATURE_BASE_REF=attacker

attacker_repo="$TMP_DIR/attacker-base"
attacker_sha="$(make_repo "$attacker_repo")"
git -C "$attacker_repo" checkout -q -b attacker
printf 'attacker\n' > "$attacker_repo/file"
git -C "$attacker_repo" add file
git -C "$attacker_repo" commit -q -m attacker
attacker_sha="$(git -C "$attacker_repo" rev-parse HEAD)"
git -C "$attacker_repo" checkout -q develop
expect_reject DAIANA_FRONT_REPO="$attacker_repo" DAIANA_PYTHON_REPO="$python_repo" DAIANA_CANDIDATE_NEXT_IMAGE="cloudseidoranalytics/daiana:sha-$attacker_sha" DAIANA_CANDIDATE_PYTHON_IMAGE="$normal_python" "${local_guard[@]}" DAIANA_FEATURE_BASE_REF=attacker
if grep -Eq 'ALLOW_LOCAL_FEATURE_REFS|DAIANA_HARNESS_MODE' "$ROOT_DIR/utils/deployment-bundle.sh"; then fail "ordinary deployment bundle gained local exception controls"; fi
pass "wrong, short, missing-opt-in, release, update, publication, production, push, and publication-enabled paths fail closed"

printf 'private-chat source-ref exception tests passed\n'
