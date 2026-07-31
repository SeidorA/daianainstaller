# Daiana Installer Step-by-Step Guide

This guide covers a fresh Daiana installation, certificate setup, and the most common troubleshooting paths. You can install prerequisites manually, or let the installer attempt to install missing Linux dependencies when it asks for approval.

## Quick path

1. Prepare DNS and server access.
2. Install or allow the installer to install prerequisites.
3. Run `bash install-daiana.sh`.
4. Verify generated credentials with `sh run.sh secrets`.
5. Apply TLS certificates with `bash apply-certs.sh` or one host at a time with `ONLY_PREFIX`.
6. Verify the public URLs and container health.

## 1. Before you start

Confirm these items first:

- You have SSH access to the target Linux server.
- DNS records point to the server public IP.
- Ports `80` and `443` are open to the internet.
- Docker Hub credentials are available if private Daiana images must be pulled.
- You know the base domain, for example `daianains.seidoranalytics.com`.

Expected public hosts are derived from `BASE_DOMAIN`:

| Prefix | Example |
|--------|---------|
| `daiana` | `daiana.<BASE_DOMAIN>` |
| `supa` | `supa.<BASE_DOMAIN>` |
| `api` | `api.<BASE_DOMAIN>` |
| `studio` | `studio.<BASE_DOMAIN>` |
| `webui` | `webui.<BASE_DOMAIN>` |
| `qdrant` | `qdrant.<BASE_DOMAIN>` |
| `nginx` | `nginx.<BASE_DOMAIN>` |
| `port` | `port.<BASE_DOMAIN>` |

## 2. Prepare the server workspace

After connecting to the server over SSH, create the installation directory and clone this repository into it:

```bash
sudo mkdir /daiana
sudo chown "$USER:$USER" /daiana
cd /daiana
git clone https://github.com/agarcia-seidor/installer.git .
```

The rest of the commands in this guide assume you are running them from:

```bash
/daiana
```

## 3. Prerequisites

You have two options.

### Option A: Let the installer help

Run the installer directly:

```bash
bash install-daiana.sh
```

The installer validates prerequisites and, on supported Linux systems, can ask for approval to install missing dependencies such as Docker Engine, the Docker Compose plugin, `curl`, `git`, `psql`, and the Supabase CLI.

### Option B: Install prerequisites manually

Install these before running the installer:

- Docker Engine
- Docker Compose plugin
- `curl`
- `git`
- `openssl`
- `jq`
- PostgreSQL client tools (`psql`)
- Supabase CLI

Then verify:

```bash
docker --version
docker compose version
curl --version
git --version
openssl version
jq --version
psql --version
supabase --version
```

## 4. Run the installer

From the repository root:

```bash
bash install-daiana.sh
```

The installer will:

- create or restore `.env`;
- generate Supabase keys and app secrets when needed;
- ask for core domain, NPM, Portainer, SMTP, Google SSO, and optional integration values;
- log in to Docker Hub when private images need access;
- deploy Supabase, Portainer, Nginx Proxy Manager, and Daiana services;
- run init SQL once after Supabase is healthy;
- create NPM proxy hosts initially without TLS.

Prompt order:

1. `BASE_DOMAIN`
2. `NPM_ADMIN_EMAIL`
3. `NPM_ADMIN_PASS`
4. `PORTAINER_ADMIN_PASS`
5. SMTP settings
6. Google SSO enablement and credentials
7. Optional integrations

## 5. Check generated credentials

After install:

```bash
sh run.sh secrets
```

This prints grouped credentials for Supabase, Nginx Proxy Manager, and Portainer from `.env`.

Do not commit `.env`. It contains live secrets.

## 6. Apply TLS certificates

Run:

```bash
bash apply-certs.sh
```

Certificate modes:

| Mode | Use when |
|------|----------|
| Let’s Encrypt | Public DNS points to this server and ports `80/443` are open. |
| Self-signed / local | Local or internal testing. |
| Custom cert files | You already have certificate and key files. |

To target a single proxy host, use `ONLY_PREFIX`:

```bash
ONLY_PREFIX=supa TLS_MODE=letsencrypt bash apply-certs.sh
ONLY_PREFIX=api TLS_MODE=letsencrypt bash apply-certs.sh
ONLY_PREFIX=qdrant TLS_MODE=letsencrypt bash apply-certs.sh
```

This is useful when one host failed but others already have certificates. The script reuses an existing certificate when NPM already has one for that domain.

The URL lifecycle is explicit: initial `*.nip.io` installation uses `http`,
`apply-certs.sh` switches all public URLs to `https` (including `*.nip.io`),
and `remove-certs.sh` switches them back to `http` before refreshing Portainer
stacks.

## 7. Verify after install

Check containers:

```bash
docker ps
```

Check Supabase Auth settings:

```bash
set -a
source .env
set +a

curl -s "$SUPABASE_PUBLIC_URL/auth/v1/settings" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ANON_KEY" | jq
```

Expected Auth settings should show enabled providers such as `email`, `phone`, or `google`, depending on your `.env`.

Check NPM outbound access to Let’s Encrypt:

```bash
docker exec npm curl -4 -Iv https://acme-v02.api.letsencrypt.org/directory
```

Expected result:

```text
HTTP/2 200
```

## Troubleshooting

### NPM returns HTTP 400: `data/meta must NOT have additional properties`

Cause: the NPM certificate API rejected an older Let's Encrypt payload shape.

Fix: use the current installer branch where `utils/npm_ssl_bootstrap.sh` creates certificates with the compatible payload. Then retry:

```bash
ONLY_PREFIX=<prefix> TLS_MODE=letsencrypt bash apply-certs.sh
```

### NPM returns HTTP 500 with `SSLEOFError` to Let’s Encrypt

Example:

```text
requests.exceptions.SSLError: HTTPSConnectionPool(host='acme-v02.api.letsencrypt.org', port=443)
SSLEOFError: UNEXPECTED_EOF_WHILE_READING
```

Cause: Certbot inside the `npm` container could not complete an outbound TLS connection to Let’s Encrypt. This is usually transient network/TLS behavior, Docker/NAT, firewall, or provider routing. It is not a domain challenge failure when the error happens while fetching `/directory`.

Verify from the host:

```bash
curl -Iv https://acme-v02.api.letsencrypt.org/directory
```

Verify from the NPM container:

```bash
docker exec npm curl -4 -Iv https://acme-v02.api.letsencrypt.org/directory
```

If the container returns `HTTP/2 200`, retry the certificate:

```bash
ONLY_PREFIX=<prefix> TLS_MODE=letsencrypt bash apply-certs.sh
```

If only the container fails, investigate Docker networking/NAT or restart Docker during a maintenance window:

```bash
sudo systemctl restart docker
docker compose up -d
```

### `No API key found in request` from `/auth/v1/settings`

Cause: Kong protects `/auth/v1/*` and requires an API key.

Use:

```bash
curl -s "$SUPABASE_PUBLIC_URL/auth/v1/settings" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ANON_KEY" | jq
```

### Login UI says no access methods are enabled

First prove Supabase Auth is healthy:

```bash
curl -s "$SUPABASE_PUBLIC_URL/auth/v1/settings" \
  -H "apikey: $ANON_KEY" \
  -H "Authorization: Bearer $ANON_KEY" | jq
```

If `external.email`, `external.phone`, or `external.google` are `true`, Auth is configured. The issue is likely in the app/UI tenant settings rather than Supabase Auth itself.

Relevant seeded tenant settings live in:

```text
volumes/db/init/public.sql
```

### A host returns `404` for `/.well-known/acme-challenge/test`

That is not automatically a failure. A random test file does not exist, so `404` can be normal. The useful signal is whether the request reaches NPM/openresty and whether Certbot can create the actual challenge file during issuance.

### Some hosts already have certificates

Use `ONLY_PREFIX` to avoid touching all hosts:

```bash
ONLY_PREFIX=supa TLS_MODE=letsencrypt bash apply-certs.sh
```

Repeat only for missing hosts.

## Useful commands

```bash
# Show running containers
docker ps

# NPM logs
docker logs npm --tail=200
docker exec npm tail -n 120 /data/logs/letsencrypt.log

# Validate compose output
docker compose -f docker-compose.yml -f docker-compose.app.yml config

# Show generated credentials
sh run.sh secrets
```

## Final checklist

- [ ] DNS points to the server.
- [ ] Ports `80` and `443` are reachable.
- [ ] `bash install-daiana.sh` completed.
- [ ] `sh run.sh secrets` prints credentials.
- [ ] NPM proxy hosts exist.
- [ ] Certificates were applied to required hosts.
- [ ] Public URLs match the lifecycle state: initial `*.nip.io` is `http`, after apply it is `https`, and after removal it is `http` again.
- [ ] Auth settings return enabled providers with an `apikey` header.
