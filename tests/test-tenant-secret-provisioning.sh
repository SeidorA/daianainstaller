#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRIGGER="$ROOT_DIR/volumes/db/init/functions.sql"
MIGRATION="$ROOT_DIR/volumes/db/daiana-migrations/20260805120000_backfill_tenant_secrets.sql"
TEAMS_SECRET='waHW4b2Kfe_OoYXxnSUscqIMuESvQhunKt6deG1uXyU='

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[[ "$(grep -c "'secretSeed', gen_random_uuid()::text" "$TRIGGER")" -eq 2 ]] || fail "new-tenant trigger branches do not generate secretSeed"
[[ "$(grep -Fc "'teamsSecret', '$TEAMS_SECRET'" "$TRIGGER")" -eq 2 ]] || fail "new-tenant trigger branches do not set the Teams default"
grep -q "'created_by', NEW.id" "$TRIGGER" || fail "tenant creator field was removed"
grep -q "IF tenant_was_created THEN" "$TRIGGER" || fail "new-tenant team provisioning guard was removed"
pass "new-tenant trigger provisions both secret settings and preserves follow-up provisioning"

[[ "$(grep -Fc "'teamsSecret', '$TEAMS_SECRET'" "$MIGRATION")" -eq 1 ]] || fail "migration Teams default contract is missing"
grep -q "nullif(btrim(settings->>'secretSeed'), '') IS NULL" "$MIGRATION" || fail "secretSeed blank-value guard is missing"
grep -q "nullif(btrim(settings->>'teamsSecret'), '') IS NULL" "$MIGRATION" || fail "teamsSecret blank-value guard is missing"
grep -q "gen_random_uuid()::text" "$MIGRATION" || fail "secretSeed randomness contract is missing"
grep -q "ELSE '{}'::jsonb" "$MIGRATION" || fail "migration non-overwrite branches are missing"
if grep -Eiq '^[[:space:]]*(begin|commit|rollback|savepoint|release[[:space:]]+savepoint)[[:space:]]*;' "$MIGRATION"; then
  fail "migration must use the runner transaction"
fi
pass "backfill migration guards blank values, preserves valid values, and uses runner transaction"
