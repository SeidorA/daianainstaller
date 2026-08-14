#!/usr/bin/env bash

set -euo pipefail

readonly SOURCE_REPOSITORY="SeidorA/Daiana"
readonly REGISTRY="registry-1.docker.io"
readonly NAMESPACE="cloudseidoranalytics"
readonly -a COMPONENTS=(next python vanna msteams whatsapp)
readonly -a IMAGE_NAMES=(daiana daianapython daianavanna daianamsteams daianawhatsapp)
readonly -a SERVICE_NAMES=(daiananext daianapython daianavanna daianamsteams daianawhatsapp)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command is unavailable: $1"; }

release_commit() {
  local release ref tag_sha tag
  release="$(gh api "repos/$SOURCE_REPOSITORY/releases/tags/$VERSION")" || die "Front release $VERSION was not found"
  jq -e --arg version "$VERSION" --arg id "$RELEASE_ID" --arg published_at "$PUBLISHED_AT" '
    .tag_name == $version and (.id | tostring) == $id and .draft == false and .prerelease == false and .published_at == $published_at
  ' <<<"$release" >/dev/null || die "Front release details do not match the dispatch payload"
  ref="$(gh api "repos/$SOURCE_REPOSITORY/git/ref/tags/$VERSION")" || die "Front tag $VERSION was not found"
  tag_sha="$(jq -r '.object.sha // empty' <<<"$ref")"
  [ -n "$tag_sha" ] || die "Front tag $VERSION has no object SHA"
  tag="$(gh api "repos/$SOURCE_REPOSITORY/git/tags/$tag_sha")" || die "Front tag $VERSION must be an annotated tag"
  jq -e '.object.type == "commit" and (.object.sha | test("^[0-9a-f]{40}$"))' <<<"$tag" >/dev/null || die "Front tag $VERSION does not resolve to a commit"
  jq -r '.object.sha' <<<"$tag"
}

validate_source_run() {
  local run
  run="$(gh api "repos/$SOURCE_REPOSITORY/actions/runs/$SOURCE_RUN_ID")" || die "Front source run $SOURCE_RUN_ID was not found"
  jq -e --arg id "$SOURCE_RUN_ID" '(.id | tostring) == $id and .status == "completed" and .conclusion == "success"' <<<"$run" >/dev/null \
    || die "Front source run does not match a successful dispatch"
}

registry_token() {
  curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$NAMESPACE/$1:pull" | jq -er '.token | select(type == "string" and length > 0)'
}

resolve_index_digest() {
  local image="$1" token headers body digest
  token="$(registry_token "$image")" || die "Unable to obtain registry access for $NAMESPACE/$image"
  headers="$(mktemp)"
  body="$(mktemp)"
  trap 'rm -f "$headers" "$body"' RETURN
  curl -fsS -D "$headers" -o "$body" -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' -H "Authorization: Bearer $token" "https://$REGISTRY/v2/$NAMESPACE/$image/manifests/$VERSION" || die "Unable to resolve $NAMESPACE/$image:$VERSION"
  digest="$(awk 'BEGIN { IGNORECASE=1 } /^Docker-Content-Digest:/ { gsub("\r", ""); print $2; exit }' "$headers")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "$NAMESPACE/$image:$VERSION did not return an OCI index digest"
  jq -e '(.schemaVersion == 2) and ((.mediaType == "application/vnd.oci.image.index.v1+json") or (.mediaType == "application/vnd.docker.distribution.manifest.list.v2+json")) and ([.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64")] | length > 0) and ([.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "arm64")] | length > 0)' "$body" >/dev/null || die "$NAMESPACE/$image:$VERSION is not a linux amd64+arm64 OCI index"
  printf '%s\n' "$digest"
}

update_default_pins() {
  local compose_file="$1" temporary_file index service image
  temporary_file="$(mktemp "${compose_file}.XXXXXX")"
  cp "$compose_file" "$temporary_file"
  for index in "${!SERVICE_NAMES[@]}"; do
    service="${SERVICE_NAMES[$index]}"
    image="${IMAGE_NAMES[$index]}"
    perl -0pi -e "s{(^  \Q$service\E:\n    image: \Q$NAMESPACE/$image\E:)v[0-9]+\\.[0-9]+\\.[0-9]+$}{\$1$VERSION}m" "$temporary_file"
    grep -Fxq "    image: $NAMESPACE/$image:$VERSION" "$temporary_file" || die "Unable to update the $service default pin"
  done
  mv "$temporary_file" "$compose_file"
}

write_bundle() {
  local output="$1" images='{}' index component image digest
  for index in "${!COMPONENTS[@]}"; do
    component="${COMPONENTS[$index]}"
    image="${IMAGE_NAMES[$index]}"
    digest="${INDEX_DIGESTS[$index]}"
    images="$(jq -c --arg component "$component" --arg image "$NAMESPACE/$image@$digest" --arg digest "$digest" --arg commit "$SOURCE_COMMIT" '. + {($component): {reference:$image, index_digest:$digest, source_commit:$commit}}' <<<"$images")"
  done
  jq -n --argjson images "$images" '{schema_version:3,deployment_mode:"complete-stack-replacement",images:$images}' > "$output"
}

[ "$#" -eq 6 ] || die "Usage: $0 1 SeidorA/Daiana vX.Y.Z release-id source-run-id published-at"
SCHEMA_VERSION="$1"
DISPATCH_SOURCE_REPOSITORY="$2"
VERSION="$3"
RELEASE_ID="$4"
SOURCE_RUN_ID="$5"
PUBLISHED_AT="$6"
[ "$SCHEMA_VERSION" = "1" ] || die "Unsupported dispatch schema version: $SCHEMA_VERSION"
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must be a stable vX.Y.Z tag"
[ "$DISPATCH_SOURCE_REPOSITORY" = "$SOURCE_REPOSITORY" ] || die "Untrusted source repository: $DISPATCH_SOURCE_REPOSITORY"
[[ "$RELEASE_ID" =~ ^[1-9][0-9]*$ ]] || die "Release ID must be a positive integer"
[[ "$SOURCE_RUN_ID" =~ ^[1-9][0-9]*$ ]] || die "Source run ID must be a positive integer"
[[ "$PUBLISHED_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "Published timestamp must be UTC RFC3339 seconds"
for command in awk curl gh jq perl; do require_command "$command"; done
[ -f docker-compose.app.yml ] || die "Run from the Installer repository root"

SOURCE_COMMIT="$(release_commit)"
validate_source_run
declare -a INDEX_DIGESTS=()
for image in "${IMAGE_NAMES[@]}"; do INDEX_DIGESTS+=("$(resolve_index_digest "$image")"); done
update_default_pins docker-compose.app.yml
mkdir -p releases
write_bundle "releases/$VERSION.json"
