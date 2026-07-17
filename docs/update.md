# Update

Use the update command to refresh the existing Portainer stacks in place.

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
Target Daiana app version [v2.1.9]: 2.1.10
```

The installer deploys that as `v2.1.10`.

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
