#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
STATE_DIR="/var/lib/bash-scripts"
LOCK_FILE="/var/lock/laravel-deploy.lock"
LOG_FILE="/var/log/laravel-deploy.log"

APP_BASE_DIR="${APP_BASE_DIR:-/var/www/laravel-app}"
RELEASES_DIR="${APP_BASE_DIR}/releases"
SHARED_DIR="${APP_BASE_DIR}/shared"
CURRENT_LINK="${APP_BASE_DIR}/current"
TMP_DIR="${APP_BASE_DIR}/tmp"

REPO_URL="${REPO_URL:-}"
BRANCH="${BRANCH:-main}"
COMMIT_SHA="${COMMIT_SHA:-}"
DEPLOY_TAG="${DEPLOY_TAG:-}"

PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-true}"
MIGRATION_TIMING="${MIGRATION_TIMING:-pre}" # pre|post|skip
RUN_OPTIMIZE="${RUN_OPTIMIZE:-true}"
QUEUE_RESTART="${QUEUE_RESTART:-true}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"
HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-6}"
RUN_NPM_BUILD="${RUN_NPM_BUILD:-false}"
NPM_BIN="${NPM_BIN:-npm}"
QUIET="${QUIET:-true}"

RELEASE_ID=""
NEW_RELEASE_DIR=""
PREVIOUS_RELEASE=""
SWITCH_COMPLETED=false

log() {
  local level="$1"
  shift
  local message="$*"
  printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$message" >> "$LOG_FILE"
  if [[ "$QUIET" != "true" || "$level" == "ERROR" || "$level" == "WARN" ]]; then
    printf '%s [%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$message"
  fi
}

fail() {
  log "ERROR" "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    fail "Run as root: sudo bash ${SCRIPT_NAME}"
  fi
}

ensure_prereqs() {
  command_exists git || fail "git is required"
  command_exists "$PHP_BIN" || fail "PHP_BIN not found: $PHP_BIN"
  command_exists "$COMPOSER_BIN" || fail "COMPOSER_BIN not found: $COMPOSER_BIN"
  command_exists curl || fail "curl is required"
  if [[ "$RUN_NPM_BUILD" == "true" ]]; then
    command_exists "$NPM_BIN" || fail "NPM_BIN not found: $NPM_BIN"
  fi
}

validate_inputs() {
  [[ "$MIGRATION_TIMING" =~ ^(pre|post|skip)$ ]] || fail "MIGRATION_TIMING must be pre, post, or skip"
  [[ "$KEEP_RELEASES" =~ ^[0-9]+$ ]] || fail "KEEP_RELEASES must be a number"

  if [[ -z "$REPO_URL" && ! -L "$CURRENT_LINK" ]]; then
    fail "REPO_URL is required for first deployment (CURRENT_LINK does not exist)."
  fi
}

ensure_dirs() {
  install -d -m 0755 "$STATE_DIR" "$RELEASES_DIR" "$SHARED_DIR" "$TMP_DIR" "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  chmod 0640 "$LOG_FILE"

  install -d -m 0775 "$SHARED_DIR/storage" "$SHARED_DIR/bootstrap/cache"

  if [[ ! -f "$SHARED_DIR/.env" ]]; then
    if [[ -L "$CURRENT_LINK" && -f "$CURRENT_LINK/.env" ]]; then
      cp -a "$CURRENT_LINK/.env" "$SHARED_DIR/.env"
    else
      fail "Missing shared env file: $SHARED_DIR/.env"
    fi
  fi
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail "Another deployment is already in progress."
}

get_previous_release() {
  if [[ -L "$CURRENT_LINK" ]]; then
    PREVIOUS_RELEASE="$(readlink -f "$CURRENT_LINK" || true)"
  else
    PREVIOUS_RELEASE=""
  fi
}

resolve_release_id() {
  local ts short_ref
  ts="$(date -u +'%Y%m%d%H%M%S')"

  if [[ -n "$DEPLOY_TAG" ]]; then
    short_ref="$DEPLOY_TAG"
  elif [[ -n "$COMMIT_SHA" ]]; then
    short_ref="${COMMIT_SHA:0:12}"
  else
    short_ref="$BRANCH"
  fi

  RELEASE_ID="${ts}-${short_ref//[^a-zA-Z0-9._-]/_}"
  NEW_RELEASE_DIR="${RELEASES_DIR}/${RELEASE_ID}"
}

clone_or_copy_source() {
  if [[ -d "$NEW_RELEASE_DIR" ]]; then
    log "WARN" "Release directory already exists; reusing: $NEW_RELEASE_DIR"
    return 0
  fi

  if [[ -n "$REPO_URL" ]]; then
    log "INFO" "Fetching source from repository"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$NEW_RELEASE_DIR"

    if [[ -n "$COMMIT_SHA" ]]; then
      git -C "$NEW_RELEASE_DIR" fetch --depth 1 origin "$COMMIT_SHA"
      git -C "$NEW_RELEASE_DIR" checkout --detach "$COMMIT_SHA"
    elif [[ -n "$DEPLOY_TAG" ]]; then
      git -C "$NEW_RELEASE_DIR" fetch --depth 1 origin "refs/tags/${DEPLOY_TAG}:refs/tags/${DEPLOY_TAG}"
      git -C "$NEW_RELEASE_DIR" checkout --detach "refs/tags/${DEPLOY_TAG}"
    fi
  elif [[ -L "$CURRENT_LINK" ]]; then
    log "INFO" "REPO_URL omitted; cloning from current release"
    cp -a "$(readlink -f "$CURRENT_LINK")" "$NEW_RELEASE_DIR"
  else
    fail "Cannot source application code. Provide REPO_URL."
  fi

  rm -rf "$NEW_RELEASE_DIR/.git" || true
}

prepare_release() {
  log "INFO" "Preparing release: $RELEASE_ID"

  ln -sfn "$SHARED_DIR/.env" "$NEW_RELEASE_DIR/.env"
  rm -rf "$NEW_RELEASE_DIR/storage"
  ln -sfn "$SHARED_DIR/storage" "$NEW_RELEASE_DIR/storage"

  install -d -m 0775 "$SHARED_DIR/storage/framework" "$SHARED_DIR/storage/logs"

  pushd "$NEW_RELEASE_DIR" >/dev/null

  "$COMPOSER_BIN" install --no-interaction --prefer-dist --optimize-autoloader --no-dev --no-progress

  if [[ "$RUN_NPM_BUILD" == "true" ]]; then
    "$NPM_BIN" ci --silent
    "$NPM_BIN" run build --silent
  fi

  if [[ "$RUN_OPTIMIZE" == "true" ]]; then
    "$PHP_BIN" artisan config:cache
    "$PHP_BIN" artisan route:cache
    "$PHP_BIN" artisan view:cache
    "$PHP_BIN" artisan event:cache || true
  fi

  popd >/dev/null
}

run_migrations() {
  local timing="$1"

  [[ "$RUN_MIGRATIONS" == "true" ]] || return 0
  [[ "$MIGRATION_TIMING" == "$timing" ]] || return 0

  log "INFO" "Running migrations (${timing}-switch)"

  pushd "$NEW_RELEASE_DIR" >/dev/null
  if "$PHP_BIN" artisan migrate --help 2>/dev/null | grep -q -- '--isolated'; then
    "$PHP_BIN" artisan migrate --force --isolated
  else
    "$PHP_BIN" artisan migrate --force
  fi
  popd >/dev/null
}

switch_release_atomically() {
  log "INFO" "Switching current symlink atomically"

  ln -sfn "$NEW_RELEASE_DIR" "${CURRENT_LINK}.new"
  mv -Tf "${CURRENT_LINK}.new" "$CURRENT_LINK"
  SWITCH_COMPLETED=true
}

post_switch_tasks() {
  pushd "$CURRENT_LINK" >/dev/null

  if [[ "$QUEUE_RESTART" == "true" ]]; then
    "$PHP_BIN" artisan queue:restart || true
    "$PHP_BIN" artisan horizon:terminate || true
  fi

  "$PHP_BIN" artisan optimize:clear || true

  popd >/dev/null
}

healthcheck() {
  [[ -n "$HEALTHCHECK_URL" ]] || return 0

  log "INFO" "Running healthcheck: $HEALTHCHECK_URL"
  local i
  for ((i=1; i<=HEALTHCHECK_RETRIES; i++)); do
    if curl -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_URL" >/dev/null; then
      log "INFO" "Healthcheck passed on attempt $i/$HEALTHCHECK_RETRIES"
      return 0
    fi
    sleep 2
  done

  fail "Healthcheck failed after ${HEALTHCHECK_RETRIES} attempts: $HEALTHCHECK_URL"
}

cleanup_old_releases() {
  log "INFO" "Cleaning old releases (keep: $KEEP_RELEASES)"

  mapfile -t releases < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
  local count="${#releases[@]}"

  if (( count <= KEEP_RELEASES )); then
    return 0
  fi

  local remove_count=$((count - KEEP_RELEASES))
  local idx
  for ((idx=0; idx<remove_count; idx++)); do
    local rel="${releases[$idx]}"
    if [[ -n "$PREVIOUS_RELEASE" && "$(readlink -f "$rel")" == "$PREVIOUS_RELEASE" ]]; then
      continue
    fi
    if [[ "$(readlink -f "$rel")" == "$(readlink -f "$CURRENT_LINK")" ]]; then
      continue
    fi
    rm -rf "$rel"
  done
}

rollback_on_error() {
  local exit_code="$?"

  if [[ "$SWITCH_COMPLETED" == "true" && -n "$PREVIOUS_RELEASE" && -d "$PREVIOUS_RELEASE" ]]; then
    log "WARN" "Deploy failed after switch; rolling back to previous release"
    ln -sfn "$PREVIOUS_RELEASE" "${CURRENT_LINK}.rollback"
    mv -Tf "${CURRENT_LINK}.rollback" "$CURRENT_LINK"
  fi

  if [[ -n "$NEW_RELEASE_DIR" && -d "$NEW_RELEASE_DIR" && "$SWITCH_COMPLETED" != "true" ]]; then
    rm -rf "$NEW_RELEASE_DIR"
  fi

  log "ERROR" "Deployment failed with exit code $exit_code"
  exit "$exit_code"
}
trap rollback_on_error ERR

print_summary() {
  log "INFO" "Deployment successful"
  log "INFO" "Current release: $(readlink -f "$CURRENT_LINK")"
}

main() {
  require_root
  ensure_prereqs
  validate_inputs
  ensure_dirs
  acquire_lock
  get_previous_release
  resolve_release_id

  clone_or_copy_source
  prepare_release
  run_migrations pre
  switch_release_atomically
  run_migrations post
  post_switch_tasks
  healthcheck
  cleanup_old_releases
  print_summary
}

main "$@"
