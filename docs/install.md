# Install

```bash
bash install-daiana.sh
```

What it does:
- validates prerequisites and can auto-install missing Linux dependencies with approval (including Docker Engine + Compose plugin)
- creates or restores `.env`
- seeds Supabase keys when needed
- prompts for Docker Hub credentials when the Daiana images need private registry access
- asks for core credentials in logical groups
- persists prompted values immediately
- deploys Portainer and app stacks
- runs init SQL once after Supabase is healthy (auth, public, studio, webui)
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
