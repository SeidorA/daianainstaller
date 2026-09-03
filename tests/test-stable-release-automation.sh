#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

workflow="$ROOT_DIR/.github/workflows/stable-release-automation.yml"
script="$ROOT_DIR/scripts/prepare-stable-release.sh"
[ -f "$workflow" ] || fail "stable release workflow is missing"
[ -x "$script" ] || fail "release preparation script is not executable"
grep -Fq 'types: [daiananext_stable_release]' "$workflow" || fail "repository dispatch is not restricted"
grep -Fq "github.event.client_payload.source_repo == 'SeidorA/Daiana'" "$workflow" || fail "workflow source allowlist is missing"
grep -Fq 'workflow_dispatch:' "$workflow" || fail "manual bootstrap is missing"
for field in schema_version source_repo stable_release_tag release_id source_run_id published_at; do
  grep -Fq "client_payload.$field" "$workflow" || fail "workflow does not extract $field"
done
grep -Fq 'ref: main' "$workflow" || fail "workflow does not prepare from main"
# shellcheck disable=SC2016 # Literal GitHub Actions expression.
grep -Fq 'GH_TOKEN: ${{ secrets.FRONT_RELEASE_READ_TOKEN }}' "$workflow" || fail "release validation does not use the scoped Front read token"
# shellcheck disable=SC2016 # Literal GitHub Actions expressions.
grep -Fq 'DAIANA_REGISTRY_USERNAME: ${{ secrets.DAIANA_REGISTRY_USERNAME }}' "$workflow" || fail "workflow does not provide registry username"
# shellcheck disable=SC2016 # Literal GitHub Actions expressions.
grep -Fq 'DAIANA_REGISTRY_PULL_TOKEN: ${{ secrets.DAIANA_REGISTRY_PULL_TOKEN }}' "$workflow" || fail "workflow does not provide registry pull token"
grep -Fq "git push origin \"HEAD:refs/heads/\${branch}\"" "$workflow" || fail "workflow branch push contract changed"
grep -Fq "GH_TOKEN=\"\$GITHUB_TOKEN\" gh pr create" "$workflow" || fail "PR creation does not use GITHUB_TOKEN"
grep -Fq "gh pr edit \"\$pr_url\" --add-label type:chore" "$workflow" || fail "PR type label is missing"
grep -Fq "git status --porcelain -- docker-compose.app.yml \"releases/\${VERSION}.json\"" "$workflow" || fail "no-change handling ignores untracked release bundles"
grep -Fq "git ls-remote --exit-code --heads origin \"\$branch\"" "$workflow" || fail "orphan branch protection is missing"
grep -Fq "gh pr list --repo SeidorA/daianainstaller --base main --head \"\$branch\" --state open" "$workflow" || fail "open PR idempotency is missing"
if grep -Eq 'git push origin (main|HEAD:main)|deployment:' "$workflow"; then fail "workflow can push main or deploy"; fi
grep -Fq 'Docker-Content-Digest' "$script" || fail "registry header digest source is missing"
grep -Fq 'SOURCE_REPOSITORY="SeidorA/Daiana"' "$script" || fail "script source allowlist is missing"
grep -Fq "[ \"\$SCHEMA_VERSION\" = \"1\" ]" "$script" || fail "dispatch schema validation is missing"
grep -Fq 'RELEASE_ID" =~ ^[1-9][0-9]*$' "$script" || fail "release ID validation is missing"
grep -Fq 'SOURCE_RUN_ID" =~ ^[1-9][0-9]*$' "$script" || fail "source run ID validation is missing"
grep -Fq 'PUBLISHED_AT" =~ ^[0-9]{4}' "$script" || fail "timestamp validation is missing"
grep -Fq 'Front release details do not match the dispatch payload' "$script" || fail "release payload comparison is missing"
# shellcheck disable=SC2016 # Literal shell source match.
grep -Fq 'Front lightweight tag $VERSION does not resolve to a commit' "$script" || fail "lightweight tag validation is missing"
# shellcheck disable=SC2016 # Literal shell source match.
grep -Fq 'Front annotated tag $VERSION does not resolve to a commit' "$script" || fail "annotated tag validation is missing"
grep -Fq 'validate_source_run' "$script" || fail "source run validation is missing"
grep -Fq 'Docker Hub read credentials are required' "$script" || fail "registry credentials are not required"
grep -Fq 'architecture == "amd64"' "$script" || fail "amd64 validation is missing"
grep -Fq 'architecture == "arm64"' "$script" || fail "arm64 validation is missing"
# shellcheck disable=SC2016 # Literal Perl expression expected in the script.
grep -Fq 'my $target_service = $ENV{TARGET_SERVICE};' "$script" || fail "compose pin updater does not scope service lookup"
grep -Fq 'my ($services_indent, $service_key_indent)' "$script" || fail "compose pin updater does not scope service-level keys"
grep -Fq 'length($1) <= $service_indent' "$script" || fail "compose pin updater does not detect service block boundaries"
grep -Fq 'next unless $indent == $child_indent && $2 eq "image"' "$script" || fail "compose pin updater does not scope image lookup"
grep -Fq 'schema_version:3' "$script" || fail "schema-v3 bundle generation is missing"

update_functions="$TMP_DIR/update-functions"
awk '/^update_default_pins\(\)/,/^}/ { print }' "$script" > "$update_functions"
fixture="$TMP_DIR/docker-compose.app.yml"
cp "$ROOT_DIR/docker-compose.app.yml" "$fixture"
(
  # shellcheck disable=SC1090
  source "$update_functions"
  die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
  NAMESPACE=cloudseidoranalytics
  VERSION=v9.9.9
  SERVICE_NAMES=(daiananext daianapython daianavanna daianamsteams daianawhatsapp)
  IMAGE_NAMES=(daiana daianapython daianavanna daianamsteams daianawhatsapp)
  update_default_pins "$fixture"
)
for image in daiana daianapython daianavanna daianamsteams daianawhatsapp; do
  grep -Fq "image: cloudseidoranalytics/$image:v9.9.9" "$fixture" \
    || fail "updater did not update cloudseidoranalytics/$image inside its service block"
done
pass "default pin updater handles intervening service keys and preserves exact image scoping"

invalid_fixture="$TMP_DIR/invalid-docker-compose.app.yml"
cp "$ROOT_DIR/docker-compose.app.yml" "$invalid_fixture"
perl -0pi -e 's{(daianawhatsapp:\n[\s\S]*?image: )cloudseidoranalytics/daianawhatsapp:v2\.4\.1}{$1cloudseidoranalytics/not-daianawhatsapp:v2.4.1}' "$invalid_fixture"
if (
  # shellcheck disable=SC1090
  source "$update_functions"
  die() { exit 1; }
  NAMESPACE=cloudseidoranalytics
  VERSION=v9.9.9
  SERVICE_NAMES=(daianawhatsapp)
  IMAGE_NAMES=(daianawhatsapp)
  update_default_pins "$invalid_fixture"
) 2>"$TMP_DIR/invalid-update.err"; then
  fail "updater accepted a service block without its exact image"
fi
grep -Fq 'image: cloudseidoranalytics/not-daianawhatsapp:v2.4.1' "$invalid_fixture" \
  || fail "fail-closed pin validation changed the invalid fixture"
pass "default pin updater fails closed when the exact service/image pair is absent"
pass "stable release workflow fails closed and creates review-only PRs"
