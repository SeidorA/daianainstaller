# Install

For the full server setup, prerequisites, TLS flow, and troubleshooting guide, see [Daiana Installer Step-by-Step Guide](installation-step-by-step.md).

```bash
bash install-daiana.sh
```

What it does:
- validates prerequisites and can auto-install missing Linux dependencies with approval (including Docker Engine + Compose plugin)
- creates or restores `.env`
- seeds Supabase keys when needed
- prompts for Docker Hub credentials when the Daiana images need private registry access
- logs the local Docker client into Docker Hub and pre-pulls private Daiana images before Portainer deploy
- asks for core credentials in logical groups
- persists prompted values immediately
- deploys Portainer and the core Supabase stack
- waits for PostgreSQL entrypoint structural init, then runs post-start seed SQL once after Supabase is healthy (auth, public, studio, webui, vault)
- applies pending ordered Daiana migrations before deploying any app consumers
- deploys the Daiana app stack only after migrations succeed
- creates NPM proxy hosts without TLS
- `sh run.sh secrets` prints Supabase, NPM, and Portainer access credentials from `.env`

## Prompt order
1. `BASE_DOMAIN`
2. `NPM_ADMIN_EMAIL`
3. `NPM_ADMIN_PASS`
4. `PORTAINER_ADMIN_PASS`
5. SMTP settings
6. Google SSO enablement + credentials
7. optional integrations

## Important defaults
- `NPM_ADMIN_EMAIL`: `admin@example.com`
- `LICENSE_ACTIVATION_BASE_URL`: `https://license.example.com`
- SMTP placeholders in `.env.example` are treated as empty on first run

## Database migrations

Installer-owned migrations live in `volumes/db/daiana-migrations/`; they are not mounted into PostgreSQL's entrypoint because Daiana schemas do not exist at that stage. Files run lexically under a global advisory lock and one transaction with `psql ON_ERROR_STOP`.

History is stored in `private.daiana_installer_schema_migrations` with the version, name, SHA-256 checksum, application time, and installer version. Exact version/checksum matches are no-ops. A checksum mismatch or SQL failure stops installation before app deployment and leaves no migration history row.

Use `bash install-daiana.sh --dry-run` to preview the lifecycle without contacting the database. PostgreSQL 15 and 17 are supported.
