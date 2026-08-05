#!/usr/bin/env bash

validate_oci_reference() {
  local reference="$1"
  [[ "$reference" =~ ^([a-z0-9]+([._-][a-z0-9]+)*(:[0-9]+)?/)?[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*(:[A-Za-z0-9_][A-Za-z0-9._-]{0,127})?(@sha256:[0-9a-f]{64})?$ ]]
}

image_tag() {
  local tagged="${1%%@*}"
  local leaf="${tagged##*/}"
  [[ "$leaf" == *:* ]] || return 0
  printf '%s' "${leaf#*:}"
}

deployment_bundle_sha256() {
  local document="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$document" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$document" | shasum -a 256 | awk '{print $1}'
  fi
}

validate_deployment_bundle() {
  local document="$1" component reference digest source_commit suffix index schema_version
  local -a components
  schema_version="$(jq -r '.schema_version // empty' <<<"$document")"
  case "$schema_version" in
    1) components=(next python studio) ;;
    2) components=(next python msteams studio) ;;
    *) die "Unsupported deployment bundle schema version: $schema_version"; return 1 ;;
  esac
  jq -e '. as $bundle |
    (.schema_version == 1 or .schema_version == 2) and
    .deployment_mode == "complete-stack-replacement" and
    ((.schema_version == 1 and (.images | type == "object" and keys == ["next", "python", "studio"])) or
     (.schema_version == 2 and (.images | type == "object" and keys == ["msteams", "next", "python", "studio"]))) and
    ((if .schema_version == 1 then ["next", "python", "studio"] else ["next", "python", "msteams", "studio"] end) | all(. as $name |
      ($bundle.images[$name] | type == "object") and
      ($bundle.images[$name] | keys == ["index_digest", "reference", "source_commit"]) and
      ($bundle.images[$name].reference | type == "string") and
      ($bundle.images[$name].index_digest | type == "string") and
      ($bundle.images[$name].source_commit | type == "string")))
  ' <<<"$document" >/dev/null \
    || { die "Invalid complete deployment bundle structure"; return 1; }

  local fields
  fields="$(jq -r --argjson components "$(printf '%s\n' "${components[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    '[.images[$components[]]] | map([.reference, .index_digest, .source_commit] | @tsv) | .[]' <<<"$document")"
  index=0
  while IFS=$'\t' read -r reference digest source_commit; do
    component="${components[$index]}"
    validate_oci_reference "$reference" || { die "Invalid $component OCI reference: $reference"; return 1; }
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { die "Invalid $component OCI index digest"; return 1; }
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { die "Invalid $component source commit SHA"; return 1; }
    suffix="${reference##*@}"
    [ "$suffix" != "$reference" ] && [ "$suffix" = "$digest" ] \
      || { die "$component reference must be digest-bound to its authoritative index digest"; return 1; }
    index=$((index + 1))
  done <<<"$fields"
}

load_deployment_bundle() {
  local file="$1" schema_version
  [ -f "$file" ] || { die "Deployment bundle not found: $file"; return 1; }
  BUNDLE_DOCUMENT="$(<"$file")"
  validate_deployment_bundle "$BUNDLE_DOCUMENT" || return 1
  # Consumed by the sourcing installer as the immutable selection marker.
  # shellcheck disable=SC2034
  BUNDLE_ACTIVE=1
  schema_version="$(jq -r '.schema_version' <<<"$BUNDLE_DOCUMENT")"
  # shellcheck disable=SC2034 # consumed by the sourcing installer
  BUNDLE_SCHEMA_VERSION="$schema_version"
  IFS=$'\t' read -r BUNDLE_NEXT_IMAGE BUNDLE_PYTHON_IMAGE BUNDLE_MSTEAMS_IMAGE BUNDLE_STUDIO_IMAGE < <(
    jq -r 'if .schema_version == 2
      then [.images.next.reference, .images.python.reference, .images.msteams.reference, .images.studio.reference]
      else [.images.next.reference, .images.python.reference, "__legacy_no_msteams__", .images.studio.reference]
      end | @tsv' <<<"$BUNDLE_DOCUMENT"
  )
  [ "$BUNDLE_MSTEAMS_IMAGE" = "__legacy_no_msteams__" ] && BUNDLE_MSTEAMS_IMAGE=""
  BUNDLE_SHA256="$(deployment_bundle_sha256 "$BUNDLE_DOCUMENT")"
}

write_deployment_bundle_override() {
  local output_file="$1"
  if [ -n "${BUNDLE_MSTEAMS_IMAGE:-}" ]; then
    jq -n --arg next "$BUNDLE_NEXT_IMAGE" --arg python "$BUNDLE_PYTHON_IMAGE" --arg msteams "$BUNDLE_MSTEAMS_IMAGE" --arg studio "$BUNDLE_STUDIO_IMAGE" \
      '{services:{daiananext:{image:$next},daianapython:{image:$python},daianamsteams:{image:$msteams},daianastudio:{image:$studio}}}' > "$output_file"
  else
    jq -n --arg next "$BUNDLE_NEXT_IMAGE" --arg python "$BUNDLE_PYTHON_IMAGE" --arg studio "$BUNDLE_STUDIO_IMAGE" \
      '{services:{daiananext:{image:$next},daianapython:{image:$python},daianastudio:{image:$studio}}}' > "$output_file"
  fi
}

deployment_bundle_metadata_json() {
  if [ -n "${BUNDLE_SHA256:-}" ]; then
    jq -n --arg sha256 "$BUNDLE_SHA256" '{sha256:$sha256}'
  else
    printf 'null\n'
  fi
}

read_snapshot_env() {
  local file="$1"
  [ -f "$file" ] || { die "Rollback snapshot is missing portainer-env.before.json: $file"; return 1; }
  jq -ce 'select(type == "array" and all(.[];
    type == "object" and (.name | type == "string") and (.value | type == "string")))' "$file" \
    || { die "Rollback snapshot contains invalid Portainer Env"; return 1; }
}

prepull_deployment_bundle_images() {
  local image
  for image in "$BUNDLE_PYTHON_IMAGE" "$BUNDLE_NEXT_IMAGE" "${BUNDLE_MSTEAMS_IMAGE:-}" "$BUNDLE_STUDIO_IMAGE"; do
    [ -n "$image" ] || continue
    docker_cmd pull "$image" || { die "Failed to pre-pull deployment bundle image: $image"; return 1; }
  done
}
