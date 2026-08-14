# Update

Use the update command to refresh the existing Portainer stacks in place. For the official Daiana application v2.2.0 release, select the checked-in immutable bundle explicitly; this does not change the installer's default Next or Python image pins.

## Official application v2.2.0 bundle

From the repository root, back up PostgreSQL and then run:

```bash
DAIANA_DEPLOYMENT_BUNDLE="$PWD/releases/v2.2.0.json" \
bash update-daiana.sh
```

This is an opt-in, backward-compatible three-image complete replacement of `daiananext`, `daianapython`, and `daianastudio` using digest-bound images. The application bundle version `v2.2.0` is independent from the Installer version in `VERSION` (`0.2.0`). Selecting the bundle does not rewrite source Compose files or retag the Installer.

The update remains migration-first: it saves an exact stack and Portainer Env snapshot, applies pending forward-only database migrations, pre-pulls all selected images, and only then submits one application stack replacement. A pull or validation failure stops before Portainer mutation. After submission, bounded readiness checks must pass for Next, Python, Teams, and Studio when a four-image QA bundle is selected; historical three-image bundles retain their three-service verification behavior. A failed check records recovery details in the snapshot metadata and prints the exact rollback command; rollback is not automatic because it cannot reverse migrations or persisted data.

> **Rollback boundary:** Installer rollback restores the saved Compose stack and Portainer Env. It does not reverse database migrations or any persisted data. Review the snapshot before updating and keep the PostgreSQL backup until the application is verified.

## Quick path

```bash
bash update-daiana.sh
```

During an interactive update, the installer:

1. validates that the installer repository is synchronized with its git upstream;
2. shows the current Daiana image targets;
3. saves a rollback snapshot of the current Daiana app stack;
4. asks for the target version for the main Daiana app images;
5. optionally asks whether to update independently versioned images;
6. waits for Supabase and applies pending Daiana database migrations;
7. renders a temporary compose override and deploys app images only after migrations succeed.

## Database migration safety

Migrations under `volumes/db/daiana-migrations/` are forward-only. The installer serializes runners with a PostgreSQL advisory lock, verifies SHA-256 history in `private.daiana_installer_schema_migrations`, and applies migration SQL plus its history insert atomically. An exact applied version/checksum is skipped; checksum drift or SQL failure stops the update before app images deploy.

Take a PostgreSQL backup before updating. The installer rollback command restores compose/images only and cannot reverse database migrations. PostgreSQL 15 and 17 are supported.

## Manual Portainer deployments

Manual installations do not have the Installer checkout or its migration ledger. Use this path when the application stack is managed directly in Portainer:

1. Back up PostgreSQL and record the backup checksum.
2. Apply the catalog migrations manually with `psql` before changing application images. The compatibility migration detects the standard `studio` schema and the manual-install `daianastudio` schema, and grants the catalog RPC only to `service_role`.
3. In Portainer, edit the existing integrated stack and change only the `daiananext` image to its immutable digest. Preserve `supabase-studio`, Supabase services, environment variables, volumes, and unrelated Daiana services.
4. Redeploy the stack and verify Next, Studio, the catalog RPC privileges, and the Management Plan selector.

Manual installations must not invent or populate `private.daiana_installer_schema_migrations` without an approved reconciliation procedure. Keep the PostgreSQL backup and the Portainer stack definition as the rollback evidence. Image rollback does not reverse manually applied migrations.

## Main Daiana app version

The main Daiana app version applies to these images together:

| Service | Image |
|---|---|
| `daiananext` | `cloudseidoranalytics/daiana` |
| `daianapython` | `cloudseidoranalytics/daianapython` |
| `daianavanna` | `cloudseidoranalytics/daianavanna` |
| `daianamsteams` | `cloudseidoranalytics/daianamsteams` |
| `daianawhatsapp` | `cloudseidoranalytics/daianawhatsapp` |

The prompt accepts versions with or without the leading `v`:

```text
Target Daiana app version [v2.4.1]: 2.4.1
```

The installer deploys that as `v2.4.1`.

## Independently versioned images

These images keep their own versions by default:

| Service | Image | Default behavior |
|---|---|---|
| `daianawebui` | `cloudseidoranalytics/daianawebui` | Keeps current compose version unless changed |
| `daianastudio` | `cloudseidoranalytics/daianastudio` | Keeps current compose version unless changed |
| `daianaqdrant` | `qdrant/qdrant` | Keeps current compose version unless changed |

When prompted, answer `y` to update them one by one. Press Enter to keep the shown default.

## Non-interactive update

Set environment variables before running the update:

```bash
DAIANA_TARGET_VERSION=2.1.10 \
DAIANA_WEBUI_TARGET_VERSION=0.10.3 \
DAIANA_STUDIO_TARGET_VERSION=3.1.3 \
QDRANT_TARGET_VERSION=v1.19.0 \
bash update-daiana.sh
```

Rules:

- `DAIANA_TARGET_VERSION`, `DAIANA_WEBUI_TARGET_VERSION`, and `DAIANA_STUDIO_TARGET_VERSION` accept values with or without `v`.
- `QDRANT_TARGET_VERSION` is used exactly as provided.
- Source compose files are not rewritten during `update`; the selected versions are applied through a temporary compose override sent to Portainer.

## Digest-bound deployment bundles

### Stable-release automation credentials

The `Prepare stable release update` workflow uses `FRONT_RELEASE_READ_TOKEN` only to read
release, tag, and workflow-run metadata from the Front repository. Configure it as a
fine-grained token restricted to Front with read-only Contents and Actions permissions.
It also uses `DAIANA_REGISTRY_USERNAME` and `DAIANA_REGISTRY_PULL_TOKEN` only to read
private Docker Hub OCI indexes for the five application images. Configure a Docker Hub
read-only token; neither credential is included in generated branches or pull requests.
The workflow uses its own `GITHUB_TOKEN` only to create a review branch and pull request
in Installer; it never deploys an environment.

The installer accepts an explicitly selected JSON deployment bundle without changing any default image pin:

```bash
DAIANA_DEPLOYMENT_BUNDLE=/secure/releases/daiana-bundle.json \
bash update-daiana.sh
```

The compatibility contract accepts version 1 bundles with exactly three image records under `images`: `next`, `python`, and `studio`. The remote-QA contract uses version 2 with exactly four records: `next`, `python`, `msteams`, and `studio`. Stable application release bundles use version 3 with exactly five records: `next`, `python`, `vanna`, `msteams`, and `whatsapp`; Studio remains independently versioned. All schemas use `deployment_mode: "complete-stack-replacement"`. Every image record must contain:

| Field | Contract |
|---|---|
| `reference` | Full OCI reference ending in `@sha256:<64 lowercase hex characters>`; an optional tag may precede the digest |
| `index_digest` | Authoritative OCI index digest, identical to the reference digest |
| `source_commit` | 40-character lowercase hexadecimal source commit SHA |

The bundle is read once, then the same captured bytes are validated, hashed, and converted to a literal JSON Compose override. Missing or extra records, mutable-only references, invalid provenance, digest mismatches, and unknown schema versions fail closed. There is no tag fallback or partial application.

## Stable release automation

`.github/workflows/stable-release-automation.yml` accepts the `daiananext_stable_release` repository dispatch only from `SeidorA/Daiana`, or a manual `workflow_dispatch` bootstrap. The dispatch contract is schema version 1 with exactly these values: `source_repo`, `stable_release_tag`, `release_id`, `source_run_id`, and `published_at`. The script validates their shapes, compares the release ID/tag/published timestamp against GitHub independently, requires a successful source run, then derives the Front commit from an annotated stable release tag. It independently fetches each of the five Docker Hub OCI indexes and requires Linux `amd64` and `arm64` descriptors. The script accepts the index digest only from the registry `Docker-Content-Digest` response header, never from a payload field. It exits cleanly when an open automation PR or no changes already exist, and refuses to overwrite an orphaned remote automation branch. It creates a review branch and PR with `GITHUB_TOKEN`; it never pushes to `main` or deploys an environment.

After all existing preconditions complete, the installer applies pending database migrations first and then pre-pulls every image in the selected bundle. Any pull failure stops before Portainer. A successful operation submits one complete Portainer stack replacement containing all literal references; it does not perform or claim a sequential per-service rollout.

## Remote-QA four-image candidate

Run the manual `sha-candidate-image.yml` workflow in Front, Python, Teams, and Studio with the exact source SHA from each repository's `develop`. Retain each workflow's digest-authoritative reference, then create a copy of `releases/qa-candidate.example.json` and replace its four example references, digests, and source commits with those outputs. The example intentionally contains non-published zero digests and must never be deployed unchanged.

```bash
DAIANA_DEPLOYMENT_BUNDLE=/secure/releases/qa-candidate.json \
bash update-daiana.sh
```

The QA bundle must contain all four services, including `daianamsteams`; tags are not deployment identity. The four workflows publish only stable `sha-<source SHA>` candidate tags, never `latest` or release tags, and their summaries expose the index digest needed for this bundle.

Before update, the installer requires the exact current Portainer stack content and Env array, stores the Env in a protected snapshot file, and records its SHA-256 in metadata. Rollback submits both saved values directly, so placeholders are not re-resolved from current environment values or repository defaults. Rollback still does not reverse migrations or persisted data.

The historical shared-message-quota candidate is preserved at `releases/shared-message-quota.json` as audit and rollback evidence. It is not the official application v2.2.0 bundle and remains inactive unless an operator explicitly selects it for a controlled historical update from the repository root:

```bash
DAIANA_DEPLOYMENT_BUNDLE="$PWD/releases/shared-message-quota.json" \
bash update-daiana.sh
```

This selection runs the installer database migration before one complete application stack replacement. Back up PostgreSQL and review the rollback limitations below before running it.

## Rollback

Each normal update saves a rollback snapshot under:

```text
volumes/daiana/update-history/<timestamp>/
```

Rollback restores the Daiana app stack compose/images only. It does not roll back databases, app migrations, Qdrant data, WebUI data, or any other persisted volume.

List snapshots:

```bash
bash update-daiana.sh --rollback --list
```

Restore the latest snapshot:

```bash
bash update-daiana.sh --rollback
```

Restore a specific snapshot:

```bash
bash update-daiana.sh --rollback 20260708-171500
```

The rollback command shows the selected snapshot and asks for confirmation before updating Portainer.

## Repository sync guard

Before `update` or `rollback`, the installer checks the current git branch against its upstream when it is running inside a git worktree with a configured upstream. If git or upstream metadata is unavailable, the check is skipped.

| State | Behavior |
|---|---|
| Up to date | Continues normally |
| Behind upstream | Asks permission to run `git pull --ff-only` |
| Behind with local changes | Stops; commit or stash local changes first |
| Ahead only | Continues and reports the local commits |
| Diverged | Stops; resolve git history manually |

Set `SKIP_REPO_SYNC_CHECK=1` only when you intentionally need to run from the current local files without contacting git upstream.

## Docker Hub registry

Private Daiana images use the Portainer registry named `dockerhub-prod-sdr` by default, with URL `docker.io`.

For automation, provide Docker Hub credentials as environment variables:

```bash
DAIANA_REGISTRY_USERNAME=<dockerhub-user> \
DAIANA_REGISTRY_PAT=<dockerhub-pat> \
bash update-daiana.sh
```

The installer still reuses older Portainer registries named `daiana-images` or using `registry-1.docker.io` when found, so existing installations keep updating without creating duplicates.
