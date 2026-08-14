#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
grep -Fq "git push origin \"HEAD:refs/heads/\${branch}\"" "$workflow" || fail "workflow branch push contract changed"
grep -Fq "GH_TOKEN=\"\$GITHUB_TOKEN\" gh pr create" "$workflow" || fail "PR creation does not use GITHUB_TOKEN"
grep -Fq "gh pr edit \"\$pr_url\" --add-label type:chore" "$workflow" || fail "PR type label is missing"
grep -Fq "git diff --quiet -- docker-compose.app.yml \"releases/\${VERSION}.json\" && exit 0" "$workflow" || fail "no-diff handling is unsafe"
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
grep -Fq 'architecture == "amd64"' "$script" || fail "amd64 validation is missing"
grep -Fq 'architecture == "arm64"' "$script" || fail "arm64 validation is missing"
grep -Fq 'schema_version:3' "$script" || fail "schema-v3 bundle generation is missing"
pass "stable release workflow fails closed and creates review-only PRs"
