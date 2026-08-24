# DMO Manual Compatibility Package

This is a local-only, self-contained PostgreSQL package for the six approved legacy-safe Daiana compatibility operations plus one ACL-only corrective operation. It never uses Docker, Compose, an Installer checkout, or either Installer migration ledger.

It deliberately excludes tenant-secret backfill and the static Studio catalog migration. The vendored quota baseline has the fixed Studio mapping provisioner removed: mappings remain explicit and are never inferred.

## Use

Set normal libpq connection variables outside the package, then run:

```sh
bin/dmo-manual-compat preflight
bin/dmo-manual-compat plan
bin/dmo-manual-compat apply --backup-file /safe/backup.dump --backup-sha256 <sha256>
bin/dmo-manual-compat verify
```

`apply` validates the backup path and hash before opening PostgreSQL. A lost session is always reported as unknown; do not retry automatically, run `verify`.

Each operation has its own transaction and takes the existing global advisory lock. State is inferred from verified database objects. A complete prefix is skipped, an absent suffix is applied, and every partial, mixed, or unknown footprint fails closed before later DDL.

The final operation is an idempotent ACL repair. A database where all six compatibility operations already exist but replay-aware RPCs retain API-role grants is classified as a complete six-operation prefix; apply runs only the corrective ACL payload and does not rerun data or DDL operations.

The package fingerprints `daianawebui` metadata before and after apply. Its fingerprint must remain unchanged. Preflight rejects populated Installer ledgers, both Studio schema variants, missing prerequisites/API roles, mixed state, and an invalid WebUI fingerprint.
