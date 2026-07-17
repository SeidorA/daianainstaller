<div align="center">

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

</div>

# Daiana Installer

Installer and lifecycle tooling for deploying Daiana on top of a self-hosted Supabase stack using Docker, Portainer, and Nginx Proxy Manager.

This repository is not only a Supabase compose bundle. It contains the operational scripts, compose overlays, documentation, and version metadata used to install, update, roll back, certificate-enable, and uninstall a Daiana deployment.

## Quick path

```bash
bash install-daiana.sh
```

After the initial install, the main lifecycle commands are:

| Action | Command | Notes |
|---|---|---|
| Install | `bash install-daiana.sh` | Bootstraps Portainer, NPM, Supabase, and Daiana stacks |
| Apply certificates | `bash apply-certs.sh` | Applies TLS to existing NPM proxy hosts; it does not create missing proxy hosts |
| Update | `bash update-daiana.sh` | Updates stacks in place and can prompt for target image versions |
| Rollback update | `bash update-daiana.sh --rollback` | Restores the latest Daiana app stack image/compose snapshot |
| List rollback snapshots | `bash update-daiana.sh --rollback --list` | Shows available update snapshots |
| Uninstall | `bash uninstall-daiana.sh` | Stops and removes managed runtime resources |
| Full cleanup | `bash uninstall-daiana.sh --purge` | Removes runtime data as well |

See [docs/README.md](docs/README.md) for the full lifecycle guide.

## What this repo manages

| Area | Purpose |
|---|---|
| Daiana app stack | Daiana frontend/backend services, Vanna, Teams, WhatsApp, WebUI, Qdrant, and storage mounts |
| Supabase base stack | Auth, Kong, PostgREST, Realtime, Storage, Studio, Postgres, and supporting services |
| Portainer | Stack deployment and Docker Hub private registry credentials |
| Nginx Proxy Manager | Public DNS/proxy host creation and certificate workflow |
| Updates | Selectable Daiana image versions, optional independently versioned images, and rollback snapshots |
| Database migrations | Forward-only ordered Daiana migrations with advisory locking and checksum history |
| Versioning | `VERSION`, `CHANGELOG.md`, `versions.md`, and Git tags |

Each Portainer stack receives only the environment variables referenced by its compose file(s).

## Requirements

The installer checks prerequisites and, where possible, offers to install missing packages automatically.

Required tools:

- `bash`
- `git`
- `docker`
- Docker Compose (`docker compose` or `docker-compose`)
- `curl`
- `jq`
- `openssl`
- `psql`
- `supabase`

For private Daiana images, provide Docker Hub credentials when prompted or set:

```bash
DAIANA_REGISTRY_USERNAME=<dockerhub-user> \
DAIANA_REGISTRY_PAT=<dockerhub-pat> \
bash install-daiana.sh
```

The default Portainer registry name is `dockerhub-prod-sdr` with URL `docker.io`.

## Update and rollback behavior

`update-daiana.sh` validates repository sync when git upstream metadata is available. If the repo is behind, it asks before running `git pull --ff-only`; if history diverged, it stops.

During update, the installer can prompt for:

- one target version for the main Daiana image family;
- optional independent versions for WebUI, Studio, and Qdrant.

It saves rollback snapshots under:

```text
volumes/daiana/update-history/<timestamp>/
```

Rollback restores **compose/images only**. It does not roll back databases, migrations, Qdrant data, WebUI data, or other persisted volumes.

Before either a fresh app deployment or updated app images start, the installer applies pending files from `volumes/db/daiana-migrations/`. Applied versions and SHA-256 checksums are recorded in `private.daiana_installer_schema_migrations`; a changed checksum fails the deployment. Back up PostgreSQL before updating because migrations are forward-only and image rollback does not reverse them. PostgreSQL 15 and 17 are supported.

For details, see [docs/update.md](docs/update.md).

## Documentation

| Document | Use |
|---|---|
| [docs/install.md](docs/install.md) | Installation flow |
| [docs/certs.md](docs/certs.md) | Certificate and proxy host workflow |
| [docs/update.md](docs/update.md) | Updates, selectable versions, rollback, and repo sync guard |
| [docs/uninstall.md](docs/uninstall.md) | Cleanup and purge behavior |
| [docs/daiana-lifecycle.md](docs/daiana-lifecycle.md) | Lifecycle overview |
| [CONFIG.md](CONFIG.md) | Supabase environment variable reference |
| [CHANGELOG.md](CHANGELOG.md) | Release notes |
| [versions.md](versions.md) | Docker image version history |
| [VERSION](VERSION) | Current installer version |

## Base stack

This installer uses the self-hosted Supabase Docker stack as its base. Relevant Supabase services include:

- Studio
- Kong
- Auth
- PostgREST
- Realtime
- Storage
- PostgreSQL
- Edge Runtime
- Logflare / Vector
- Supavisor

For upstream Supabase concepts and service-specific configuration, use the official [Self-Hosting with Docker](https://supabase.com/docs/guides/self-hosting/docker) documentation.

## Local development helpers

The repo includes a Makefile as a shortcut to the same lifecycle scripts:

- `make install` — run `install-daiana.sh`
- `make certs` — run `apply-certs.sh`
- `make update` — run `update-daiana.sh`
- `make rollback` — restore the latest update snapshot
- `make rollback SNAPSHOT=<id>` — restore a specific snapshot
- `make rollback-list` — list update snapshots
- `make uninstall` — run `uninstall-daiana.sh`
- `make purge` — run `uninstall-daiana.sh --purge`
- `make version` — show `VERSION` and Git tag information

It also keeps direct compose helpers for local/developer use:

- `make up`, `make down`, `make ps`, `make logs`
- `make up WIPE=1`, `make down WIPE=1` — clean runtime data while preserving `volumes/daiana/update-history`
- `make compose-config`

## Security notes

This installer can expose services publicly through Nginx Proxy Manager. Before production use:

- replace all default secrets and passwords in `.env`;
- use Docker Hub PATs, not account passwords;
- review public hostnames and CORS settings;
- configure backups before updates;
- understand rollback scope: image rollback is not data rollback.

## License

This repository is licensed under Apache 2.0. It includes and adapts self-hosted Supabase Docker configuration; see the upstream [Supabase repository](https://github.com/supabase/supabase) for the original project context.
