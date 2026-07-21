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
  local document="$1" component reference digest source_commit suffix index
  local -a components=(next python studio)
  jq -e '. as $bundle |
    .schema_version == 1 and
    .deployment_mode == "complete-stack-replacement" and
    (.images | type == "object" and keys == ["next", "python", "studio"]) and
    (["next", "python", "studio"] | all(. as $name |
      ($bundle.images[$name] | type == "object") and
      ($bundle.images[$name] | keys == ["index_digest", "reference", "source_commit"]) and
      ($bundle.images[$name].reference | type == "string") and
      ($bundle.images[$name].index_digest | type == "string") and
      ($bundle.images[$name].source_commit | type == "string")))
  ' <<<"$document" >/dev/null \
    || { die "Invalid complete deployment bundle structure"; return 1; }

  local fields
  fields="$(jq -r '[.images.next, .images.python, .images.studio] | map([.reference, .index_digest, .source_commit] | @tsv) | .[]' <<<"$document")"
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
  local file="$1"
  [ -f "$file" ] || { die "Deployment bundle not found: $file"; return 1; }
  BUNDLE_DOCUMENT="$(<"$file")"
  validate_deployment_bundle "$BUNDLE_DOCUMENT" || return 1
  # Consumed by the sourcing installer as the immutable selection marker.
  # shellcheck disable=SC2034
  BUNDLE_ACTIVE=1
  IFS=$'\t' read -r BUNDLE_NEXT_IMAGE BUNDLE_PYTHON_IMAGE BUNDLE_STUDIO_IMAGE < <(
    jq -r '[.images.next.reference, .images.python.reference, .images.studio.reference] | @tsv' <<<"$BUNDLE_DOCUMENT"
  )
  BUNDLE_SHA256="$(deployment_bundle_sha256 "$BUNDLE_DOCUMENT")"
}

write_deployment_bundle_override() {
  local output_file="$1"
  jq -n --arg next "$BUNDLE_NEXT_IMAGE" --arg python "$BUNDLE_PYTHON_IMAGE" --arg studio "$BUNDLE_STUDIO_IMAGE" \
    '{services:{daiananext:{image:$next},daianapython:{image:$python},daianastudio:{image:$studio}}}' > "$output_file"
}

deployment_bundle_metadata_json() {
  if [ -n "${BUNDLE_SHA256:-}" ]; then
    jq -n --arg sha256 "$BUNDLE_SHA256" '{sha256:$sha256}'
  else
    printf 'null\n'
  fi
}

prepull_deployment_bundle_images() {
  local image
  for image in "$BUNDLE_PYTHON_IMAGE" "$BUNDLE_NEXT_IMAGE" "$BUNDLE_STUDIO_IMAGE"; do
    docker_cmd pull "$image" || { die "Failed to pre-pull deployment bundle image: $image"; return 1; }
  done
}
