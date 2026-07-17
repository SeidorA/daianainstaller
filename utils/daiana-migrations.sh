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
  local migration_count=0
  local LC_ALL=C
  export LC_ALL

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

  [ -n "${POSTGRES_PASSWORD:-}" ] || die "POSTGRES_PASSWORD is required to run Daiana migrations"
  [ -n "${POSTGRES_DB:-}" ] || die "POSTGRES_DB is required to run Daiana migrations"
  command -v docker >/dev/null 2>&1 || die "docker is required to run Daiana migrations"
  migration_sql="$(mktemp "${TMPDIR:-/tmp}/daiana-migrations.XXXXXX")"
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
    rm -f "$migration_sql"
    die "No Daiana migration files found in $DAIANA_MIGRATIONS_DIR"
  fi

  log "Running $migration_count ordered Daiana migration file(s) as postgres"
  if docker_cmd exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DAIANA_DB_CONTAINER" \
      psql -X -h 127.0.0.1 -U postgres -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f /dev/stdin < "$migration_sql"; then
    rm -f "$migration_sql"
    log "Daiana migrations completed"
    return 0
  else
    rc=$?
    rm -f "$migration_sql"
    log "Daiana migrations failed; PostgreSQL rolled back migration and history changes"
    return "$rc"
  fi
}
