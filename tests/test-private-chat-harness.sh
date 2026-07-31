#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
harness="$ROOT_DIR/utils/private-chat-harness.sh"
override="$ROOT_DIR/docker-compose.private-chat-candidate.yml"
next_migration="$ROOT_DIR/volumes/db/daiana-migrations/20260727130000_add_history_message_refs.sql"
quota_migration="$ROOT_DIR/volumes/db/daiana-migrations/20260727140000_allow_authorized_private_message_quota.sql"
make_source_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name harness-test
  : > "$repo/source"
  git -C "$repo" add source
  git -C "$repo" commit -q -m initial
  git -C "$repo" branch -M develop
}
make_source_repo "$TMP_DIR/msteams"
make_source_repo "$TMP_DIR/studio"
next_image='cloudseidoranalytics/daiana:sha-90bd701c3eec30f7d3b56fb230050f7e46fd98bf'
python_image='cloudseidoranalytics/daianapython:sha-3ebc16d029b06efd2a0cd6b02980c45324948150'
msteams_image="cloudseidoranalytics/daianamsteams:sha-$(git -C "$TMP_DIR/msteams" rev-parse develop)"
studio_image="cloudseidoranalytics/daianastudio:sha-$(git -C "$TMP_DIR/studio" rev-parse develop)"
python_origin='http://api.192.168.0.19.nip.io'

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
wait_for_file() {
  local path="$1" attempt=0
  while [[ ! -e "$path" && "$attempt" -lt 500 ]]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  [[ -e "$path" ]] || fail "timed out waiting for synchronization marker: $path"
}

grep -q 'run_daiana_migrations' "$harness" || fail "harness does not use the Installer migration runner"
grep -q 'daiana_installer_schema_migrations' "$harness" || fail "harness does not verify the live Installer ledger"
grep -q 'RUNTIME_MUTATION_STARTED' "$harness" || fail "activation boundary is missing"
grep -q 'manual-cleanup-required' "$harness" || fail "manual cleanup marker is missing"
grep -q 'requested=.*observed=' "$harness" || fail "requested/observed image proof is missing"
grep -q 'migrations-applied.receipt' "$harness" || fail "durable migration receipt is missing"
grep -q 'forward_only=true' "$harness" || fail "forward-only migration state is missing"
grep -q 'require_exact_env_entry' "$harness" || fail "candidate environment assertions are not exact"
grep -q 'compose_environment_contract' "$harness" || fail "baseline Compose-explicit environment contract is missing"
grep -q 'image_environment_contract' "$harness" || fail "candidate image-default environment contract is missing"
grep -q 'candidate_next_image_id' "$harness" || fail "candidate image ID binding is missing"
for service_ref in DAIANA_CANDIDATE_MSTEAMS_IMAGE DAIANA_CANDIDATE_STUDIO_IMAGE candidate_msteams_image_id candidate_studio_image_id msteams_candidate_config_sha256 studio_candidate_config_sha256; do
  grep -q "$service_ref" "$harness" || fail "four-service receipt/config contract is missing: $service_ref"
done
pass "harness has staged receipts, compensation boundary, exact env checks, and image proof"

grep -q 'pull_policy: never' "$override" || fail "candidate override permits image pulling"
grep -q 'NODE_ENV: development' "$override" || fail "candidate is not development-only"
grep -q 'PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN: "true"' "$override" || fail "insecure origin guard is not explicit"
grep -q 'name: daiana-mgmt' "$override" || fail "candidate changed the required network"
grep -q 'external: true' "$override" || fail "candidate network is not external"
pass "candidate Compose override remains local-only"

for migration in "$next_migration" "$quota_migration"; do
  grep -q 'Provenance: daianapython commit 16e161f468f1976d15ba40b1312dc5f247d64dab' "$migration" || fail "migration provenance is missing"
  grep -q 'Canonical source SHA-256:' "$migration" || fail "migration source checksum is missing"
done

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
state_file="${FAKE_STATE:?}"
state=baseline
[[ -f "$state_file" ]] && state="$(cat "$state_file")"
printf '%s\n' "$*" >> "${DOCKER_LOG:?}"
case "${1:-}" in
  info) exit ;;
  network) exit ;;
  image)
     [[ "${2:-}" == inspect ]] || exit
      if [[ "${4:-}" == *'join .RepoDigests'* ]]; then
       if [[ "${4:-}" == '{{join .RepoDigests ","}}' ]]; then
         if [[ "${5:-}" == 'cloudseidoranalytics/daiana:v2.1.9' && "${FAKE_SCENARIO:-}" == baseline_image_digest_mutation && -e "$FAKE_STATE.restored" ]]; then
           printf 'cloudseidoranalytics/daiana@sha256:%064d\n' 9
         elif [[ "${5:-}" == 'cloudseidoranalytics/daiana:v2.1.9' ]]; then
           printf 'cloudseidoranalytics/daiana@sha256:%064d\n' 1
          elif [[ "${5:-}" == 'cloudseidoranalytics/daianapython:v2.1.9' ]]; then
            printf 'cloudseidoranalytics/daianapython@sha256:%064d\n' 2
          elif [[ "${5:-}" == 'cloudseidoranalytics/daianamsteams:v2.1.9' ]]; then
            printf 'cloudseidoranalytics/daianamsteams@sha256:%064d\n' 5
          elif [[ "${5:-}" == 'cloudseidoranalytics/daianastudio:v3.1.3' ]]; then
            printf 'cloudseidoranalytics/daianastudio@sha256:%064d\n' 6
         else
           printf 'cloudseidoranalytics/daiana@sha256:%064d\n' 3
         fi
       elif [[ "${FAKE_SCENARIO:-}" == runtime_digest_mismatch ]]; then
        if [[ "${5:-}" == *daiana-next* || "${5:-}" == *daiananext* ]]; then printf 'sha256:%064d|cloudseidoranalytics/daiana@sha256:%064d|arm64\n' 9 9
        elif [[ "${5:-}" == 'cloudseidoranalytics/daianamsteams:v2.1.9' ]]; then printf 'sha256:%064d|cloudseidoranalytics/daianamsteams@sha256:%064d|arm64\n' 5 5
        elif [[ "${5:-}" == 'cloudseidoranalytics/daianastudio:v3.1.3' ]]; then printf 'sha256:%064d|cloudseidoranalytics/daianastudio@sha256:%064d|arm64\n' 6 6
        else printf 'sha256:%064d|cloudseidoranalytics/daianapython@sha256:%064d|arm64\n' 2 2; fi
       elif [[ "${5:-}" == *'cloudseidoranalytics/daiana:sha-'* ]]; then
         [[ "${FAKE_SCENARIO:-}" == candidate_image_id_mismatch ]] && printf 'sha256:%064d|cloudseidoranalytics/daiana@sha256:%064d|arm64\n' 9 9 || printf 'sha256:%064d|cloudseidoranalytics/daiana@sha256:%064d|arm64\n' 3 3
        elif [[ "${5:-}" == *'cloudseidoranalytics/daianapython:sha-'* ]]; then
          printf 'sha256:%064d|cloudseidoranalytics/daianapython@sha256:%064d|arm64\n' 4 4
        elif [[ "${5:-}" == *'cloudseidoranalytics/daianamsteams:sha-'* ]]; then
          printf 'sha256:%064d|cloudseidoranalytics/daianamsteams@sha256:%064d|arm64\n' 7 7
        elif [[ "${5:-}" == *'cloudseidoranalytics/daianastudio:sha-'* ]]; then
          printf 'sha256:%064d|cloudseidoranalytics/daianastudio@sha256:%064d|arm64\n' 8 8
       elif [[ "${5:-}" == 'cloudseidoranalytics/daiana:v2.1.9' ]]; then
          [[ "${FAKE_SCENARIO:-}" == baseline_image_digest_mutation && -e "$FAKE_STATE.restored" ]] && printf 'sha256:%064d|cloudseidoranalytics/daiana@sha256:%064d|arm64\n' 1 9 || printf 'sha256:%064d|cloudseidoranalytics/daiana@sha256:%064d|arm64\n' 1 1
       else printf 'sha256:%064d|cloudseidoranalytics/daianapython@sha256:%064d|arm64\n' 2 2; fi
     elif [[ "${4:-}" == '{{json .Config.Env}}' ]]; then
       if [[ "${FAKE_SCENARIO:-}" == compose_image_default_env_omitted ]]; then
         printf '["IMAGE_DEFAULT=candidate-image"]\n'
       else
         printf '[]\n'
       fi
     else
       printf 'arm64\n'
    fi
    exit ;;
  container)
    container="${5:-}"
     if [[ "${4:-}" == '{{.Config.Image}}' ]]; then
       if [[ "$state" == candidate || "$state" == partial ]] && [[ "$container" == daiana-next ]]; then
         if [[ "${FAKE_SCENARIO:-}" == post_start || "${FAKE_SCENARIO:-}" == compensation_failure ]]; then printf 'local/wrong:sha-0000000000000000000000000000000000000000\n'
         elif [[ "${FAKE_SCENARIO:-}" == tag_retarget ]]; then printf 'cloudseidoranalytics/daiana:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
         else printf '%s\n' "${DAIANA_CANDIDATE_NEXT_IMAGE:?}"; fi
       elif [[ "$state" == candidate || "$state" == partial ]] && [[ "$container" == daiana-python ]]; then printf '%s\n' "${DAIANA_CANDIDATE_PYTHON_IMAGE:?}"
       elif [[ "$state" == candidate || "$state" == partial ]] && [[ "$container" == daiana-msteams ]]; then printf '%s\n' "${DAIANA_CANDIDATE_MSTEAMS_IMAGE:?}"
       elif [[ "$state" == candidate || "$state" == partial ]] && [[ "$container" == daiana-studio ]]; then printf '%s\n' "${DAIANA_CANDIDATE_STUDIO_IMAGE:?}"
       elif [[ "$container" == daiana-next ]]; then printf 'cloudseidoranalytics/daiana:v2.1.9\n'
       elif [[ "$container" == daiana-python ]]; then printf 'cloudseidoranalytics/daianapython:v2.1.9\n'
       elif [[ "$container" == daiana-msteams ]]; then printf 'cloudseidoranalytics/daianamsteams:v2.1.9\n'
       else printf 'cloudseidoranalytics/daianastudio:v3.1.3\n'; fi
    elif [[ "${4:-}" == *State.Status* ]]; then printf 'running\n'
    elif [[ "${4:-}" == *'range .Config.Env'* ]]; then
      if [[ "$state" == candidate || "$state" == partial ]]; then
            if [[ "${FAKE_SCENARIO:-}" == runtime_explicit_baseline_mutation ]]; then printf 'NODE_ENV=development\nUNRELATED_SETTING=mutated\nPRIVATE_CHAT_PYTHON_ORIGIN=%s\nPRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true\n' "${PRIVATE_CHAT_PYTHON_ORIGIN}"
          elif [[ "${FAKE_SCENARIO:-}" == env_mismatch ]]; then printf 'NODE_ENV=development-extra\nPRIVATE_CHAT_PYTHON_ORIGIN=%s\nPRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true\n' "${PRIVATE_CHAT_PYTHON_ORIGIN}"
        elif [[ "${FAKE_SCENARIO:-}" == env_duplicate_same || "${FAKE_SCENARIO:-}" == env_duplicate_conflict ]]; then
          printf 'NODE_ENV=development\n'
          [[ "${FAKE_SCENARIO:-}" == env_duplicate_conflict ]] && printf 'NODE_ENV=production\n' || printf 'NODE_ENV=development\n'
           printf 'PRIVATE_CHAT_PYTHON_ORIGIN=%s\nPRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true\n' "${PRIVATE_CHAT_PYTHON_ORIGIN}"
            elif [[ "$container" == daiana-msteams || "$container" == daiana-studio ]]; then
              [[ "${FAKE_SCENARIO:-}" == compose_image_default_env_omitted ]] && printf 'UNRELATED_SETTING=baseline\nIMAGE_DEFAULT=candidate-image\n' || printf 'UNRELATED_SETTING=baseline\n';
            elif [[ "${FAKE_SCENARIO:-}" == compose_image_default_env_omitted && "$container" != daiana-next ]]; then printf 'NODE_ENV=development\nUNRELATED_SETTING=baseline\nIMAGE_DEFAULT=candidate-image\nPRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true\n';
             elif [[ "$container" == daiana-next || "$container" == daiana-python ]]; then printf 'NODE_ENV=development\nUNRELATED_SETTING=baseline\n'; [[ "$container" == daiana-next ]] && printf 'PRIVATE_CHAT_PYTHON_ORIGIN=%s\n' "${PRIVATE_CHAT_PYTHON_ORIGIN}"; printf 'PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true\n';
            else printf 'NODE_ENV=development\nUNRELATED_SETTING=baseline\nPRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true\n'; fi
        else
           if [[ "$container" == daiana-msteams || "$container" == daiana-studio ]]; then printf 'UNRELATED_SETTING=baseline\nIMAGE_DEFAULT=baseline-image\n'
           elif [[ "${FAKE_SCENARIO:-}" == baseline_env_missing_python ]]; then
            if [[ "$container" == daiana-next ]]; then printf 'NODE_ENV=production\nUNRELATED_SETTING=baseline\n'; else printf 'UNRELATED_SETTING=baseline\n'; fi
          elif [[ "${FAKE_SCENARIO:-}" == baseline_env_wrong ]]; then
            printf 'NODE_ENV=development\nUNRELATED_SETTING=baseline\n'
          elif [[ "${FAKE_SCENARIO:-}" == baseline_env_malformed ]]; then
            printf 'NODE_ENV\nUNRELATED_SETTING=baseline\n'
          elif [[ "${FAKE_SCENARIO:-}" == baseline_env_conflict ]]; then
            printf 'NODE_ENV=development\nNODE_ENV=production\nPRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true\nPRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=false\n'
         elif [[ "${FAKE_SCENARIO:-}" == baseline_env_unexpected ]]; then
           printf 'NODE_ENV=production\nPRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=false\n'
         elif [[ "${FAKE_SCENARIO:-}" == baseline_env_mutation && -e "${FAKE_STATE}.env-mutated" ]]; then
           printf 'NODE_ENV=production\nUNRELATED_SETTING=mutated\n'
           elif [[ "${FAKE_SCENARIO:-}" == compose_image_default_env_omitted ]]; then printf 'NODE_ENV=production\nUNRELATED_SETTING=baseline\nIMAGE_DEFAULT=baseline-image\n'
          else printf 'NODE_ENV=production\nUNRELATED_SETTING=baseline\n'; fi
       fi
     elif [[ "${4:-}" == *Config.Env* ]]; then
         if [[ "$state" == candidate || "$state" == partial ]]; then
              if [[ "$container" == daiana-msteams || "$container" == daiana-studio ]]; then
                [[ "${FAKE_SCENARIO:-}" == compose_image_default_env_omitted ]] && printf '["UNRELATED_SETTING=baseline","IMAGE_DEFAULT=candidate-image"]\n' || printf '["UNRELATED_SETTING=baseline"]\n';
               elif [[ "${FAKE_SCENARIO:-}" == compose_image_default_env_omitted && "$container" != daiana-next ]]; then printf '["NODE_ENV=development","UNRELATED_SETTING=baseline","IMAGE_DEFAULT=candidate-image","PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true"]\n'
                elif [[ "$container" == daiana-next ]]; then printf '["NODE_ENV=development","UNRELATED_SETTING=baseline","PRIVATE_CHAT_PYTHON_ORIGIN=%s","PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true"]\n' "${PRIVATE_CHAT_PYTHON_ORIGIN}"
                elif [[ "$container" == daiana-python ]]; then printf '["NODE_ENV=development","UNRELATED_SETTING=baseline","PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true"]\n'
             else printf '["NODE_ENV=development","UNRELATED_SETTING=baseline","PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true"]\n'; fi
         elif [[ "$container" == daiana-msteams || "$container" == daiana-studio ]]; then printf '["UNRELATED_SETTING=baseline","IMAGE_DEFAULT=baseline-image"]\n'
         elif [[ "${FAKE_SCENARIO:-}" == baseline_env_missing_python && "$container" == daiana-python ]]; then printf '["UNRELATED_SETTING=baseline"]\n'
        elif [[ "${FAKE_SCENARIO:-}" == baseline_env_wrong ]]; then printf '["NODE_ENV=development","UNRELATED_SETTING=baseline"]\n'
        elif [[ "${FAKE_SCENARIO:-}" == baseline_env_malformed ]]; then printf '["NODE_ENV","UNRELATED_SETTING=baseline"]\n'
        elif [[ "${FAKE_SCENARIO:-}" == baseline_env_mutation && -e "${FAKE_STATE}.env-mutated" ]]; then printf '["NODE_ENV=production","UNRELATED_SETTING=mutated"]\n'
         elif [[ "${FAKE_SCENARIO:-}" == compose_image_default_env_omitted ]]; then printf '["NODE_ENV=production","UNRELATED_SETTING=baseline","IMAGE_DEFAULT=baseline-image"]\n'
        else printf '["NODE_ENV=production","UNRELATED_SETTING=baseline"]\n'; fi
      elif [[ "${4:-}" == *'{{.Image}}'* ]]; then
        if [[ "$state" == candidate || "$state" == partial ]]; then
          if [[ "$container" == daiana-next ]]; then
            [[ "${FAKE_SCENARIO:-}" == immutable_id_mismatch ]] && printf 'sha256:%064d\n' 9 || printf 'sha256:%064d\n' 3
           elif [[ "$container" == daiana-msteams ]]; then printf 'sha256:%064d\n' 7
           elif [[ "$container" == daiana-studio ]]; then printf 'sha256:%064d\n' 8
           else printf 'sha256:%064d\n' 4; fi
        elif [[ "$container" == daiana-next ]]; then
           [[ "${FAKE_SCENARIO:-}" == baseline_image_id_mutation && -e "$FAKE_STATE.restored" ]] && printf 'sha256:%064d\n' 9 || printf 'sha256:%064d\n' 1
         elif [[ "$container" == daiana-msteams ]]; then printf 'sha256:%064d\n' 5
         elif [[ "$container" == daiana-studio ]]; then printf 'sha256:%064d\n' 6
         else printf 'sha256:%064d\n' 2; fi
     elif [[ "${4:-}" == *'{{.Id}}'* ]]; then printf '%s-%s-id\n' "$state" "$container"
    elif [[ "${4:-}" == *'{{.Config.Image}}|'* ]]; then printf '%064d\n' 0
    else printf 'container-id\n'; fi
    exit ;;
  exec)
     if [[ -n "${DAIANA_HARNESS_TEST_MARKER_SEEN:-}" && -s "${DAIANA_HARNESS_STATE_DIR:-}/migrations-committed.receipt" ]]; then
       : > "$DAIANA_HARNESS_TEST_MARKER_SEEN"
     fi
       if [[ "${FAKE_SCENARIO:-}" == migration_transport_loss ]]; then
         printf 'connection reset by peer\n' >&2
         exit 125
       fi
       if [[ "${FAKE_SCENARIO:-}" == migration_arbitrary_nonzero ]]; then
         exit 23
       fi
       if [[ "${FAKE_SCENARIO:-}" == migration_sql_failure ]]; then
         printf 'ERROR: syntax error at or near "CREATE"\n' >&2
         exit 17
       fi
      if [[ "${FAKE_SCENARIO:-}" == kill_during_migration ]]; then
       : > "${FAKE_STATE}.migration-ready"
        attempt=0
        while [[ ! -e "${FAKE_STATE}.migration-stop" && "$attempt" -lt 500 ]]; do
          sleep 0.01
          attempt=$((attempt + 1))
        done
        [[ -e "${FAKE_STATE}.migration-stop" ]] || exit 124
     fi
     if [[ "$*" == *'count(*) = 2'* ]]; then
      printf 't\n20260727130000|add_history_message_refs|%s\n20260727140000|allow_authorized_private_message_quota|%s\n' "$(shasum -a 256 "$DAIANA_TEST_NEXT_MIGRATION" | cut -d ' ' -f 1)" "$(shasum -a 256 "$DAIANA_TEST_QUOTA_MIGRATION" | cut -d ' ' -f 1)"
    elif [[ "$*" == *to_regclass* ]]; then printf 't\nt\nt\n'
     else while IFS= read -r _; do :; done; fi
     exit ;;
   compose)
      [[ "${2:-}" == version ]] && exit
        if [[ "$*" == *'config --format json'* ]]; then
            if [[ "$*" == *'docker-compose.private-chat-candidate.yml'* && "$*" != *'docker-compose.app.yml'* ]]; then
          COMPOSE_CANDIDATE_RENDERED=yes python3 - <<'PY'
import json, os

scenario = os.environ.get("FAKE_SCENARIO", "")
next_image = os.environ["DAIANA_CANDIDATE_NEXT_IMAGE"]
python_image = os.environ["DAIANA_CANDIDATE_PYTHON_IMAGE"]
msteams_image = os.environ["DAIANA_CANDIDATE_MSTEAMS_IMAGE"]
studio_image = os.environ["DAIANA_CANDIDATE_STUDIO_IMAGE"]
services = {
    "daiananext": {"command": None, "entrypoint": None, "image": next_image, "pull_policy": "never", "environment": {"NODE_ENV": "development", "PRIVATE_CHAT_PYTHON_ORIGIN": os.environ["PRIVATE_CHAT_PYTHON_ORIGIN"], "PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN": "true"}, "networks": {"default": None}},
    "daianapython": {"command": None, "entrypoint": None, "image": python_image, "pull_policy": "never", "environment": {"NODE_ENV": "development", "PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN": "true"}, "networks": {"default": None}},
    "daianamsteams": {"command": None, "entrypoint": None, "image": msteams_image, "pull_policy": "never", "networks": {"default": None}},
    "daianastudio": {"command": None, "entrypoint": None, "image": studio_image, "pull_policy": "never", "networks": {"default": None}},
}
mutation = scenario.removeprefix("overlay_")
if mutation == "ports": services["daiananext"]["ports"] = ["8080:8080"]
elif mutation == "volumes": services["daiananext"]["volumes"] = ["./tmp:/tmp"]
elif mutation == "command": services["daiananext"]["command"] = ["sh", "-c", "true"]
elif mutation == "entrypoint": services["daianapython"]["entrypoint"] = ["sh"]
elif mutation == "depends_on": services["daiananext"]["depends_on"] = {"daianapython": {"condition": "service_started"}}
elif mutation == "extra_environment": services["daiananext"]["environment"]["UNAPPROVED"] = "value"
elif mutation == "third_service": services["unrelated"] = {"image": "local/unrelated"}
elif mutation == "wrong_top_level_key": pass
elif mutation == "extra_network": services["unrelated"] = {"name": "unrelated", "external": True}
elif mutation == "wrong_network": network_name = "wrong-network"
elif mutation == "wrong_image": services["daiananext"]["image"] = "cloudseidoranalytics/daiana:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
elif mutation == "wrong_pull_policy": services["daianapython"]["pull_policy"] = "always"
elif mutation == "origin_public_http": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://example.com"
elif mutation == "origin_public_nip_http": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://api.8.8.8.8.nip.io"
elif mutation == "origin_path": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://127.0.0.1:5002/path"
elif mutation == "origin_query": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://api.192.168.0.19.nip.io?x=1"
elif mutation == "origin_fragment": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://api.192.168.0.19.nip.io#fragment"
elif mutation == "origin_credentials": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://user@api.192.168.0.19.nip.io"
elif mutation == "origin_whitespace": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://api.192.168.0.19 .nip.io"
elif mutation == "origin_malformed_host": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://api..192.168.0.19.nip.io"
elif mutation == "origin_wrong_service_placement": services["daiananext"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = "http://192.168.0.19.api.nip.io"
elif mutation == "origin_python_service":
    services["daianapython"]["environment"]["PRIVATE_CHAT_PYTHON_ORIGIN"] = os.environ["PRIVATE_CHAT_PYTHON_ORIGIN"]
elif mutation in {"malicious_yaml_tag", "invalid_yaml"}: services["daiananext"]["invalid"] = True
else: network_name = "daiana-mgmt"
network_name = locals().get("network_name", "daiana-mgmt")
model = {"name": "daiana-app", "services": services, "networks": {"default": {"name": network_name, "external": True, "ipam": {}}}}
if mutation == "wrong_top_level_key": model["x-unapproved"] = True
print(json.dumps(model, separators=(",", ":")))
PY
            exit
          fi
          # This is a normalized full Installer model, including baseline
         # services and environment entries. Duplicate-key cases intentionally
         # remain raw JSON so the stdlib object-pairs hook can reject them.
          candidate_rendered=''
          [[ "$*" == *'docker-compose.private-chat-candidate.yml'* ]] && candidate_rendered=yes
          COMPOSE_CANDIDATE_RENDERED="$candidate_rendered" python3 - <<'PY'
import json, os

scenario = os.environ.get("FAKE_SCENARIO", "")
next_image = os.environ["DAIANA_CANDIDATE_NEXT_IMAGE"]
python_image = os.environ["DAIANA_CANDIDATE_PYTHON_IMAGE"]
msteams_image = os.environ["DAIANA_CANDIDATE_MSTEAMS_IMAGE"]
studio_image = os.environ["DAIANA_CANDIDATE_STUDIO_IMAGE"]
env_next = {"UNRELATED_SETTING": "baseline"}
env_python = dict(env_next)
if os.environ.get("COMPOSE_CANDIDATE_RENDERED") == "yes":
    env_next.update({"NODE_ENV": "development", "PRIVATE_CHAT_PYTHON_ORIGIN": os.environ["PRIVATE_CHAT_PYTHON_ORIGIN"], "PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN": "true"})
    env_python.update({"NODE_ENV": "development", "PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN": "true"})
if scenario == "compose_env_mismatch":
    env_python["NODE_ENV"] = "production"
if scenario == "compose_baseline_value_mutation" and os.environ.get("COMPOSE_CANDIDATE_RENDERED") == "yes":
    env_next["UNRELATED_SETTING"] = "altered"
model = {
    "name": "wrong-project" if scenario == "compose_wrong_project" else "daiana-app",
    "networks": {"default": {"name": "wrong-network" if scenario == "compose_wrong_network" else "daiana-mgmt", "ipam": {}, "external": True}},
    "services": {
    "studio": {"command": None, "entrypoint": None, "image": "supabase/studio:fixture", "networks": {"default": None}},
    "daianavanna": {"command": None, "entrypoint": None, "image": "cloudseidoranalytics/daianavanna:v2.1.9", "networks": {"default": None}},
    "daiananext": {"command": None, "entrypoint": None, "environment": env_next, "image": next_image, "pull_policy": "never", "networks": {"default": None}},
     "daianapython": {"command": None, "entrypoint": None, "environment": env_python, "image": python_image, "pull_policy": "never", "networks": {"default": None}},
     "daianamsteams": {"command": None, "entrypoint": None, "environment": {"UNRELATED_SETTING": "baseline"}, "image": msteams_image, "pull_policy": "never", "networks": {"default": None}},
     "daianastudio": {"command": None, "entrypoint": None, "environment": {"UNRELATED_SETTING": "baseline"}, "image": studio_image, "pull_policy": "never", "networks": {"default": None}},
    },
}
if scenario == "compose_image_mismatch":
    model["services"]["daiananext"]["image"] = "cloudseidoranalytics/daiana:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
if scenario == "compose_pull_policy_mismatch":
    model["services"]["daianapython"]["pull_policy"] = "always"
if scenario == "compose_missing_next":
    del model["services"]["daiananext"]
if scenario == "compose_missing_python":
    del model["services"]["daianapython"]
if scenario == "compose_wrong_service_scope":
    model["services"]["unrelated"] = {"image": "local/unrelated"}
if scenario in {"compose_duplicate_service", "compose_conflicting_service"}:
    python_service = json.dumps(model["services"]["daianapython"], separators=(",", ":"))
    print('{"name":"daiana-app","networks":{"default":{"name":"daiana-mgmt","ipam":{},"external":true}},"services":{"studio":{"image":"supabase/studio:fixture"},"daiananext":' + json.dumps(model["services"]["daiananext"], separators=(",", ":")) + ',"daianapython":' + python_service + ',"daianapython":' + (python_service if scenario == "compose_duplicate_service" else python_service.replace("development", "production")) + '}}')
elif scenario in {"compose_env_duplicate", "compose_env_duplicate_ordinary"}:
    next_env = '{"NODE_ENV":"development","UNRELATED_SETTING":"baseline","UNRELATED_SETTING":"altered","PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN":"true"}' if scenario == "compose_env_duplicate_ordinary" else '{"NODE_ENV":"development","NODE_ENV":"production","UNRELATED_SETTING":"baseline","PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN":"true"}'
    model["services"]["daiananext"]["environment"] = json.loads(next_env)
    raw = json.dumps(model, separators=(",", ":"))
    raw = raw.replace(json.dumps(model["services"]["daiananext"]["environment"], separators=(",", ":")), next_env, 1)
    print(raw)
else:
    print(json.dumps(model, separators=(",", ":")))
PY
         exit
       fi
        if [[ "$*" == *' config '* || "$*" == *' config' ]]; then
           exit
        fi
       if [[ "$*" == *docker-compose.private-chat-candidate.yml* ]]; then
       if [[ "${FAKE_SCENARIO:-}" == signal_cleanup ]]; then
         : > "${FAKE_STATE}.ready"
          attempt=0
          while [[ ! -e "${FAKE_STATE}.stop" && "$attempt" -lt 500 ]]; do
            sleep 0.01
            attempt=$((attempt + 1))
          done
          [[ -e "${FAKE_STATE}.stop" ]] || exit 124
       fi
      if [[ "${FAKE_SCENARIO:-}" == compose_partial ]]; then printf 'partial\n' > "$state_file"; exit 1; fi
      printf 'candidate\n' > "$state_file"
    else
      if [[ "${FAKE_SCENARIO:-}" == compensation_failure && "$state" != baseline ]]; then exit 1; fi
       [[ "${FAKE_SCENARIO:-}" != baseline_env_mutation ]] || : > "${FAKE_STATE}.env-mutated"
       : > "${FAKE_STATE}.restored"
      printf 'baseline\n' > "$state_file"
    fi
    exit ;;
  *) exit ;;
esac
DOCKER
chmod +x "$FAKE_BIN/docker"

run_case() {
  local scenario="$1" state_dir="$TMP_DIR/state-$1" rc
  mkdir -p "$state_dir"
  printf 'baseline\n' > "$TMP_DIR/docker-state-$scenario"
  : > "$TMP_DIR/docker-$scenario.log"
  export FAKE_SCENARIO="$scenario" FAKE_STATE="$TMP_DIR/docker-state-$scenario" DOCKER_LOG="$TMP_DIR/docker-$scenario.log"
    export DAIANA_HARNESS_STATE_DIR="$state_dir" DAIANA_FRONT_REPO="$ROOT_DIR/../daiananext" DAIANA_PYTHON_REPO="$ROOT_DIR/../daianapython" DAIANA_MSTEAMS_REPO="$ROOT_DIR/../daianamsteams" DAIANA_STUDIO_REPO="$ROOT_DIR/../daianastudio" DAIANA_CANDIDATE_NEXT_IMAGE="$next_image" DAIANA_CANDIDATE_PYTHON_IMAGE="$python_image" DAIANA_CANDIDATE_MSTEAMS_IMAGE=cloudseidoranalytics/daianamsteams:sha-c31a2262eb5720707861ac79a8d4cd55311c730e DAIANA_CANDIDATE_STUDIO_IMAGE=cloudseidoranalytics/daianastudio:sha-ed872073e7f359e7b8c88c6c2a26f55c46582c69 DAIANA_APPROVED_NEXT_SOURCE_SHA=90bd701c3eec30f7d3b56fb230050f7e46fd98bf DAIANA_APPROVED_PYTHON_SOURCE_SHA=3ebc16d029b06efd2a0cd6b02980c45324948150 DAIANA_APPROVED_MSTEAMS_SOURCE_SHA=c31a2262eb5720707861ac79a8d4cd55311c730e DAIANA_APPROVED_STUDIO_SOURCE_SHA=ed872073e7f359e7b8c88c6c2a26f55c46582c69 PRIVATE_CHAT_PYTHON_ORIGIN="$python_origin"
   export ALLOW_LOCAL_FEATURE_REFS=1 DAIANA_HARNESS_MODE=local-candidate DAIANA_HARNESS_OPERATION=candidate DAIANA_DEPLOYMENT_MODE=local-candidate DAIANA_HARNESS_NO_PUSH=1 DAIANA_HARNESS_NO_PUBLICATION=1 DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1
  export POSTGRES_PASSWORD=test-password POSTGRES_DB=postgres DAIANA_DB_CONTAINER=supabase-db
  export DAIANA_TEST_NEXT_MIGRATION="$next_migration" DAIANA_TEST_QUOTA_MIGRATION="$quota_migration"
      unset DAIANA_HARNESS_TEST_FAIL_RECEIPT_WRITE DAIANA_HARNESS_TEST_FAIL_RECEIPT_VALIDATION DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_WRITE DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_VALIDATION DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_RENAME DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_FSYNC DAIANA_HARNESS_TEST_FAIL_MIGRATION_COMMITMENT_WRITE DAIANA_HARNESS_TEST_FAIL_POST_MIGRATION DAIANA_HARNESS_TEST_SIGNAL_AFTER_MIGRATION DAIANA_HARNESS_TEST_TAMPER_STAGED_RECEIPT DAIANA_HARNESS_TEST_TAMPER_BASELINE_FINGERPRINT
   [[ "$scenario" != receipt_write ]] || export DAIANA_HARNESS_TEST_FAIL_RECEIPT_WRITE=yes
   [[ "$scenario" != receipt_validation ]] || export DAIANA_HARNESS_TEST_FAIL_RECEIPT_VALIDATION=yes
    [[ "$scenario" != migration_receipt_write ]] || export DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_WRITE=yes
    [[ "$scenario" != migration_receipt_validation ]] || export DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_VALIDATION=yes
      [[ "$scenario" != migration_commitment_write ]] || export DAIANA_HARNESS_TEST_FAIL_MIGRATION_COMMITMENT_WRITE=yes
      [[ "$scenario" != migration_receipt_rename ]] || export DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_RENAME=yes
      [[ "$scenario" != migration_receipt_fsync ]] || export DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_FSYNC=yes
     [[ "$scenario" != signal_during_migration ]] || export DAIANA_HARNESS_TEST_SIGNAL_AFTER_MIGRATION=yes
  set +e
   if [[ "$scenario" == signal_cleanup ]]; then
     DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null 2>&1 &
     child=$!
      wait_for_file "$FAKE_STATE.ready"
     : > "$FAKE_STATE.stop"
     kill -TERM "$child" 2>/dev/null || true
     wait "$child"
     rc=$?
  else
     DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate
    rc=$?
  fi
   set -e
    [[ "$rc" -ne 0 ]] || fail "$scenario was falsely accepted"
     if [[ "$scenario" == migration_transport_loss || "$scenario" == migration_arbitrary_nonzero ]]; then
      [[ -e "$state_dir/migrations-committed.receipt" ]] || fail "$scenario omitted unknown-outcome commitment"
      grep -q '^state=blocked$' "$state_dir/migrations-committed.receipt" || fail "$scenario did not retain blocked unknown outcome"
      grep -q 'never claim database rollback' "$state_dir/migrations-committed.receipt" || fail "$scenario claimed rollback"
       pass "$scenario retains an unknown, retry-blocked outcome"
       return
     fi
    if [[ "$scenario" == migration_sql_failure ]]; then
      [[ -e "$state_dir/migrations-committed.receipt" ]] || fail "$scenario omitted failed migration outcome"
      grep -q '^state=failed$' "$state_dir/migrations-committed.receipt" || fail "$scenario did not preserve known SQL failure as failed"
      pass "$scenario preserves a known SQL failure as failed"
      return
    fi
    if [[ "$scenario" == baseline_env_wrong || "$scenario" == baseline_env_malformed || "$scenario" == baseline_env_conflict || "$scenario" == baseline_env_unexpected ]]; then
     if grep -q ' exec ' "$TMP_DIR/docker-$scenario.log" || grep -q 'docker-compose.private-chat-candidate.yml.*up' "$TMP_DIR/docker-$scenario.log"; then
       fail "$scenario reached migration or candidate runtime mutation"
     fi
     pass "$scenario rejects protected baseline environment entries before mutation"
      return
    fi
        if [[ "$scenario" == compose_missing_next || "$scenario" == compose_missing_python || "$scenario" == compose_duplicate_service || "$scenario" == compose_conflicting_service || "$scenario" == compose_wrong_project || "$scenario" == compose_wrong_network || "$scenario" == compose_wrong_service_scope || "$scenario" == compose_env_mismatch || "$scenario" == compose_env_duplicate || "$scenario" == compose_env_duplicate_ordinary || "$scenario" == compose_baseline_value_mutation || "$scenario" == compose_image_mismatch || "$scenario" == compose_pull_policy_mismatch ]]; then
     if grep -q ' exec ' "$TMP_DIR/docker-$scenario.log" || grep -q 'docker-compose.private-chat-candidate.yml.*up' "$TMP_DIR/docker-$scenario.log"; then
       fail "$scenario reached migration or candidate runtime mutation"
     fi
     pass "$scenario rejects the rendered Compose environment before mutation"
     return
   fi
     if [[ "$scenario" != signal_during_migration && "$scenario" != migration_sql_failure ]]; then
      [[ -e "$state_dir/manual-cleanup-required" ]] || fail "$scenario did not retain manual cleanup marker"
    fi
     if [[ "$scenario" == migration_receipt_write || "$scenario" == migration_receipt_validation || "$scenario" == migration_receipt_rename || "$scenario" == migration_receipt_fsync ]]; then
      grep -q '^migration_130000_version=20260727130000$' "$state_dir/failure-diagnostics.txt" || fail "$scenario diagnostics omitted migration version"
      grep -q '^migration_130000_sha256=' "$state_dir/failure-diagnostics.txt" || fail "$scenario diagnostics omitted migration checksum"
    fi
    if [[ "$scenario" == migration_receipt_fsync ]]; then
      [[ -e "$state_dir/migrations-applied.receipt" ]] || fail "$scenario discarded the renamed receipt after fsync failure"
    fi
    if [[ "$scenario" != signal_during_migration && "$scenario" != migration_sql_failure ]]; then
      [[ -e "$state_dir/baseline.receipt" ]] || fail "$scenario did not retain baseline receipt"
    fi
     if [[ "$scenario" == migration_commitment_write ]]; then
       [[ -e "$state_dir/migrations-committed.receipt" ]] || fail "$scenario omitted failed migration-boundary evidence"
       grep -q '^state=blocked$' "$state_dir/migrations-committed.receipt" || fail "$scenario did not block retry after commitment failure"
      [[ -e "$state_dir/manual-cleanup-required" ]] || fail "$scenario omitted durable manual-recovery marker"
      if grep -q 'docker-compose.private-chat-candidate.yml.* up ' "$TMP_DIR/docker-$scenario.log"; then
        fail "$scenario reached candidate Compose mutation"
      fi
     elif [[ "$scenario" == signal_during_migration ]]; then
       [[ -e "$state_dir/migrations-committed.receipt" ]] || fail "$scenario omitted interrupted migration evidence"
       grep -q '^state=blocked$' "$state_dir/migrations-committed.receipt" || fail "$scenario did not record blocked unknown outcome"
     else
      [[ -e "$state_dir/migrations-committed.receipt" ]] || fail "$scenario did not retain migration commitment"
    fi
    if [[ "$scenario" != migration_receipt_write && "$scenario" != migration_receipt_rename && "$scenario" != migration_receipt_fsync && "$scenario" != migration_commitment_write && "$scenario" != signal_during_migration && "$scenario" != migration_sql_failure ]]; then
     [[ -e "$state_dir/migrations-applied.receipt" ]] || fail "$scenario did not retain migration receipt"
   fi
  [[ ! -e "$state_dir/active" ]] || fail "$scenario left a false active marker"
  if [[ "$scenario" != compensation_failure ]]; then
    [[ "$(cat "$TMP_DIR/docker-state-$scenario")" == baseline ]] || fail "$scenario did not restore baseline"
  fi
  pass "$scenario preserves the forward-only migration boundary"
}

run_success() {
  local state_dir="$TMP_DIR/state-success"
  mkdir -p "$state_dir"
  printf 'baseline\n' > "$TMP_DIR/docker-state-success"
  : > "$TMP_DIR/docker-success.log"
  : > "$TMP_DIR/durable-success.log"
    export FAKE_SCENARIO="${SUCCESS_SCENARIO:-none}" FAKE_STATE="$TMP_DIR/docker-state-success" DOCKER_LOG="$TMP_DIR/docker-success.log"
    export DAIANA_HARNESS_STATE_DIR="$state_dir" DAIANA_FRONT_REPO="$ROOT_DIR/../daiananext" DAIANA_PYTHON_REPO="$ROOT_DIR/../daianapython" DAIANA_MSTEAMS_REPO="$ROOT_DIR/../daianamsteams" DAIANA_STUDIO_REPO="$ROOT_DIR/../daianastudio" DAIANA_CANDIDATE_NEXT_IMAGE="$next_image" DAIANA_CANDIDATE_PYTHON_IMAGE="$python_image" DAIANA_CANDIDATE_MSTEAMS_IMAGE=cloudseidoranalytics/daianamsteams:sha-c31a2262eb5720707861ac79a8d4cd55311c730e DAIANA_CANDIDATE_STUDIO_IMAGE=cloudseidoranalytics/daianastudio:sha-ed872073e7f359e7b8c88c6c2a26f55c46582c69 DAIANA_APPROVED_NEXT_SOURCE_SHA=90bd701c3eec30f7d3b56fb230050f7e46fd98bf DAIANA_APPROVED_PYTHON_SOURCE_SHA=3ebc16d029b06efd2a0cd6b02980c45324948150 DAIANA_APPROVED_MSTEAMS_SOURCE_SHA=c31a2262eb5720707861ac79a8d4cd55311c730e DAIANA_APPROVED_STUDIO_SOURCE_SHA=ed872073e7f359e7b8c88c6c2a26f55c46582c69 PRIVATE_CHAT_PYTHON_ORIGIN="$python_origin"
   export ALLOW_LOCAL_FEATURE_REFS=1 DAIANA_HARNESS_MODE=local-candidate DAIANA_HARNESS_OPERATION=candidate DAIANA_DEPLOYMENT_MODE=local-candidate DAIANA_HARNESS_NO_PUSH=1 DAIANA_HARNESS_NO_PUBLICATION=1 DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1
  export POSTGRES_PASSWORD=test-password POSTGRES_DB=postgres DAIANA_DB_CONTAINER=supabase-db
  export DAIANA_TEST_NEXT_MIGRATION="$next_migration" DAIANA_TEST_QUOTA_MIGRATION="$quota_migration"
   export DAIANA_HARNESS_TEST_DURABLE_TRACE_FILE="$TMP_DIR/durable-success.log" DAIANA_COMPOSE_PROJECT_NAME=daiana-app
      DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate || fail "successful activation failed"
  [[ -e "$state_dir/active" && -s "$state_dir/active.receipt" ]] || fail "successful activation did not publish active receipt/marker"
   [[ -e "$state_dir/migrations-applied.receipt" ]] || fail "successful activation omitted migration receipt"
   grep -q '^compose_project=daiana-app$' "$state_dir/active.receipt" || fail "active receipt omitted fixed Compose project identity"
    grep -q '^mutation_services=daianapython,daiananext,daianamsteams,daianastudio$' "$state_dir/active.receipt" || fail "active receipt omitted mutation service scope"
  grep -q 'fsync-file-after-rename:' "$TMP_DIR/durable-success.log" || fail "successful activation omitted post-rename file fsync"
  grep -q 'fsync-directory-after-rename:' "$TMP_DIR/durable-success.log" || fail "successful activation omitted post-rename directory fsync"
  baseline_line="$(grep -n 'baseline.receipt' "$TMP_DIR/durable-success.log" | sed -n '1p' | cut -d: -f1)"
  active_line="$(grep -n 'active.receipt' "$TMP_DIR/durable-success.log" | sed -n '1p' | cut -d: -f1)"
  [[ -n "$baseline_line" && -n "$active_line" && "$baseline_line" -lt "$active_line" ]] || fail "baseline receipt was not durably published before active receipt"
  grep -q '^forward_only=true$' "$state_dir/migrations-applied.receipt" || fail "migration receipt omitted forward-only state"
   grep -q "candidate_next_image=$next_image" "$state_dir/active.receipt" || fail "active receipt omitted requested image"
    if [[ "$FAKE_SCENARIO" == baseline_env_missing_python ]]; then
      grep -q '^baseline_python_node_env_state=implicit-production$' "$state_dir/active.receipt" || fail "missing baseline NODE_ENV was not recorded as implicit production"
      grep -q '^baseline_python_env_keys=UNRELATED_SETTING$' "$state_dir/active.receipt" || fail "implicit baseline NODE_ENV was falsely added to the receipt key set"
    fi
    if [[ "$FAKE_SCENARIO" == compose_image_default_env_omitted ]]; then
       grep -q '^baseline_next_env_keys=IMAGE_DEFAULT,NODE_ENV,UNRELATED_SETTING$' "$state_dir/active.receipt" || fail "image-provided baseline environment key was not retained in the live contract"
       grep -q '^baseline_next_explicit_env_keys=UNRELATED_SETTING$' "$state_dir/active.receipt" || fail "Compose-explicit baseline keys were not distinguished from image defaults"
       grep -q '^baseline_next_explicit_env_contract=UNRELATED_SETTING|' "$state_dir/active.receipt" || fail "Compose-explicit baseline value contract was not recorded"
    fi
   [[ "$(grep '^candidate_next_image_id=' "$state_dir/active.receipt" | cut -d= -f2)" != "$(grep '^baseline_next_image_id=' "$state_dir/active.receipt" | cut -d= -f2)" ]] || fail "fake Docker masked candidate Next identity as baseline"
   [[ "$(grep '^candidate_python_image_id=' "$state_dir/active.receipt" | cut -d= -f2)" != "$(grep '^baseline_python_image_id=' "$state_dir/active.receipt" | cut -d= -f2)" ]] || fail "fake Docker masked candidate Python identity as baseline"
   DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" cleanup >/dev/null || fail "successful cleanup failed"
  [[ "$(cat "$TMP_DIR/docker-state-success")" == baseline ]] || fail "successful cleanup did not restore baseline"
  [[ ! -e "$state_dir/active" ]] || fail "successful cleanup retained active marker"
  [[ -e "$state_dir/migrations-applied.receipt" ]] || fail "successful cleanup discarded durable migration receipt"
pass "all four rendered candidate services preserve the exact development environment contract"
}

SUCCESS_SCENARIO=compose_image_default_env_omitted run_success
unset DAIANA_COMPOSE_PROJECT_NAME

run_rejected_project_override() {
  local project="$1" state_dir
  state_dir="$TMP_DIR/state-project-$project"
  mkdir -p "$state_dir"
  printf 'baseline\n' > "$TMP_DIR/docker-state-project-$project"
  : > "$TMP_DIR/docker-project-$project.log"
  export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-project-$project" DOCKER_LOG="$TMP_DIR/docker-project-$project.log"
  export DAIANA_HARNESS_STATE_DIR="$state_dir" DAIANA_CANDIDATE_NEXT_IMAGE="$next_image" DAIANA_CANDIDATE_PYTHON_IMAGE="$python_image"
  export ALLOW_LOCAL_FEATURE_REFS=1 DAIANA_HARNESS_MODE=local-candidate DAIANA_HARNESS_OPERATION=candidate DAIANA_DEPLOYMENT_MODE=local-candidate DAIANA_HARNESS_NO_PUSH=1 DAIANA_HARNESS_NO_PUBLICATION=1 DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1
  export POSTGRES_PASSWORD=test-password POSTGRES_DB=postgres DAIANA_DB_CONTAINER=supabase-db DAIANA_TEST_NEXT_MIGRATION="$next_migration" DAIANA_TEST_QUOTA_MIGRATION="$quota_migration"
  export DAIANA_COMPOSE_PROJECT_NAME="$project"
  if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null 2>&1; then
    fail "project override $project was accepted"
  fi
  [[ ! -s "$TMP_DIR/docker-project-$project.log" ]] || fail "project override $project reached Docker"
  pass "project override $project is rejected before mutation"
}

run_rejected_project_override supabase
run_rejected_project_override arbitrary-project
unset DAIANA_COMPOSE_PROJECT_NAME

run_case compose_env_mismatch
run_case compose_baseline_value_mutation
run_case compose_env_duplicate
run_case compose_missing_next
run_case compose_missing_python
run_case compose_duplicate_service
run_case compose_conflicting_service
run_case compose_wrong_project
run_case compose_wrong_network
run_case compose_image_mismatch
run_case compose_pull_policy_mismatch

cp "$override" "$TMP_DIR/candidate-overlay.original"

# The rendered model is allowed to contain the Installer's unrelated base
# services, but the candidate overlay itself remains closed-world.  Mutate each
# forbidden overlay field and prove validation rejects it before Docker is
# reached. Compose's normalized JSON plus the Python standard-library validator
# checks structure, not text indentation, so these cases guard against parser
# and interpolation-bypass regressions.
run_overlay_rejection() {
  local mutation="$1" state_dir log_file rc
  state_dir="$TMP_DIR/state-overlay-$mutation"
  log_file="$TMP_DIR/docker-overlay-$mutation.log"
  cp "$TMP_DIR/candidate-overlay.original" "$override"
  python3 - "$override" "$mutation" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
mutation = sys.argv[2]
contents = path.read_text()
mutations = {
    "ports": ("    pull_policy: never\n", "    pull_policy: never\n    ports:\n      - \"8080:8080\"\n", 1),
      "volumes": ("    pull_policy: never\n", "    pull_policy: never\n    volumes:\n      - ./tmp:/tmp\n", 1),
      "command": ("    pull_policy: never\n", "    pull_policy: never\n    command: [\"sh\", \"-c\", \"true\"]\n", 1),
      "entrypoint": ("    pull_policy: never\n", "    pull_policy: never\n    entrypoint: [\"sh\"]\n", 1),
    "depends_on": ("    pull_policy: never\n", "    pull_policy: never\n    depends_on:\n      daianapython:\n        condition: service_started\n", 1),
      "extra_environment": (
        "      PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN: \"true\"\n",
        "      PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN: \"true\"\n      UNAPPROVED: value\n",
        1,
    ),
     "third_service": (
         "\nnetworks:\n",
         "\n  unrelated:\n    image: local/unrelated\n\nnetworks:\n",
         1,
     ),
     "extra_network": (
         "\nnetworks:\n",
         "\n  unrelated:\n    name: unrelated\n    external: true\n\nnetworks:\n",
         1,
     ),
     "wrong_top_level_key": ("\nnetworks:\n", "\nx-unapproved: true\n\nnetworks:\n", 1),
     "wrong_network": ("    name: daiana-mgmt\n", "    name: wrong-network\n", 1),
     "wrong_image": ("    image: ${DAIANA_CANDIDATE_NEXT_IMAGE:?DAIANA_CANDIDATE_NEXT_IMAGE is required}\n", "    image: cloudseidoranalytics/daiana:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", 1),
      "wrong_pull_policy": ("    pull_policy: never\n", "    pull_policy: always\n", 1),
       "origin_public_http": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: http://example.com\n", 1),
       "origin_public_nip_http": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: http://api.8.8.8.8.nip.io\n", 1),
       "origin_path": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: http://127.0.0.1:5002/path\n", 1),
       "origin_query": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: http://api.192.168.0.19.nip.io?x=1\n", 1),
       "origin_fragment": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: 'http://api.192.168.0.19.nip.io#fragment'\n", 1),
       "origin_credentials": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: http://user@api.192.168.0.19.nip.io\n", 1),
       "origin_whitespace": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: 'http://api.192.168.0.19 .nip.io'\n", 1),
       "origin_malformed_host": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: http://api..192.168.0.19.nip.io\n", 1),
       "origin_wrong_service_placement": ("      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", "      PRIVATE_CHAT_PYTHON_ORIGIN: http://192.168.0.19.api.nip.io\n", 1),
      "origin_python_service": ("  daianapython:\n    image: ${DAIANA_CANDIDATE_PYTHON_IMAGE:?DAIANA_CANDIDATE_PYTHON_IMAGE is required}\n    pull_policy: never\n", "  daianapython:\n    image: ${DAIANA_CANDIDATE_PYTHON_IMAGE:?DAIANA_CANDIDATE_PYTHON_IMAGE is required}\n    pull_policy: never\n    environment:\n      PRIVATE_CHAT_PYTHON_ORIGIN: ${PRIVATE_CHAT_PYTHON_ORIGIN:?PRIVATE_CHAT_PYTHON_ORIGIN is required}\n", 1),
     "malicious_yaml_tag": ("services:\n", "services:\n  !!python/object/apply:os.system [\"echo pwned\"]\n", 1),
     "invalid_yaml": ("services:\n", "services:\n  invalid_yaml_marker: [\n", 1),
}
old, new, count = mutations[mutation]
if old not in contents:
    raise SystemExit(f"mutation did not apply: {mutation}")
contents = contents.replace(old, new, count)
path.write_text(contents)
PY
  mkdir -p "$state_dir"
  printf 'baseline\n' > "$TMP_DIR/docker-state-$mutation"
  : > "$log_file"
  export FAKE_SCENARIO="overlay_$mutation" FAKE_STATE="$TMP_DIR/docker-state-$mutation" DOCKER_LOG="$log_file" DAIANA_HARNESS_STATE_DIR="$state_dir"
  set +e
  DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" preflight >/dev/null 2>&1
  rc=$?
  set -e
  cp "$TMP_DIR/candidate-overlay.original" "$override"
  [[ "$rc" -ne 0 ]] || fail "candidate overlay mutation $mutation was accepted"
   if grep -Eq ' up | exec ' "$log_file"; then
     fail "candidate overlay mutation $mutation reached runtime mutation"
   fi
   grep -q 'config --format json' "$log_file" || fail "candidate overlay mutation $mutation skipped Compose JSON parsing"
   pass "candidate overlay rejects $mutation"
 }

 for overlay_mutation in \
   ports volumes command entrypoint depends_on extra_environment third_service extra_network \
    wrong_top_level_key wrong_network wrong_image wrong_pull_policy origin_public_http origin_public_nip_http origin_path origin_query origin_fragment origin_credentials origin_whitespace origin_malformed_host origin_wrong_service_placement origin_python_service malicious_yaml_tag invalid_yaml; do
  run_overlay_rejection "$overlay_mutation"
done

grep -q '^COMPOSE_PROJECT_NAME="daiana-app"$' "$harness" || fail "Compose project identity is still environment-overridable"
grep -q 'COMPOSE_MUTATION_SERVICES=(daianapython daiananext daianamsteams daianastudio)' "$harness" || fail "candidate mutation service scope is not fixed"
grep -q 'config --format json' "$harness" || fail "canonical rendered Compose JSON validation is missing"
grep -q 'object_pairs_hook' "$harness" || fail "duplicate JSON key rejection is missing"
pass "canonical full-model JSON validation and fixed mutation scope are present"

pass "realistic full-model Compose identity, image, pull-policy, and environment regressions are covered"

# A restored case can be retried immediately; an incomplete case must block a
# retry rather than silently starting another candidate.
export FAKE_SCENARIO=compose_partial FAKE_STATE="$TMP_DIR/docker-state-compose_partial" DOCKER_LOG="$TMP_DIR/docker-retry.log"
export DAIANA_HARNESS_STATE_DIR="$TMP_DIR/state-compose_partial"
if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null 2>&1; then fail "retry after post-migration failure was permitted"; fi
export FAKE_SCENARIO=compensation_failure FAKE_STATE="$TMP_DIR/docker-state-compensation_failure" DAIANA_HARNESS_STATE_DIR="$TMP_DIR/state-compensation_failure"
if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null 2>&1; then fail "retry after incomplete compensation was permitted"; fi
pass "retry policy blocks every post-migration failure"

runtime_mismatch_state="$TMP_DIR/state-runtime-mismatch"
mkdir -p "$runtime_mismatch_state"
printf 'baseline\n' > "$TMP_DIR/docker-state-runtime-mismatch"
: > "$TMP_DIR/docker-runtime-mismatch.log"
export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-runtime-mismatch" DOCKER_LOG="$TMP_DIR/docker-runtime-mismatch.log" DAIANA_HARNESS_STATE_DIR="$runtime_mismatch_state"
export DAIANA_COMPOSE_PROJECT_NAME=daiana-app
export DAIANA_HARNESS_REDACTION_SCRIPT="$ROOT_DIR/utils/private-chat-redaction.py"
: > "$TMP_DIR/durable-success.log"
unset DAIANA_HARNESS_TEST_DURABLE_TRACE_FILE
unset DAIANA_HARNESS_TEST_TAMPER_STAGED_RECEIPT DAIANA_HARNESS_TEST_TAMPER_BASELINE_FINGERPRINT DAIANA_HARNESS_TEST_SIGNAL_AFTER_MIGRATION DAIANA_HARNESS_TEST_FAIL_RECEIPT_WRITE DAIANA_HARNESS_TEST_FAIL_RECEIPT_VALIDATION DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_WRITE DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_VALIDATION DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_RENAME DAIANA_HARNESS_TEST_FAIL_MIGRATION_RECEIPT_FSYNC DAIANA_HARNESS_TEST_FAIL_MIGRATION_COMMITMENT_WRITE DAIANA_HARNESS_TEST_FAIL_MIGRATION_COMMITMENT_RENAME DAIANA_HARNESS_TEST_FAIL_MIGRATION_COMMITMENT_FSYNC DAIANA_HARNESS_TEST_FAIL_POST_MIGRATION DAIANA_HARNESS_TEST_MARKER_SEEN
FAKE_SCENARIO=none DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate || fail "runtime mismatch setup activation failed"
cp "$runtime_mismatch_state/active.receipt" "$TMP_DIR/original-active.receipt"
for mismatch_field in candidate_next_image_id candidate_next_repo_digest next_candidate_config_sha256; do
  before_cleanup_base_compose="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-runtime-mismatch.log")"
  tampered_receipt="$TMP_DIR/tampered-active.receipt"
  cp "$TMP_DIR/original-active.receipt" "$runtime_mismatch_state/active.receipt"
  awk -F= -v field="$mismatch_field" '{ if ($1 == field) print $1 "=tampered-value"; else print }' "$runtime_mismatch_state/active.receipt" > "$tampered_receipt"
  mv "$tampered_receipt" "$runtime_mismatch_state/active.receipt"
  if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" cleanup >/dev/null 2>&1; then fail "active receipt $mismatch_field mismatch was accepted"; fi
  [[ "$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-runtime-mismatch.log")" == "$before_cleanup_base_compose" ]] || fail "active receipt mismatch reached cleanup Compose mutation"
  [[ -e "$runtime_mismatch_state/failure-diagnostics.txt" ]] || fail "active receipt mismatch omitted diagnostics"
done
pass "active receipt image ID/digest and candidate fingerprint mismatches are rejected before cleanup mutation"

# The fake distinguishes the tag presented in Config.Image from the immutable
# image ID recorded in the running container. Both failures must stop before
# baseline Compose and retain the active/baseline evidence.
for runtime_identity_case in tag_retarget immutable_id_mismatch; do
  identity_state="$TMP_DIR/state-runtime-$runtime_identity_case"
  mkdir -p "$identity_state"
  printf 'baseline\n' > "$TMP_DIR/docker-state-runtime-$runtime_identity_case"
  : > "$TMP_DIR/docker-runtime-$runtime_identity_case.log"
  export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-runtime-$runtime_identity_case" DOCKER_LOG="$TMP_DIR/docker-runtime-$runtime_identity_case.log" DAIANA_HARNESS_STATE_DIR="$identity_state"
   unset DAIANA_HARNESS_TEST_DURABLE_TRACE_FILE DAIANA_HARNESS_TEST_TAMPER_STAGED_RECEIPT DAIANA_HARNESS_TEST_TAMPER_BASELINE_FINGERPRINT
     export FAKE_SCENARIO=none
       DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null || fail "$runtime_identity_case setup activation failed"
  before_identity_cleanup="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-runtime-$runtime_identity_case.log")"
  export FAKE_SCENARIO="$runtime_identity_case"
  if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" cleanup >/dev/null 2>&1; then
    fail "$runtime_identity_case was accepted during cleanup"
  fi
  after_identity_cleanup="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-runtime-$runtime_identity_case.log")"
  [[ "$after_identity_cleanup" == "$before_identity_cleanup" ]] || fail "$runtime_identity_case reached baseline Compose"
  [[ -e "$identity_state/baseline.receipt" && -e "$identity_state/active.receipt" && -e "$identity_state/active" ]] || fail "$runtime_identity_case discarded retained evidence"
  [[ -e "$identity_state/manual-cleanup-required" && -e "$identity_state/failure-diagnostics.txt" ]] || fail "$runtime_identity_case omitted retained failure markers"
done
pass "Config.Image tag retarget and immutable container Image ID mismatches retain receipts before cleanup"

# A redaction verifier failure is itself a cleanup failure. Evidence must stay
# in place and the failing redactor must not open the runtime mutation boundary.
redaction_failure_state="$TMP_DIR/state-redaction-failure"
mkdir -p "$redaction_failure_state"
printf 'baseline\n' > "$TMP_DIR/docker-state-redaction-failure"
: > "$TMP_DIR/docker-redaction-failure.log"
cat > "$TMP_DIR/failing-redactor.py" <<'PY'
#!/usr/bin/env python3
raise SystemExit(77)
PY
chmod +x "$TMP_DIR/failing-redactor.py"
export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-redaction-failure" DOCKER_LOG="$TMP_DIR/docker-redaction-failure.log" DAIANA_HARNESS_STATE_DIR="$redaction_failure_state" DAIANA_HARNESS_REDACTION_SCRIPT="$ROOT_DIR/utils/private-chat-redaction.py"
unset DAIANA_HARNESS_TEST_DURABLE_TRACE_FILE DAIANA_HARNESS_TEST_TAMPER_STAGED_RECEIPT DAIANA_HARNESS_TEST_TAMPER_BASELINE_FINGERPRINT
DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null || fail "redaction-failure setup activation failed"
before_redaction_cleanup="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-redaction-failure.log")"
export DAIANA_HARNESS_REDACTION_SCRIPT="$TMP_DIR/failing-redactor.py"
if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" cleanup >/dev/null 2>&1; then
  fail "redaction verifier failure was accepted"
fi
after_redaction_cleanup="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-redaction-failure.log")"
[[ "$after_redaction_cleanup" == "$before_redaction_cleanup" ]] || fail "redaction verifier failure reached baseline Compose"
[[ -e "$redaction_failure_state/baseline.receipt" && -e "$redaction_failure_state/active.receipt" && -e "$redaction_failure_state/active" ]] || fail "redaction verifier failure discarded receipts"
[[ -e "$redaction_failure_state/manual-cleanup-required" && -e "$redaction_failure_state/failure-diagnostics.txt" ]] || fail "redaction verifier failure omitted manual-cleanup diagnostics"
pass "redaction verifier failure is retained and retry-blocked before cleanup mutation"

source_guard_state="$TMP_DIR/state-cleanup-source-guard"
mkdir -p "$source_guard_state"
printf 'baseline\n' > "$TMP_DIR/docker-state-cleanup-source-guard"
: > "$TMP_DIR/docker-cleanup-source-guard.log"
export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-cleanup-source-guard" DOCKER_LOG="$TMP_DIR/docker-cleanup-source-guard.log" DAIANA_HARNESS_STATE_DIR="$source_guard_state"
export DAIANA_HARNESS_REDACTION_SCRIPT="$ROOT_DIR/utils/private-chat-redaction.py"
DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null || fail "cleanup source-guard setup activation failed"
   awk -F= '{ if ($1 == "candidate_next_image") print $1 "=cloudseidoranalytics/daiana:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; else print }' "$source_guard_state/active.receipt" > "$TMP_DIR/tampered-source.receipt"
mv "$TMP_DIR/tampered-source.receipt" "$source_guard_state/active.receipt"
before_source_guard_cleanup="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-cleanup-source-guard.log")"
if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" cleanup >/dev/null 2>&1; then fail "cleanup accepted a source-ref-tampered receipt"; fi
after_source_guard_cleanup="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-cleanup-source-guard.log")"
[[ "$after_source_guard_cleanup" == "$before_source_guard_cleanup" ]] || fail "source-ref-tampered receipt reached baseline cleanup Compose"
pass "cleanup re-runs source ancestry and rejects a tampered candidate image before restoration"

kill_state="$TMP_DIR/state-kill-during-migration"
mkdir -p "$kill_state"
printf 'baseline\n' > "$TMP_DIR/docker-state-kill-during-migration"
: > "$TMP_DIR/docker-kill-during-migration.log"
: > "$TMP_DIR/marker-seen"
export FAKE_SCENARIO=kill_during_migration FAKE_STATE="$TMP_DIR/docker-state-kill-during-migration" DOCKER_LOG="$TMP_DIR/docker-kill-during-migration.log" DAIANA_HARNESS_STATE_DIR="$kill_state" DAIANA_HARNESS_TEST_MARKER_SEEN="$TMP_DIR/marker-seen"
DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null 2>&1 &
kill_child=$!
  wait_for_file "$TMP_DIR/marker-seen"
  wait_for_file "$FAKE_STATE.migration-ready"
kill -KILL "$kill_child" 2>/dev/null || true
wait "$kill_child" 2>/dev/null || true
grep -q '^state=pending$' "$kill_state/migrations-committed.receipt" || fail "SIGKILL did not leave pending migration boundary evidence"
[[ ! -e "$kill_state/manual-cleanup-required" ]] || fail "SIGKILL unexpectedly claimed catchable cleanup evidence"
: > "$FAKE_STATE.migration-stop"
export FAKE_SCENARIO=none
if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null 2>&1; then fail "retry after unknown migration outcome was permitted"; fi
pass "pre-migration intent is durable and SIGKILL leaves an unknown, retry-blocking boundary"

digest_state="$TMP_DIR/state-runtime-digest-mismatch"
mkdir -p "$digest_state"
printf 'baseline\n' > "$TMP_DIR/docker-state-runtime-digest-mismatch"
: > "$TMP_DIR/docker-runtime-digest-mismatch.log"
export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-runtime-digest-mismatch" DOCKER_LOG="$TMP_DIR/docker-runtime-digest-mismatch.log" DAIANA_HARNESS_STATE_DIR="$digest_state"
export DAIANA_HARNESS_REDACTION_SCRIPT="$ROOT_DIR/utils/private-chat-redaction.py"
DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null || fail "runtime digest setup activation failed"
before_digest_cleanup_base_compose="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-runtime-digest-mismatch.log")"
export FAKE_SCENARIO=runtime_digest_mismatch
if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" cleanup >/dev/null 2>&1; then fail "observed runtime digest mismatch was accepted"; fi
[[ -e "$digest_state/manual-cleanup-required" ]] || fail "runtime digest mismatch omitted manual cleanup marker"
[[ -e "$digest_state/failure-diagnostics.txt" ]] || fail "runtime digest mismatch omitted diagnostics"
after_digest_cleanup_base_compose="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-runtime-digest-mismatch.log")"
[[ "$after_digest_cleanup_base_compose" == "$before_digest_cleanup_base_compose" ]] || fail "runtime digest mismatch reached baseline cleanup Compose"
pass "observed runtime digest mutation is rejected before cleanup"

for baseline_image_case in baseline_image_id_mutation baseline_image_digest_mutation; do
  image_state="$TMP_DIR/state-$baseline_image_case"
  mkdir -p "$image_state"
  printf 'baseline\n' > "$TMP_DIR/docker-state-$baseline_image_case"
  : > "$TMP_DIR/docker-$baseline_image_case.log"
  export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-$baseline_image_case" DOCKER_LOG="$TMP_DIR/docker-$baseline_image_case.log" DAIANA_HARNESS_STATE_DIR="$image_state"
  DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null || fail "$baseline_image_case setup activation failed"
  before_baseline_image_cleanup="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-$baseline_image_case.log")"
  export FAKE_SCENARIO="$baseline_image_case"
  if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" cleanup >/dev/null 2>&1; then fail "$baseline_image_case was accepted"; fi
  after_baseline_image_cleanup="$(awk '$0 ~ /compose/ && $0 !~ /private-chat-candidate/ { count++ } END { print count + 0 }' "$TMP_DIR/docker-$baseline_image_case.log")"
  [[ "$after_baseline_image_cleanup" -gt "$before_baseline_image_cleanup" ]] || fail "$baseline_image_case did not reach baseline cleanup Compose for post-restore verification"
  [[ -e "$image_state/manual-cleanup-required" && -e "$image_state/active" ]] || fail "$baseline_image_case did not retain manual-cleanup diagnostics"
done
pass "baseline image ID and content digest mutations are rejected after rollback verification"

env_mutation_state="$TMP_DIR/state-baseline-env-mutation"
mkdir -p "$env_mutation_state"
printf 'baseline\n' > "$TMP_DIR/docker-state-baseline-env-mutation"
: > "$TMP_DIR/docker-baseline-env-mutation.log"
export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-baseline-env-mutation" DOCKER_LOG="$TMP_DIR/docker-baseline-env-mutation.log" DAIANA_HARNESS_STATE_DIR="$env_mutation_state"
DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null || fail "environment mutation setup activation failed"
export FAKE_SCENARIO=baseline_env_mutation
if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" cleanup >/dev/null 2>&1; then fail "unrelated environment mutation was accepted during rollback"; fi
[[ -e "$env_mutation_state/manual-cleanup-required" ]] || fail "environment mutation omitted manual cleanup marker"
[[ -e "$env_mutation_state/failure-diagnostics.txt" ]] || fail "environment mutation omitted diagnostics"
[[ -e "$env_mutation_state/active" ]] || fail "environment mutation falsely cleared active state"
pass "unrelated environment mutation is detected and rollback diagnostics are retained"

# A tampered staged receipt is rejected before candidate Compose is reached.
tampered_state="$TMP_DIR/state-tampered"
mkdir -p "$tampered_state"
printf 'phase=baseline\n' > "$tampered_state/baseline.receipt"
printf 'baseline\n' > "$TMP_DIR/docker-state-tampered"
: > "$TMP_DIR/docker-tampered.log"
export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-tampered" DOCKER_LOG="$TMP_DIR/docker-tampered.log" DAIANA_HARNESS_STATE_DIR="$tampered_state"
if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null 2>&1; then fail "tampered staged receipt was accepted"; fi
if grep -q 'docker-compose.private-chat-candidate.yml.* up ' "$TMP_DIR/docker-tampered.log"; then fail "tampered staged receipt reached candidate Compose mutation"; fi
pass "tampered staged receipt causes zero candidate runtime mutation"

for tamper in staged_receipt baseline_fingerprint; do
  state_dir="$TMP_DIR/state-$tamper"
  mkdir -p "$state_dir"
  printf 'baseline\n' > "$TMP_DIR/docker-state-$tamper"
  : > "$TMP_DIR/docker-$tamper.log"
  export FAKE_SCENARIO=none FAKE_STATE="$TMP_DIR/docker-state-$tamper" DOCKER_LOG="$TMP_DIR/docker-$tamper.log" DAIANA_HARNESS_STATE_DIR="$state_dir"
  if [[ "$tamper" == staged_receipt ]]; then export DAIANA_HARNESS_TEST_TAMPER_STAGED_RECEIPT=yes; else export DAIANA_HARNESS_TEST_TAMPER_BASELINE_FINGERPRINT=yes; fi
  if DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes PATH="$FAKE_BIN:$PATH" bash "$harness" activate >/dev/null 2>&1; then fail "$tamper was accepted"; fi
   if grep -q 'docker-compose.private-chat-candidate.yml.* up ' "$TMP_DIR/docker-$tamper.log" || grep -q ' exec ' "$TMP_DIR/docker-$tamper.log"; then fail "$tamper reached migration or candidate runtime mutation"; fi
done

unset DAIANA_HARNESS_TEST_TAMPER_STAGED_RECEIPT DAIANA_HARNESS_TEST_TAMPER_BASELINE_FINGERPRINT
pass "staged receipt and fingerprint tampering are rejected before the migration boundary"

# Every retained diagnostic class is redacted before publication, and a
# pre-existing secret-like artifact fails closed rather than being accepted.
awk '$0 ~ /^case / && $0 ~ /preflight/ { exit } { print }' "$harness" > "$TMP_DIR/harness-functions.sh"
mkdir -p "$TMP_DIR/utils"
cp "$ROOT_DIR/utils/private-chat-redaction.py" "$TMP_DIR/utils/private-chat-redaction.py"
export DAIANA_HARNESS_REDACTION_SCRIPT="$ROOT_DIR/utils/private-chat-redaction.py"
redaction_state="$TMP_DIR/state-redaction"
mkdir -p "$redaction_state"
POSTGRES_PASSWORD='redaction-password-sentinel' POSTGRES_DB=postgres \
  DAIANA_HARNESS_STATE_DIR="$redaction_state" ROOT_DIR="$ROOT_DIR" bash -c '
    set -euo pipefail
    source "$1"
    write_failure_diagnostics "password=redaction-password-sentinel URL=https://private.example.test token=jwt-sentinel; JSON={\"password\":\"json-password-sentinel\",\"nested\":{\"api_key\":\"json-key-sentinel\"}} YAML={\"token\":\"yaml-token-sentinel\"} Authorization: Bearer bearer-sentinel escaped=https:\\/\\/private.example.test\\/path?token=escaped-token-sentinel"
    mark_manual_cleanup "postgresql://postgres:redaction-password-sentinel@db/private password=redaction-password-sentinel; {\"authorization\":\"Bearer nested-bearer-sentinel\",\"private_key\":\"-----BEGIN PRIVATE KEY-----\"}"
    verify_receipts_redacted "$STATE_DIR"
  ' bash "$TMP_DIR/harness-functions.sh"
if grep -Eiq 'redaction-password-sentinel|https?://|postgres(ql)?://|token=[^[]' "$redaction_state"/*; then
  fail "redaction failed for retained diagnostics or manual-cleanup marker"
fi
if grep -Eiq 'json-password-sentinel|json-key-sentinel|yaml-token-sentinel|bearer-sentinel|escaped-token-sentinel|nested-bearer-sentinel|BEGIN PRIVATE KEY' "$redaction_state"/*; then
  fail "quoted or escaped secret survived generated diagnostics or markers"
fi
printf 'token=unredacted-secret\n' > "$redaction_state/retry-blocked.marker"
if POSTGRES_PASSWORD=redaction-password-sentinel DAIANA_HARNESS_STATE_DIR="$redaction_state" ROOT_DIR="$ROOT_DIR" bash -c 'source "$1"; verify_receipts_redacted "$STATE_DIR"' bash "$TMP_DIR/harness-functions.sh"; then
  fail "secret-like retry-blocked artifact was accepted"
fi
for forbidden in \
  'https://private.example.test/path' \
  'postgresql://user:password@db/app' \
  'Authorization: Bearer bearer-sentinel' \
  'PASSWORD=assignment-sentinel' \
  'API_KEY=assignment-sentinel' \
  '/Users/example/private.txt' \
  '-----BEGIN PRIVATE KEY-----'; do
  printf '%s\n' "$forbidden" > "$redaction_state/forbidden.marker"
  if POSTGRES_PASSWORD=redaction-password-sentinel DAIANA_HARNESS_STATE_DIR="$redaction_state" ROOT_DIR="$ROOT_DIR" bash -c 'source "$1"; verify_receipts_redacted "$STATE_DIR"' bash "$TMP_DIR/harness-functions.sh"; then
    fail "recursive artifact scanner accepted forbidden value: $forbidden"
  fi
done
for quoted_forbidden in \
  '{"password":"quoted-json-secret"}' \
  '{"nested":{"api_key":"nested-json-secret"}}' \
  '"token":"escaped-json-secret"' \
  'Authorization: Bearer quoted-bearer-secret' \
  'url=https:\\/\\/private.example.test\\/x?secret=escaped-url-secret' \
  'private_key: "-----BEGIN PRIVATE KEY-----"'; do
  printf '%s\n' "$quoted_forbidden" > "$redaction_state/quoted.marker"
  if POSTGRES_PASSWORD=redaction-password-sentinel DAIANA_HARNESS_STATE_DIR="$redaction_state" ROOT_DIR="$ROOT_DIR" bash -c 'source "$1"; verify_receipts_redacted "$STATE_DIR"' bash "$TMP_DIR/harness-functions.sh"; then
    fail "recursive artifact scanner accepted quoted or escaped secret: $quoted_forbidden"
  fi
done
pass "diagnostics, manual-cleanup, and retry-blocked artifacts are redacted or fail closed"

# Exercise the public redaction boundary directly as well as through retained
# files. Safe metadata remains useful; quoted, nested, escaped, header, URL,
# path, and key material never crosses that boundary.
export DAIANA_HARNESS_REDACTION_SCRIPT="$ROOT_DIR/utils/private-chat-redaction.py" ROOT_DIR
redacted_reason="$({
  printf '%s' 'event=kept nested={"password":"json-password-sentinel","object":{"api_key":"nested-key-sentinel"}} escaped={\"token\":\"escaped-token-sentinel\"} Authorization: Bearer bearer-sentinel url=https:\/\/user:pass@example.test\/x?secret=url-secret-sentinel path=/Users/example/private.pem private_key="-----BEGIN PRIVATE KEY-----"'
} | bash -c 'source "$1"; redact_reason' bash "$TMP_DIR/harness-functions.sh")"
if grep -Eiq 'json-password-sentinel|nested-key-sentinel|escaped-token-sentinel|bearer-sentinel|url-secret-sentinel|private\.pem|BEGIN PRIVATE KEY|https?://' <<<"$redacted_reason"; then
  fail "direct redact_reason boundary leaked quoted, escaped, URL, path, or key material"
fi
pass "redact_reason preserves safe metadata and removes nested quoted/escaped secrets"

printf 'private-chat atomic failure-injection tests passed\n'
exit 0
