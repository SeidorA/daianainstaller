# Certificate lifecycle

## Apply

```bash
bash apply-certs.sh
```

Apply completes NPM certificate setup, updates managed proxy hosts, verifies TLS,
then projects public URLs into `.env` and Vault before invoking
`update-daiana.sh --update`. The update recreates/redeploys the installer app
stack, including Supabase and URL-consuming Daiana services.

The lifecycle has three explicit URL states: initial installation uses `http`
for `*.nip.io` IP-DNS domains, applying any certificate switches all public
URLs to `https` (including `*.nip.io`), and removing certificates switches
them back to `http`. Other configured domains use `https` after installation
and certificate application. Internal Docker URLs are never rewritten.

## Removal

Removal is a separate, noninteractive operation and fails closed without
explicit confirmation:

```bash
bash remove-certs.sh --confirm
bash remove-certs.sh --confirm --certificate-id=4
bash remove-certs.sh --confirm --all-managed
```

It first detaches TLS from every managed NPM proxy host and confirms
`certificate_id=0`, forced HTTPS off, HSTS off, and HTTP/2 off. Only after that
does it stage the explicit `http` projection, update `.env` and Vault with compensation,
and invoke `update-daiana.sh --update` so Supabase Auth/Studio/Storage/
Functions/Kong and URL-consuming Daiana services consume the new values.

Certificate records are not deleted by default. `--certificate-id` selects one
record; `--all-managed` selects all records captured from managed hosts.
Each candidate is validated for positive ID, provider, name, and domains, is
refused while referenced by any proxy host, and is accepted only after an exact
NPM `404` reread. For Let's Encrypt this deletes the NPM record; it does **not**
revoke the certificate at the ACME CA.

## Modes
1. Let’s Encrypt
2. self-signed / local certs
3. custom cert files

## What it does
- only applies certificates
- does not create proxy hosts
- updates existing NPM hosts for `port.$BASE_DOMAIN` and `nginx.$BASE_DOMAIN`
- after every intended host passes TLS verification, refreshes the documented
  public URL variables in `.env` using the lifecycle projection above; internal
  Docker URLs, healthchecks, upstreams, and database URLs are never rewritten
- stages and validates the complete public URL set before replacing
  `.env`, upserts the matching values in one Vault transaction, then refreshes
  Portainer stacks
- auto-generates local/self-signed cert files when `TLS_MODE=local` and the files are missing
- supports `ONLY_PREFIX` to target a single proxy prefix (for example `port`, `nginx`, `supa`)

## Certificate verification semantics

- Let’s Encrypt records are verified with NPM provider/status (`letsencrypt` and
  `issued`), API hostname metadata, a future expiry, and an explicit trusted
  HTTPS GET.
- Custom uploads are NPM provider `other`; `status=null` is valid and the API
  `domain_names` list is not treated as a SAN list. The configured local PEM is
  parsed, checked for expiry and the requested hostname/SAN, then used for a
  trusted HTTPS GET. NPM expiry values in ISO `T...Z` and macOS space-formatted
  `YYYY-MM-DD HH:MM:SS` form are accepted; ambiguous values fail closed.
- For `*.nip.io` hosts, the trusted GET uses `--resolve` with the IPv4 address
  encoded by `BASE_DOMAIN`. `NPM_TLS_VERIFY_IP` may explicitly provide that
  address, but a missing, malformed, or conflicting address fails closed.

## Safe rollback boundary

Rollback PUTs use only NPM's mutable proxy-host projection: domains,
forward scheme/host/port, certificate and TLS flags, proxy behavior flags,
advanced configuration, enabled state, and locations. GET metadata such as
`id`, timestamps, and runtime-only fields is excluded; missing mutable fields
fail closed before a rollback request is sent.

Local/custom certificate record setup and upload complete before the service
loop can mutate any proxy host. An upload/setup failure therefore has no proxy
rollback boundary to cross: zero proxy hosts have changed, and the script
emits a redacted non-zero receipt with a reason ending in
`_before_proxy_mutation`.

After the first proxy-host mutation, issuance, proxy application, certificate
verification, or TLS failure uses compensating rollback. Before each mutation,
the bootstrap captures the complete restorable host state; every changed host
is then restored in reverse order and reread from NPM before the script emits
its redacted non-zero failure receipt. For a successful create whose response
has no usable ID, the bootstrap rereads the inventory and journals exactly one
new host only when its deterministic full payload and domain/forward tuple
matches; no match or an ambiguous match fails closed as rollback-incomplete and
requires manual cleanup. Newly created proxy hosts are removed only after an
explicit NPM 404 confirms absence. This boundary covers NPM
proxy-host configuration only; it does not claim migration rollback and does
not delete persistent database, certificate, volume, or network data.

When this recovery boundary cannot identify one host, the failure receipt uses
`NPM_BOOTSTRAP_REASON=..._rollback_incomplete_manual_cleanup_required`; this is
never a success receipt and must not be interpreted as confirmed cleanup.

## Examples
- `ONLY_PREFIX=port bash apply-certs.sh`
- `ONLY_PREFIX=supa bash apply-certs.sh`

## NPM readiness and recovery ordering

The bootstrap requires a real HTTP response from `NPM_API_URL/api/` before it
logs in or changes certificates. It uses bounded curl connect and operation
timeouts, retries transient connection failures, and exits non-zero with a
redacted `NPM_BOOTSTRAP_STATUS=FAILED` receipt if readiness, issuance, or
application fails. It never treats HTTP as a TLS fallback.

Public propagation ordering is strict: certificate setup/upload, proxy-host
mutation, and verification complete first; only a complete run without
`ONLY_PREFIX` may stage the full HTTPS `.env` projection, replace `.env`, run
one Vault transaction from that exact stage, and trigger the stack refresh.
These are separate resources, so the script does **not** claim cross-resource
atomicity. If Vault or stack refresh fails it performs best-effort, verified
compensation for both `.env` and Vault; a failed compensation retains redacted
diagnostics and never emits success. A stack refresh is not compensated by this
script: a failed refresh can leave runtime stack state partially changed and
requires manual stack reconciliation. Before the replacement/upsert boundary,
validation failures are a no-op.

Use these read-only diagnostics in this order:

```bash
# 1. Confirm the NPM container is running and inspect recent startup output.
docker ps --filter name=npm
docker logs --tail=200 npm

# 2. Probe the actual readiness endpoint without credentials or request bodies.
curl --connect-timeout 5 --max-time 15 -sS -D - -o /dev/null "$NPM_API_URL/api/"

# 3. If the host probe resets or times out, repeat it; do not log in or retry certificates yet.
for i in 1 2 3 4 5; do curl --connect-timeout 5 --max-time 15 -sS -o /dev/null -w '%{http_code}\n' "$NPM_API_URL/api/"; sleep 2; done

# 4. Once readiness is a valid HTTP response, inspect certificate state through
#    the authenticated API. Source a permission-restricted secret file (or use
#    your secret manager) first; never paste a token into this command or shell history.
set -a
. /secure/path/npm-admin.env  # defines NPM_API_TOKEN; keep this file secret
set +a
: "${NPM_API_TOKEN:?Source NPM_API_TOKEN securely before inspecting certificates}"
auth_file="$(mktemp)"
chmod 600 "$auth_file"
printf 'header = "Authorization: Bearer %s"\n' "$NPM_API_TOKEN" > "$auth_file"
curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
  --config "$auth_file" \
  "$NPM_API_URL/api/nginx/certificates?per_page=200"
rm -f "$auth_file"
unset NPM_API_TOKEN

# 5. Rerun the narrow certificate operation after the diagnostics are healthy.
ONLY_PREFIX=<prefix> TLS_MODE=letsencrypt bash apply-certs.sh

# 6. Verify the resulting public TLS handshake and hostname with a GET. This
#    avoids false failures from applications that reject HEAD. Replace
#    <expected-ip> with the endpoint IP only when bypassing DNS is required.
curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
  --connect-timeout 5 --max-time 15 \
  --resolve "<prefix>.<base-domain>:443:<expected-ip>" \
  -o /dev/null "https://<prefix>.<base-domain>/"

# Diagnostic-only: insecure probe when investigating an untrusted/self-signed certificate.
# Never use this command as a success gate.
curl --insecure --fail --silent --show-error --proto '=https' --tlsv1.2 \
  --connect-timeout 5 --max-time 15 -o /dev/null \
  "https://<prefix>.<base-domain>/"
```

Do not include `NPM_ADMIN_PASS`, tokens, cookies, database URLs, or
authorization headers in diagnostic output. If the bootstrap reports
`certificate_issuance_failed`, `certificate_application_failed_before_proxy_mutation`,
`certificate_verification_failed`, or a missing TLS result, correct the
underlying NPM/ACME condition and rerun the same narrow operation; the script
reuses existing certificate records safely. The pre-mutation suffix means no
proxy rollback was needed; post-mutation failure reasons identify whether
proxy hosts were restored or rollback was incomplete.
