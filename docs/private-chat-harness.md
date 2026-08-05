# Authenticated private-chat candidate harness

The harness is a registry-free, local-only candidate path for the verified
Front, Python, Teams, and application Studio feature heads. It is separate from `install-daiana.sh`,
`update-daiana.sh`, Portainer, and the deployment-bundle pull path.

## Preconditions

- The host and all four candidate images are arm64.
- External Docker network `daiana-mgmt` exists.
- The candidate Compose project identity is fixed to `daiana-app`, matching the
  Installer baseline. `DAIANA_COMPOSE_PROJECT_NAME` is not an override: if set,
  it must equal exactly `daiana-app`; unset/default is also resolved to
  `daiana-app`. The rendered candidate model must declare external network
  `daiana-mgmt`; only `daiananext`, `daianapython`, `daianamsteams`, and `daianastudio` are selected for mutation.
- `daiana-next`, `daiana-python`, `daiana-msteams`, and `daiana-studio` are running their known baseline images. The
  known v2.1.9 Python image does not expose `NODE_ENV`; the harness treats that
  missing entry as an explicit **implicit-production** baseline contract. An
  explicit `NODE_ENV=production` is also accepted exactly once. Wrong,
  duplicate, conflicting, or malformed `NODE_ENV` entries are rejected. The
  harness never adds `NODE_ENV=production` to make a baseline pass.
- Candidate images are already built locally and tagged with their full source SHA using the exact approved repositories: `cloudseidoranalytics/daiana`, `cloudseidoranalytics/daianapython`, `cloudseidoranalytics/daianamsteams`, and `cloudseidoranalytics/daianastudio`, each followed by `:sha-` and 40 lowercase hexadecimal characters. Teams and Studio require explicit full-SHA allowlist inputs; missing, malformed, or unapproved values fail closed.
- Normal source-ref validation uses each repository's fixed local baseline:
  Front uses `develop`, Python and Teams use their local `develop` refs, while
  Studio uses its fixed local `feat/daiana-313` ref. The Studio baseline is
  intentional because it contains the Daiana quota changes. Every invocation also requires
  `DAIANA_HARNESS_MODE=local-candidate`, `DAIANA_HARNESS_OPERATION=candidate`,
  `DAIANA_DEPLOYMENT_MODE=local-candidate`, `DAIANA_HARNESS_NO_PUSH=1`,
  `DAIANA_HARNESS_NO_PUBLICATION=1`, and
  `DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1`. `DAIANA_FEATURE_BASE_REF` is
  rejected and cannot select an alternate ancestry base. The only exceptions are the exact approved four-service candidates: Front
  `503d3c65bce2d9ec68d714010f680f702052c3dc` and Python
  `68565fb1870da340a6f5f3f6bc258f7bf3d70ab8`, Teams
  `1571fc1e7e7f11038168dd1a6673cdd50777efa1`, or the newly approved Teams
  `28174f50391b6fa83d7cf97382a756f5d2f5fcb1`, with the same Front, Python,
  and Studio SHAs. The caller must supply all four matching
  `DAIANA_APPROVED_*_SOURCE_SHA` values; missing, short, wrong, or mismatched values fail closed.
- PostgreSQL has been backed up. Installer migrations are forward-only and are
  not reversed by cleanup.

The current HTTP nip.io route requires `NODE_ENV=development` together with
`PRIVATE_CHAT_ALLOW_INSECURE_LOCAL_ORIGIN=true`. The candidate override sets
both values on **both** `daiananext` and `daianapython`, and requires the
non-empty `PRIVATE_CHAT_PYTHON_ORIGIN` only on `daiananext`. That origin must be
an origin-only HTTP/HTTPS URL: HTTP is limited to localhost, loopback, or
private/loopback `nip.io` hosts, including optional DNS service labels such as
`api.192.168.0.19.nip.io`; HTTPS follows the existing Front proxy policy.
Credentials, paths, queries, and fragments are rejected. This is intentionally
development-only configuration for the local HTTP E2E path and is not present
in the production/base Compose files. Preflight renders the complete candidate
Compose model and rejects missing, duplicate, conflicting, or wrong-service
candidate environment before the migration boundary.

Teams and application Studio receive no candidate-only environment values or
health claim. Their baseline environment and volumes come from the Compose
merge, and readiness remains unavailable unless the committed Compose contract
provides a deterministic health check.

## Commands

Preflight is read-only and checks the local candidate inputs without contacting
PostgreSQL. It still requires the two variable names below to be set to
non-empty values because the same preflight contract is enforced before
activation; never place secret values in documentation or shell history:

```bash
ALLOW_LOCAL_FEATURE_REFS=1 \
POSTGRES_PASSWORD="$POSTGRES_PASSWORD" POSTGRES_DB="$POSTGRES_DB" \
DAIANA_HARNESS_MODE=local-candidate DAIANA_HARNESS_OPERATION=candidate \
DAIANA_DEPLOYMENT_MODE=local-candidate DAIANA_HARNESS_NO_PUSH=1 \
 DAIANA_HARNESS_NO_PUBLICATION=1 DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1 \
 PRIVATE_CHAT_PYTHON_ORIGIN="$PRIVATE_CHAT_PYTHON_ORIGIN" \
 DAIANA_CANDIDATE_NEXT_IMAGE=cloudseidoranalytics/daiana:sha-503d3c65bce2d9ec68d714010f680f702052c3dc \
 DAIANA_CANDIDATE_PYTHON_IMAGE=cloudseidoranalytics/daianapython:sha-68565fb1870da340a6f5f3f6bc258f7bf3d70ab8 \
  DAIANA_CANDIDATE_MSTEAMS_IMAGE=cloudseidoranalytics/daianamsteams:sha-28174f50391b6fa83d7cf97382a756f5d2f5fcb1 \
  DAIANA_CANDIDATE_STUDIO_IMAGE=cloudseidoranalytics/daianastudio:sha-ed872073e7f359e7b8c88c6c2a26f55c46582c69 \
  DAIANA_APPROVED_NEXT_SOURCE_SHA=503d3c65bce2d9ec68d714010f680f702052c3dc \
  DAIANA_APPROVED_PYTHON_SOURCE_SHA=68565fb1870da340a6f5f3f6bc258f7bf3d70ab8 \
  DAIANA_APPROVED_MSTEAMS_SOURCE_SHA=28174f50391b6fa83d7cf97382a756f5d2f5fcb1 \
  DAIANA_APPROVED_STUDIO_SOURCE_SHA=ed872073e7f359e7b8c88c6c2a26f55c46582c69 \
 bash utils/private-chat-harness.sh preflight
```

For the approved feature heads, preflight also needs the same explicit
local-only exception guards shown in the activation command below.

Activation requires an additional explicit consent variable. It recreates
only the four application services under Compose project `daiana-app`, uses `--pull never`, and never removes
volumes or the external network:

```bash
DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes \
ALLOW_LOCAL_FEATURE_REFS=1 \
POSTGRES_PASSWORD="$POSTGRES_PASSWORD" POSTGRES_DB="$POSTGRES_DB" \
DAIANA_HARNESS_MODE=local-candidate \
DAIANA_HARNESS_OPERATION=candidate \
DAIANA_DEPLOYMENT_MODE=local-candidate \
 DAIANA_HARNESS_NO_PUSH=1 DAIANA_HARNESS_NO_PUBLICATION=1 \
 DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1 \
 PRIVATE_CHAT_PYTHON_ORIGIN="$PRIVATE_CHAT_PYTHON_ORIGIN" \
 DAIANA_CANDIDATE_NEXT_IMAGE=cloudseidoranalytics/daiana:sha-503d3c65bce2d9ec68d714010f680f702052c3dc \
  DAIANA_CANDIDATE_PYTHON_IMAGE=cloudseidoranalytics/daianapython:sha-68565fb1870da340a6f5f3f6bc258f7bf3d70ab8 \
  DAIANA_CANDIDATE_MSTEAMS_IMAGE=cloudseidoranalytics/daianamsteams:sha-28174f50391b6fa83d7cf97382a756f5d2f5fcb1 \
  DAIANA_CANDIDATE_STUDIO_IMAGE=cloudseidoranalytics/daianastudio:sha-ed872073e7f359e7b8c88c6c2a26f55c46582c69 \
  DAIANA_APPROVED_NEXT_SOURCE_SHA=503d3c65bce2d9ec68d714010f680f702052c3dc \
  DAIANA_APPROVED_PYTHON_SOURCE_SHA=68565fb1870da340a6f5f3f6bc258f7bf3d70ab8 \
  DAIANA_APPROVED_MSTEAMS_SOURCE_SHA=28174f50391b6fa83d7cf97382a756f5d2f5fcb1 \
  DAIANA_APPROVED_STUDIO_SOURCE_SHA=ed872073e7f359e7b8c88c6c2a26f55c46582c69 \
 bash utils/private-chat-harness.sh activate
```

`POSTGRES_PASSWORD` and `POSTGRES_DB` must be non-empty environment variables;
the command intentionally references their existing values and never places
secret values in this document or shell history. `ALLOW_LOCAL_FEATURE_REFS=1` is a narrowly scoped, local-only exception. It is
accepted only for the exact approved four-service SHA allowlist, with all six explicit
local-candidate/candidate/no-push/
no-publication/no-registry-publish guards. It is rejected for release, update,
production, publication, and ordinary deployment-bundle paths; the candidate
Compose overlay also requires `pull_policy: never`. Never copy these variables
into production or release automation.

Activation requires `POSTGRES_PASSWORD` and `POSTGRES_DB`. Before recreating the
app containers it invokes the existing Installer migration runner against a
temporary directory containing the three private-chat migrations. The runner's
advisory lock, checksum history, ordering, and single transaction remain the
source of truth; already applied checksums are skipped. Activation then verifies
the live `private.daiana_installer_schema_migrations` ledger contains all three
version/name/checksum entries and checks the `history.message_ref`,
`figure_artifacts`, public quota finalization, and Flowise no-history quota
finalization objects. This is explicitly
forward-only: before invoking the runner, the harness durably fsyncs an atomic
intent marker with both expected versions/checksums and forward-only
manual-recovery instructions. A successful runner plus live ledger/schema
verification atomically transitions that marker to committed evidence;
catchable failures transition it to failed or blocked evidence. If the process
is killed, the pending marker remains, the database outcome is unknown, and
retry is blocked until manual reconciliation. The harness then writes
`migrations-applied.receipt` with all three versions, names, and checksums. Cleanup
never rolls back migrations or claims atomic database compensation;
post-commit receipt failures retain diagnostics and block retry.
The new `migration_120000_*` fields are additive; retained receipts from the
previous two-migration contract remain valid and are never rewritten.

Restore the known baseline app images after the candidate run:

```bash
DAIANA_HARNESS_ALLOW_RUNTIME_MUTATION=yes \
ALLOW_LOCAL_FEATURE_REFS=1 \
 DAIANA_HARNESS_MODE=local-candidate DAIANA_HARNESS_OPERATION=candidate \
 DAIANA_DEPLOYMENT_MODE=local-candidate DAIANA_HARNESS_NO_PUSH=1 \
  DAIANA_HARNESS_NO_PUBLICATION=1 DAIANA_HARNESS_NO_REGISTRY_PUBLISH=1 \
  DAIANA_APPROVED_NEXT_SOURCE_SHA=503d3c65bce2d9ec68d714010f680f702052c3dc \
  DAIANA_APPROVED_PYTHON_SOURCE_SHA=68565fb1870da340a6f5f3f6bc258f7bf3d70ab8 \
  DAIANA_APPROVED_MSTEAMS_SOURCE_SHA=28174f50391b6fa83d7cf97382a756f5d2f5fcb1 \
  DAIANA_APPROVED_STUDIO_SOURCE_SHA=ed872073e7f359e7b8c88c6c2a26f55c46582c69 \
 bash utils/private-chat-harness.sh cleanup
```

Cleanup first re-runs the mandatory local-candidate context, fixed per-repository
ancestry (`develop` for Front/Python/Teams and `feat/daiana-313` for Studio), exact approved source-SHA allowlist, and per-component image
repository/full-SHA-tag validation from the active receipt. It then validates
the active receipt against the currently running candidate containers: running
state, container IDs, exact image references, immutable image IDs and
RepoDigests (or the full-SHA source-tag contract), architecture, candidate
configuration fingerprints, and requested image values. A mismatch is rejected
before baseline Compose is invoked and redacted diagnostics are retained; a
tampered receipt cannot bypass the source or image guards. Only after those
candidate checks pass does cleanup use the baseline Compose files without the
candidate overlay. It then asserts that all four baseline containers are running again without the candidate's
development-only HTTP environment. A missing baseline `NODE_ENV` remains
missing; cleanup does not add or remove unrelated environment entries. The
baseline receipt records `implicit-production` or `explicit-production`
separately from the actual environment key set, while safe fingerprints retain
the lossless observed `Config.Env` representation. It compares both restored safe configuration
fingerprints with the baseline receipt before deleting any receipt. A mismatch
or secret-like receipt value fails closed and retains the state directory for
diagnostics (RISK-001). It removes only the temporary harness state directory
after all assertions pass. Receipts contain image references,
container IDs, architecture, migration checksums, and redaction metadata; they
never contain environment values, credentials, tokens, cookies, passwords,
URLs, or database connection strings.

The historical NPM/runtime receipts under `volumes/api/` are local runtime
evidence, not tracked harness fixtures; they are intentionally excluded from
the tracked artifact scan. They must not be copied into a commit or treated as
redacted schema examples. The harness's recursive retained-state scanner
fails closed on HTTP/DB URLs, bearer credentials, password/token/key
assignments, private-key markers, and concrete local paths.
The repository `.gitignore` also excludes runtime receipt, diagnostic, state,
and marker filename patterns under `volumes/api/`. Existing untracked evidence
is intentionally retained in place for rollback review; do not delete it or
stage it. If rollback evidence must leave the workspace, copy it to an
access-controlled external evidence store first, verify the copy, and record
that location before removing the local copy.

Candidate environment assertions require exactly one `KEY=value` entry for
each required key/value pair; substring matches and duplicate or contradictory
entries are rejected. Secret-bearing environment values are never written to
receipts or diagnostics. Activation stages and validates the
baseline receipt before migration or candidate Compose startup. Once startup begins, EXIT/ERR/INT/TERM handlers compensate with the
baseline Compose files and verify image, running-state, environment, and safe
configuration fingerprints before removing `active`. Receipt or assertion
failures therefore cannot be reported as successful activation. If baseline
restoration cannot be verified, the state directory retains redacted
`failure-diagnostics.txt`, `baseline.receipt`, `migrations-applied.receipt`, and
`manual-cleanup-required`; that marker blocks an unsafe retry. Verified
pre-migration compensation may remove temporary state. Any failure after the
migrations-applied boundary retains the baseline and migration receipts,
writes `manual-cleanup-required` with `retry=blocked`, and requires manual
database/runtime recovery even when app-container restoration succeeds.

The deterministic harness test injects partial startup, post-start assertion,
receipt write/validation, migration-commitment write, signal, and compensation
failures and checks both verified restoration and the manual-cleanup boundary.
A commitment-write failure is treated as post-migration and leaves the durable
manual-recovery/retry-blocked marker before candidate Compose can run.

## Migration coverage

The two feature migrations are packaged without transaction wrappers so the
existing Installer runner owns ordering, advisory locking, and checksum
history. Each runner batch is transactional while it is applying, but a
successfully committed migration is forward-only: cleanup never rolls it back
and later recovery is manual. Run disposable PostgreSQL coverage without touching the
local deployment:

```bash
DAIANA_MIGRATION_TEST_PG_VERSIONS="15 17" \
bash tests/test-private-chat-migrations-integration.sh
```

The integration test creates and removes disposable PostgreSQL containers and
never uses persistent Supabase volumes.

The source-ref contract is covered separately by
`bash tests/test-private-chat-source-refs.sh`, including the normal ancestry
path for the three `develop` baselines and Studio `feat/daiana-313`, exact approved
four-source-SHA allowlist, short/wrong refs, missing opt-in, release,
publish, update, publication, production, push, disabled no-publication and
no-registry-publish guards, enabled publish and registry-publish guards, and
the ordinary deployment-bundle control check.

### Rollback boundary

Cleanup restores only the four application containers to the recorded baseline;
it does not undo committed migrations. After the migration commitment, receipt,
rollback, or verification boundary is crossed, failure leaves redacted
diagnostics and `manual-cleanup-required` with retry blocked. Retained failure,
manual-cleanup, and retry-blocked artifacts are scanned for secret-like values
before publication and fail closed if they cannot be proven redacted. The
baseline receipt retains only fingerprints and key names for public/internal
URL and Vault configuration; values are never emitted. Migration boundary and
receipt files, plus their containing directory, are fsynced after every atomic
rename. Recovery is manual and must
restore the baseline runtime and reconcile the forward-only database changes;
do not use the local exception as a production rollback mechanism.

Receipts record `compose_project=daiana-app`, `network=daiana-mgmt`, and the
mutation scope `daianapython,daiananext,daianamsteams,daianastudio`. These identity fields are validated
before candidate startup and before baseline cleanup. A project override,
wrong rendered network, or out-of-scope service fails before migration or
runtime mutation. After migration commitment or any post-migration failure,
reconcile the database and restore the four app containers manually before
retrying.
