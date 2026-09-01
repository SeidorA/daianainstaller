#!/usr/bin/env bash

DAIANA_MIGRATIONS_DIR="${DAIANA_MIGRATIONS_DIR:-volumes/db/daiana-migrations}"
DAIANA_DB_CONTAINER="${DAIANA_DB_CONTAINER:-supabase-db}"
DAIANA_MIGRATION_PROFILE="${DAIANA_MIGRATION_PROFILE:-standard}"
DAIANA_MIGRATION_LEDGER="${DAIANA_MIGRATION_LEDGER:-private.daiana_installer_schema_migrations}"

daiana_migration_effective_file() {
  local file="$1" output="$2"

  case "$DAIANA_MIGRATION_PROFILE:${file##*/}" in
    standard:*) DAIANA_MIGRATION_EFFECTIVE_FILE="$file" ;;
    legacy-daianastudio:20260717120000_add_shared_message_quota.sql)
      # The standard package provisions its seeded Studio mapping from the
      # canonical schema. Legacy installs must only accept explicit mappings.
      awk '
        /^CREATE OR REPLACE FUNCTION private\.provision_known_studio_mapping\(\)/ { skip = 1 }
        !skip { print }
        skip && /^SELECT private\.provision_known_studio_mapping\(\);$/ { skip = 0 }
      ' "$file" > "$output"
      DAIANA_MIGRATION_EFFECTIVE_FILE="$output"
      ;;
    legacy-daianastudio:20260812100000_add_studio_mapping_catalog.sql)
      # A later standard migration supplies the schema-aware catalog RPC.
      DAIANA_MIGRATION_EFFECTIVE_FILE=""
      ;;
    legacy-daianastudio:20260805120000_backfill_tenant_secrets.sql)
      # Runtime tenant secret provisioning requires separate approval and is
      # not part of the legacy schema-compatibility migration set.
      DAIANA_MIGRATION_EFFECTIVE_FILE=""
      ;;
    legacy-daianastudio:*) DAIANA_MIGRATION_EFFECTIVE_FILE="$file" ;;
    *) die "Unknown Daiana migration profile: $DAIANA_MIGRATION_PROFILE" ;;
  esac
}

daiana_migration_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | cut -d ' ' -f 1
  else
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  fi
}

daiana_migration_metadata() {
  local file="$1"
  local base version name
  base="${file##*/}"
  version="${base%%_*}"
  name="${base#*_}"
  name="${name%.sql}"
  case "$base" in *_*.sql) ;; *) die "Invalid Daiana migration filename: $base (expected <version>_<name>.sql)" ;; esac
  case "$version" in ''|*[!0-9]*) die "Invalid Daiana migration version in filename: $base" ;; esac
  case "$version$name" in
    *[!A-Za-z0-9._-]*) die "Unsafe Daiana migration filename: $base" ;;
  esac
  printf '%s|%s' "$version" "$name"
}

run_daiana_migrations() {
  local dry_run="${1:-0}"
  local installer_version migration_sql file effective_file effective_dir metadata version name checksum base rc opposite_ledger interlock_error
  local migration_count=0 output_file outcome_file result_file_owned=0
  local LC_ALL=C
  export LC_ALL
  DAIANA_MIGRATION_OUTCOME=unknown
  export DAIANA_MIGRATION_OUTCOME

  [ -d "$DAIANA_MIGRATIONS_DIR" ] || die "Daiana migrations directory is missing: $DAIANA_MIGRATIONS_DIR"
  case "$DAIANA_MIGRATION_PROFILE" in
    standard)
      opposite_ledger=private.daiana_legacy_daianastudio_schema_migrations
      ;;
    legacy-daianastudio)
      [ "$DAIANA_MIGRATION_LEDGER" = private.daiana_installer_schema_migrations ] && DAIANA_MIGRATION_LEDGER=private.daiana_legacy_daianastudio_schema_migrations
      opposite_ledger=private.daiana_installer_schema_migrations
      ;;
    *) die "Unknown Daiana migration profile: $DAIANA_MIGRATION_PROFILE" ;;
  esac
  installer_version="$(tr -d '[:space:]' < VERSION)"
  [ -n "$installer_version" ] || die "VERSION is empty"
  case "$installer_version" in *[!A-Za-z0-9._-]*) die "VERSION contains unsafe characters" ;; esac

  if [ "$dry_run" = "1" ]; then
    log "Dry-run: ordered Daiana migrations from $DAIANA_MIGRATIONS_DIR"
    for file in "$DAIANA_MIGRATIONS_DIR"/*.sql; do
      [ -e "$file" ] || continue
      effective_dir="$(mktemp -d "${TMPDIR:-/tmp}/daiana-migration-profile.XXXXXX")"
      daiana_migration_effective_file "$file" "$effective_dir/${file##*/}"
      effective_file="$DAIANA_MIGRATION_EFFECTIVE_FILE"
      [ -n "$effective_file" ] || continue
      metadata="$(daiana_migration_metadata "$file")"
      checksum="$(daiana_migration_sha256 "$effective_file")"
      rm -rf "$effective_dir"
      log "Would verify/apply ${file##*/} (version=${metadata%%|*}, sha256=$checksum)"
      migration_count=$((migration_count + 1))
    done
    [ "$migration_count" -gt 0 ] || die "No Daiana migration files found in $DAIANA_MIGRATIONS_DIR"
    return 0
  fi

  password_validation_xtrace_was_enabled=0
  case "$-" in *x*) password_validation_xtrace_was_enabled=1; set +x ;; esac
  [ -n "${POSTGRES_PASSWORD:-}" ] || die "POSTGRES_PASSWORD is required to run Daiana migrations"
  if (( password_validation_xtrace_was_enabled )); then set -x; fi
  [ -n "${POSTGRES_DB:-}" ] || die "POSTGRES_DB is required to run Daiana migrations"
  command -v docker >/dev/null 2>&1 || die "docker is required to run Daiana migrations"
  if [ -n "${DAIANA_MIGRATION_RESULT_FILE:-}" ]; then
    outcome_file="$DAIANA_MIGRATION_RESULT_FILE"
  else
    outcome_file="$(mktemp "${TMPDIR:-/tmp}/daiana-migrations-outcome.XXXXXX")"
    result_file_owned=1
  fi
  printf 'outcome=unknown\nstatus=125\n' > "$outcome_file"
  if (
    migration_sql="$(mktemp "${TMPDIR:-/tmp}/daiana-migrations.XXXXXX")"
    effective_dir="$(mktemp -d "${TMPDIR:-/tmp}/daiana-migration-profile.XXXXXX")"
    trap 'rm -f "${migration_sql:-}"; rm -rf "${effective_dir:-}"' EXIT
  {
    printf '%s\n' '\set ON_ERROR_STOP on'
    printf '%s\n' 'BEGIN;'
    printf '%s\n' "SELECT pg_advisory_xact_lock(1480867157, 1296651378);"
    # A known mixed manual update must be reconciled into a validated ledger,
    # not guessed by either schema profile.
    printf '%s\n' "SELECT to_regnamespace('daianastudio') IS NOT NULL"
    printf '%s\n' "   AND to_regnamespace('daianawebui') IS NOT NULL"
    printf '%s\n' "   AND to_regclass('public.tenant_studio_organization_mappings') IS NOT NULL"
    printf '%s\n' "   AND to_regclass('public.tenant_studio_workspace_mappings') IS NOT NULL"
    printf '%s\n' "   AND to_regclass('public.tenant_message_quota_periods') IS NOT NULL"
    printf '%s\n' "   AND to_regclass('public.tenant_message_quota_reservations') IS NOT NULL"
    printf '%s\n' "   AND to_regprocedure('private.provision_known_studio_mapping()') IS NOT NULL"
    printf '%s\n' "   AND NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass('public.history') AND attname = 'message_ref' AND NOT attisdropped)"
    printf '%s\n' "   AND to_regclass('public.figure_artifacts') IS NULL AS daiana_manual_mixed_footprint \\gset"
    printf '%s\n' "SELECT to_regclass('private.daiana_installer_schema_migrations') IS NOT NULL AS daiana_standard_ledger_exists, to_regclass('private.daiana_legacy_daianastudio_schema_migrations') IS NOT NULL AS daiana_legacy_ledger_exists \\gset"
    printf '%s\n' '\if :daiana_standard_ledger_exists'
    printf '%s\n' 'SELECT EXISTS (SELECT 1 FROM private.daiana_installer_schema_migrations) AS daiana_standard_profile_applied \gset'
    printf '%s\n' '\else'
    printf '%s\n' '\set daiana_standard_profile_applied false'
    printf '%s\n' '\endif'
    printf '%s\n' '\if :daiana_legacy_ledger_exists'
    printf '%s\n' 'SELECT EXISTS (SELECT 1 FROM private.daiana_legacy_daianastudio_schema_migrations) AS daiana_legacy_profile_applied \gset'
    printf '%s\n' '\else'
    printf '%s\n' '\set daiana_legacy_profile_applied false'
    printf '%s\n' '\endif'
    printf '%s\n' '\if :daiana_manual_mixed_footprint'
    printf '%s\n' '\if :daiana_standard_profile_applied'
    printf '%s\n' '\else'
    printf '%s\n' '\if :daiana_legacy_profile_applied'
    printf '%s\n' '\else'
    # shellcheck disable=SC2016 # Literal PostgreSQL dollar-quote sentinel.
    printf "DO %s BEGIN RAISE EXCEPTION 'Daiana migration manual-state interlock: detected a partial managed migration footprint without an applied standard or legacy ledger; refusing %s before DDL. Remediation: do not run either profile; reconcile and validate the migration ledger or use an approved recovery plan.'; END %s;\n" \
      '$daiana_manual_state_interlock$' "$DAIANA_MIGRATION_PROFILE" '$daiana_manual_state_interlock$'
    printf '%s\n' '\endif'
    printf '%s\n' '\endif'
    printf '%s\n' '\endif'
    # Check while holding the migration lock so concurrent profile starts
    # cannot both pass an empty-ledger preflight.
    printf "SELECT to_regclass('%s') IS NOT NULL AS daiana_opposite_ledger_exists \\gset\n" "$opposite_ledger"
    printf '%s\n' '\if :daiana_opposite_ledger_exists'
    printf "SELECT EXISTS (SELECT 1 FROM %s) AS daiana_opposite_profile_applied \\gset\n" "$opposite_ledger"
    printf '%s\n' '\if :daiana_opposite_profile_applied'
    # shellcheck disable=SC2016 # Literal PostgreSQL dollar-quote sentinel.
    printf "DO %s BEGIN RAISE EXCEPTION 'Daiana migration profile interlock: %s already has applied migrations; refusing %s before DDL'; END %s;\n" \
      '$daiana_profile_interlock$' "$opposite_ledger" "$DAIANA_MIGRATION_PROFILE" '$daiana_profile_interlock$'
    printf '%s\n' '\endif'
    printf '%s\n' '\endif'
    printf '%s\n' 'CREATE SCHEMA IF NOT EXISTS private AUTHORIZATION postgres;'
    printf '%s\n' 'REVOKE ALL ON SCHEMA private FROM PUBLIC;'
    printf 'CREATE TABLE IF NOT EXISTS %s (\n' "$DAIANA_MIGRATION_LEDGER"
    printf '%s\n' '  version text PRIMARY KEY,'
    printf '%s\n' '  name text NOT NULL,'
    printf '%s\n' '  checksum character(64) NOT NULL,'
    printf '%s\n' '  applied_at timestamptz NOT NULL DEFAULT now(),'
    printf '%s\n' '  installer_version text NOT NULL'
    printf '%s\n' ');'
    printf 'ALTER TABLE %s OWNER TO postgres;\n' "$DAIANA_MIGRATION_LEDGER"
    printf 'REVOKE ALL ON %s FROM PUBLIC, anon, authenticated, service_role;\n' "$DAIANA_MIGRATION_LEDGER"

    for file in "$DAIANA_MIGRATIONS_DIR"/*.sql; do
      [ -e "$file" ] || continue
      daiana_migration_effective_file "$file" "$effective_dir/${file##*/}"
      effective_file="$DAIANA_MIGRATION_EFFECTIVE_FILE"
      [ -n "$effective_file" ] || continue
      metadata="$(daiana_migration_metadata "$file")"
      version="${metadata%%|*}"
      name="${metadata#*|}"
      checksum="$(daiana_migration_sha256 "$effective_file")"
      base="${file##*/}"
      migration_count=$((migration_count + 1))

      printf "SELECT EXISTS (SELECT 1 FROM %s WHERE version = '%s' AND checksum = '%s') AS daiana_exact_applied \\gset\n" "$DAIANA_MIGRATION_LEDGER" "$version" "$checksum"
      printf '%s\n' '\if :daiana_exact_applied'
      printf '\\echo SKIP %s (version=%s, checksum verified)\n' "$base" "$version"
      printf '%s\n' '\else'
      # shellcheck disable=SC2016
      printf "DO %s BEGIN IF EXISTS (SELECT 1 FROM %s WHERE version = '%s') THEN RAISE EXCEPTION 'Daiana migration checksum drift for version %s' USING DETAIL = 'Packaged checksum: %s'; END IF; END %s;\n" \
        '$daiana_checksum$' "$DAIANA_MIGRATION_LEDGER" "$version" "$version" "$checksum" '$daiana_checksum$'
      printf '\\echo APPLY %s (version=%s, sha256=%s)\n' "$base" "$version" "$checksum"
      printf '%s\n' '-- installer migration file begins'
      command cat "$effective_file"
      printf '%s\n' '-- installer migration file ends'
      printf "INSERT INTO %s (version, name, checksum, installer_version) VALUES ('%s', '%s', '%s', '%s');\n" "$DAIANA_MIGRATION_LEDGER" "$version" "$name" "$checksum" "$installer_version"
      printf '\\echo APPLIED %s\n' "$base"
      printf '%s\n' '\endif'
    done
    printf '%s\n' 'COMMIT;'
  } > "$migration_sql"

  if [ "$migration_count" -eq 0 ]; then
    die "No Daiana migration files found in $DAIANA_MIGRATIONS_DIR"
  fi

  log "Running $migration_count ordered Daiana migration file(s) as supabase_admin"
  # The first line on stdin is consumed by the container-local shell and used
  # to create the libpq password environment. The migration SQL follows on the
  # same pipe, so the password never appears in docker's argv or process list.
  migration_xtrace_was_enabled=0
  case "$-" in
    *x*) migration_xtrace_was_enabled=1; set +x ;;
  esac
  output_file="$(mktemp "${TMPDIR:-/tmp}/daiana-migrations-output.XXXXXX")"
  if { printf '%s\n' "$POSTGRES_PASSWORD"; cat "$migration_sql"; } | \
      docker_cmd exec -i "$DAIANA_DB_CONTAINER" \
      sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql "$@"' sh \
      -X -h 127.0.0.1 -U supabase_admin -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /dev/stdin >"$output_file" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  if (( migration_xtrace_was_enabled )); then
    set -x
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f "$output_file" "$migration_sql"
    printf 'outcome=committed\nstatus=0\n' > "$outcome_file"
    exit 0
  else
    # A Docker client/transport failure, or a session killed while PostgreSQL
    # was consuming the transaction, does not prove rollback.  Keep the
    # distinction in-process so callers can leave a pending/manual marker.
    if grep -Eiq 'ERROR:|syntax error|checksum drift|permission denied|relation .* does not exist|duplicate key|violates|must be owner|invalid .* (value|input)' "$output_file"; then
      DAIANA_MIGRATION_OUTCOME=failed
    else
      # A non-zero client status without a positively identified SQL error is
      # ambiguous: the transaction may have committed before the session was
      # lost.  Callers must reconcile the live ledger instead of claiming a
      # rollback.
      DAIANA_MIGRATION_OUTCOME=unknown
    fi
    printf 'outcome=%s\nstatus=%s\n' "$DAIANA_MIGRATION_OUTCOME" "$rc" > "$outcome_file"
    interlock_error="$(grep -m 1 -E 'Daiana migration (profile|manual-state) interlock:' "$output_file" || true)"
    [ -z "$interlock_error" ] || log "$interlock_error"
    rm -f "$output_file" "$migration_sql"
    exit "$rc"
  fi
  ); then
    DAIANA_MIGRATION_OUTCOME=committed
    DAIANA_MIGRATION_STATUS=0
    export DAIANA_MIGRATION_STATUS
    log "Daiana migrations completed"
    [ "$result_file_owned" -eq 1 ] && rm -f "$outcome_file"
    return 0
  else
    rc=$?
    DAIANA_MIGRATION_OUTCOME="$(awk -F= '$1 == "outcome" { print $2; exit }' "$outcome_file" 2>/dev/null || printf unknown)"
    DAIANA_MIGRATION_OUTCOME="${DAIANA_MIGRATION_OUTCOME:-unknown}"
    DAIANA_MIGRATION_STATUS="$(awk -F= '$1 == "status" { print $2; exit }' "$outcome_file" 2>/dev/null || printf '%s' "$rc")"
    DAIANA_MIGRATION_STATUS="${DAIANA_MIGRATION_STATUS:-$rc}"
    export DAIANA_MIGRATION_STATUS
    export DAIANA_MIGRATION_OUTCOME
    if [ "${DAIANA_MIGRATION_OUTCOME:-unknown}" = unknown ]; then
      log "Daiana migrations returned an unknown database outcome; manual reconciliation is required"
    else
      log "Daiana migrations failed before the commit boundary"
    fi
    [ "$result_file_owned" -eq 1 ] && rm -f "$outcome_file"
    return "$rc"
  fi
}
