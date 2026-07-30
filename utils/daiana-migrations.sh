#!/usr/bin/env bash

DAIANA_MIGRATIONS_DIR="${DAIANA_MIGRATIONS_DIR:-volumes/db/daiana-migrations}"
DAIANA_DB_CONTAINER="${DAIANA_DB_CONTAINER:-supabase-db}"

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
  local installer_version migration_sql file metadata version name checksum base rc
  local migration_count=0 output_file outcome_file result_file_owned=0
  local LC_ALL=C
  export LC_ALL
  DAIANA_MIGRATION_OUTCOME=unknown
  export DAIANA_MIGRATION_OUTCOME

  [ -d "$DAIANA_MIGRATIONS_DIR" ] || die "Daiana migrations directory is missing: $DAIANA_MIGRATIONS_DIR"
  installer_version="$(tr -d '[:space:]' < VERSION)"
  [ -n "$installer_version" ] || die "VERSION is empty"
  case "$installer_version" in *[!A-Za-z0-9._-]*) die "VERSION contains unsafe characters" ;; esac

  if [ "$dry_run" = "1" ]; then
    log "Dry-run: ordered Daiana migrations from $DAIANA_MIGRATIONS_DIR"
    for file in "$DAIANA_MIGRATIONS_DIR"/*.sql; do
      [ -e "$file" ] || continue
      metadata="$(daiana_migration_metadata "$file")"
      checksum="$(daiana_migration_sha256 "$file")"
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
  trap 'rm -f "$migration_sql"' EXIT
  {
    printf '%s\n' '\set ON_ERROR_STOP on'
    printf '%s\n' 'BEGIN;'
    printf '%s\n' "SELECT pg_advisory_xact_lock(1480867157, 1296651378);"
    printf '%s\n' 'CREATE SCHEMA IF NOT EXISTS private AUTHORIZATION postgres;'
    printf '%s\n' 'REVOKE ALL ON SCHEMA private FROM PUBLIC;'
    printf '%s\n' 'CREATE TABLE IF NOT EXISTS private.daiana_installer_schema_migrations ('
    printf '%s\n' '  version text PRIMARY KEY,'
    printf '%s\n' '  name text NOT NULL,'
    printf '%s\n' '  checksum character(64) NOT NULL,'
    printf '%s\n' '  applied_at timestamptz NOT NULL DEFAULT now(),'
    printf '%s\n' '  installer_version text NOT NULL'
    printf '%s\n' ');'
    printf '%s\n' 'ALTER TABLE private.daiana_installer_schema_migrations OWNER TO postgres;'
    printf '%s\n' 'REVOKE ALL ON private.daiana_installer_schema_migrations FROM PUBLIC, anon, authenticated, service_role;'

    for file in "$DAIANA_MIGRATIONS_DIR"/*.sql; do
      [ -e "$file" ] || continue
      metadata="$(daiana_migration_metadata "$file")"
      version="${metadata%%|*}"
      name="${metadata#*|}"
      checksum="$(daiana_migration_sha256 "$file")"
      base="${file##*/}"
      migration_count=$((migration_count + 1))

      printf "SELECT EXISTS (SELECT 1 FROM private.daiana_installer_schema_migrations WHERE version = '%s' AND checksum = '%s') AS daiana_exact_applied \\gset\n" "$version" "$checksum"
      printf '%s\n' '\if :daiana_exact_applied'
      printf '\\echo SKIP %s (version=%s, checksum verified)\n' "$base" "$version"
      printf '%s\n' '\else'
      # shellcheck disable=SC2016
      printf "DO %s BEGIN IF EXISTS (SELECT 1 FROM private.daiana_installer_schema_migrations WHERE version = '%s') THEN RAISE EXCEPTION 'Daiana migration checksum drift for version %s' USING DETAIL = 'Packaged checksum: %s'; END IF; END %s;\n" \
        '$daiana_checksum$' "$version" "$version" "$checksum" '$daiana_checksum$'
      printf '\\echo APPLY %s (version=%s, sha256=%s)\n' "$base" "$version" "$checksum"
      printf '%s\n' '-- installer migration file begins'
      command cat "$file"
      printf '%s\n' '-- installer migration file ends'
      printf "INSERT INTO private.daiana_installer_schema_migrations (version, name, checksum, installer_version) VALUES ('%s', '%s', '%s', '%s');\n" "$version" "$name" "$checksum" "$installer_version"
      printf '\\echo APPLIED %s\n' "$base"
      printf '%s\n' '\endif'
    done
    printf '%s\n' 'COMMIT;'
  } > "$migration_sql"

  if [ "$migration_count" -eq 0 ]; then
    die "No Daiana migration files found in $DAIANA_MIGRATIONS_DIR"
  fi

  log "Running $migration_count ordered Daiana migration file(s) as postgres"
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
      -X -h 127.0.0.1 -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /dev/stdin >"$output_file" 2>&1; then
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
