#!/usr/bin/env bash

update_rollback_command() {
  local snapshot_dir="${1:-${LAST_UPDATE_SNAPSHOT_DIR:-}}"
  [ -n "$snapshot_dir" ] || return 1
  printf 'bash update-daiana.sh --rollback %s' "${snapshot_dir##*/}"
}

record_update_verification_failure() {
  local service="$1" endpoint="$2"
  local snapshot_dir="${LAST_UPDATE_SNAPSHOT_DIR:-}"
  local metadata tmp rollback_command

  [ -n "$snapshot_dir" ] || return 1
  metadata="$snapshot_dir/metadata.json"
  [ -f "$metadata" ] || return 1
  rollback_command="$(update_rollback_command "$snapshot_dir")" || return 1
  tmp="$(mktemp "$snapshot_dir/.metadata.recovery.XXXXXX")"
  if ! jq \
    --arg failed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg service "$service" \
    --arg endpoint "$endpoint" \
    --arg rollback_command "$rollback_command" \
    '.recovery = {
      status: "post-deploy-verification-failed",
      failed_at: $failed_at,
      service: $service,
      endpoint: $endpoint,
      rollback_command: $rollback_command,
      note: "Rollback restores the saved stack and Env only; it does not reverse migrations or persisted data."
    }' "$metadata" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$metadata"
}

verify_update_services() {
  local max_tries="${DAIANA_POST_DEPLOY_MAX_TRIES:-60}"
  local delay="${DAIANA_POST_DEPLOY_RETRY_DELAY:-2}"
  local service endpoint accept_redirect rollback_command

  while IFS='|' read -r service endpoint accept_redirect; do
    log "Verifying $service readiness at $endpoint"
    if ! wait_for_http "$endpoint" "$service readiness" "$max_tries" "$delay" "$accept_redirect" 0; then
      record_update_verification_failure "$service" "$endpoint" \
        || log "Could not persist post-deployment recovery metadata in ${LAST_UPDATE_SNAPSHOT_DIR:-the update snapshot}"
      if rollback_command="$(update_rollback_command)"; then
        log "$service did not become ready after $max_tries attempts. Review the snapshot and recover with: $rollback_command"
      else
        log "$service did not become ready after $max_tries attempts. No rollback snapshot is available; manual recovery is required."
      fi
      return 1
    fi
  done <<EOF
Daiana Next|${SITE_URL%/}/|1
Daiana Python|${BACKEND_BASE_URL%/}/api/v1/health|0
Daiana Studio|${STUDIO_BASE_URL%/}/api/v1/ping|0
EOF
}
