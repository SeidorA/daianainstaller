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
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

validate_deployment_bundle() {
  local file="$1" component reference digest source_commit suffix
  [ -f "$file" ] || { die "Deployment bundle not found: $file"; return 1; }
  jq -e '. as $bundle |
    .schema_version == 1 and
    .rollout_order == ["daianapython", "daiananext", "daianastudio"] and
    (.images | type == "object") and
    (["next", "python", "studio"] | all(. as $name |
      ($name | in($bundle.images)) and
      ($bundle.images[$name] | type == "object") and
      ($bundle.images[$name].reference | type == "string") and
      ($bundle.images[$name].index_digest | type == "string") and
      ($bundle.images[$name].source_commit | type == "string")))
  ' "$file" >/dev/null \
    || { die "Invalid deployment bundle structure or rollout order: $file"; return 1; }

  for component in next python studio; do
    reference="$(jq -r --arg name "$component" '.images[$name].reference' "$file")"
    digest="$(jq -r --arg name "$component" '.images[$name].index_digest' "$file")"
    source_commit="$(jq -r --arg name "$component" '.images[$name].source_commit' "$file")"
    validate_oci_reference "$reference" || { die "Invalid $component OCI reference: $reference"; return 1; }
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { die "Invalid $component OCI index digest"; return 1; }
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || { die "Invalid $component source commit SHA"; return 1; }
    suffix="${reference##*@}"
    [ "$suffix" != "$reference" ] && [ "$suffix" = "$digest" ] \
      || { die "$component reference must be digest-bound to its authoritative index digest"; return 1; }
  done
}

load_deployment_bundle() {
  local file="$1"
  validate_deployment_bundle "$file" || return 1
  # Consumed by the sourcing installer.
  # shellcheck disable=SC2034
  BUNDLE_FILE="$file"
  BUNDLE_SCOPE="${DAIANA_BUNDLE_SCOPE:-all}"
  case "$BUNDLE_SCOPE" in
    pair|studio|all) ;;
    *) die "DAIANA_BUNDLE_SCOPE must be pair, studio, or all"; return 1 ;;
  esac
  BUNDLE_NEXT_IMAGE="$(jq -r '.images.next.reference' "$file")"
  BUNDLE_PYTHON_IMAGE="$(jq -r '.images.python.reference' "$file")"
  BUNDLE_STUDIO_IMAGE="$(jq -r '.images.studio.reference' "$file")"
  BUNDLE_SHA256="$(deployment_bundle_sha256 "$file")"
}

write_deployment_bundle_override() {
  local output_file="$1"
  local scope="$2"
  {
    printf 'services:\n'
    case "$scope" in
      pair|all)
        printf '  daianapython:\n    image: %s\n' "$BUNDLE_PYTHON_IMAGE"
        printf '  daiananext:\n    image: %s\n' "$BUNDLE_NEXT_IMAGE"
        ;;
    esac
    case "$scope" in
      studio|all) printf '  daianastudio:\n    image: %s\n' "$BUNDLE_STUDIO_IMAGE" ;;
    esac
  } > "$output_file"
}

deployment_bundle_metadata_json() {
  if [ -n "${BUNDLE_SHA256:-}" ]; then
    jq -n --arg sha256 "$BUNDLE_SHA256" --arg scope "$BUNDLE_SCOPE" '{sha256:$sha256, scope:$scope}'
  else
    printf 'null\n'
  fi
}
