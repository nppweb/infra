#!/usr/bin/env bash

set -Eeuo pipefail

IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INFRA_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
DEPLOY_ROOT_DEFAULT=$(cd -- "$INFRA_DIR/.." && pwd)
DEPLOY_ROOT="${DEPLOY_PATH:-$DEPLOY_ROOT_DEFAULT}"
STATE_DIR="${DEPLOY_STATE_DIR:-$DEPLOY_ROOT/.deploy-state}"
LOCK_FILE="${DEPLOY_LOCK_FILE:-$STATE_DIR/deploy.lock}"
COMPOSE_ENV_FILE="${DEPLOY_ENV_FILE:-$INFRA_DIR/.env}"
WAIT_TIMEOUT="${DEPLOY_WAIT_TIMEOUT:-300}"
POLL_INTERVAL="${DEPLOY_POLL_INTERVAL:-5}"

MANAGED_REPOS=(infra npp-web npp-backend processing-worker scrape-helper contracts)

RELEASE_FILE=""
LIST_ONLY=0

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/rollback.sh [options]

Options:
  --release-file <path>   Roll back to an explicit release snapshot file.
  --list                  List available release snapshots.
  --help                  Show this help.

Default behavior:
  Rolls back to the previous successful release snapshot.
EOF
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: $command_name"
}

repo_path() {
  local repo_name="$1"

  case "$repo_name" in
    infra)
      printf '%s\n' "$INFRA_DIR"
      ;;
    npp-web | npp-backend | processing-worker | scrape-helper | contracts)
      printf '%s/%s\n' "$DEPLOY_ROOT" "$repo_name"
      ;;
    *)
      fail "Unknown repo: $repo_name"
      ;;
  esac
}

sha_var_name() {
  local repo_name="$1"

  case "$repo_name" in
    infra)
      printf 'REPO_SHA_INFRA\n'
      ;;
    npp-web)
      printf 'REPO_SHA_NPP_WEB\n'
      ;;
    npp-backend)
      printf 'REPO_SHA_NPP_BACKEND\n'
      ;;
    processing-worker)
      printf 'REPO_SHA_PROCESSING_WORKER\n'
      ;;
    scrape-helper)
      printf 'REPO_SHA_SCRAPE_HELPER\n'
      ;;
    contracts)
      printf 'REPO_SHA_CONTRACTS\n'
      ;;
    *)
      fail "Unknown repo: $repo_name"
      ;;
  esac
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --release-file)
        RELEASE_FILE="${2:-}"
        shift 2
        ;;
      --list)
        LIST_ONLY=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

list_releases() {
  local release_dir

  release_dir="$STATE_DIR/releases"
  [[ -d "$release_dir" ]] || fail "No release directory found: $release_dir"

  ls -1 "$release_dir"
}

resolve_release_file() {
  local release_dir selected_release

  if [[ -n "$RELEASE_FILE" ]]; then
    [[ -f "$RELEASE_FILE" ]] || fail "Release file not found: $RELEASE_FILE"
    return
  fi

  release_dir="$STATE_DIR/releases"
  [[ -d "$release_dir" ]] || fail "No release directory found: $release_dir"

  selected_release=$(ls -1 "$release_dir"/*.env 2>/dev/null | sort | tail -n 2 | head -n 1 || true)
  [[ -n "$selected_release" ]] || fail "Could not resolve previous release snapshot"

  RELEASE_FILE="$selected_release"
}

compose() {
  (
    cd "$INFRA_DIR"
    docker compose \
      --env-file "$COMPOSE_ENV_FILE" \
      -f docker-compose.yml \
      -f docker-compose.apps.yml \
      "$@"
  )
}

service_status() {
  local service_name="$1"
  local container_id

  container_id=$(compose ps -q "$service_name")
  [[ -n "$container_id" ]] || fail "Container ID not found for service '$service_name'"

  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_id"
}

wait_for_service() {
  local service_name="$1"
  local waited=0
  local status=""

  while ((waited < WAIT_TIMEOUT)); do
    status=$(service_status "$service_name")

    case "$status" in
      healthy | running)
        log "Service '$service_name' status: $status"
        return 0
        ;;
      exited | dead | unhealthy)
        fail "Service '$service_name' entered bad state: $status"
        ;;
      *)
        log "Waiting for service '$service_name' (status: $status)"
        ;;
    esac

    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done

  fail "Timed out waiting for service '$service_name' after ${WAIT_TIMEOUT}s"
}

wait_for_stack() {
  local services=(postgres redis rabbitmq minio backend-api processing-worker scraper-service frontend)
  local service_name

  for service_name in "${services[@]}"; do
    wait_for_service "$service_name"
  done
}

read_env_var() {
  local key="$1"
  local default_value="$2"
  local value=""

  if [[ -f "$COMPOSE_ENV_FILE" ]]; then
    value=$(awk -F= -v key="$key" '
      $0 !~ /^[[:space:]]*#/ && $1 == key {
        sub(/^[^=]*=/, "", $0)
        print $0
        exit
      }
    ' "$COMPOSE_ENV_FILE")
  fi

  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default_value"
  fi
}

check_http() {
  local name="$1"
  local url="$2"
  local waited=0

  while ((waited < WAIT_TIMEOUT)); do
    if curl --silent --show-error --fail "$url" >/dev/null; then
      log "HTTP check passed for '$name': $url"
      return 0
    fi

    log "Waiting for HTTP check '$name': $url"
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
  done

  fail "HTTP check failed for '$name' after ${WAIT_TIMEOUT}s: $url"
}

rollback_repo() {
  local repo_name="$1"
  local sha_var repo_sha repo_dir

  sha_var=$(sha_var_name "$repo_name")
  repo_sha="${!sha_var:-}"
  [[ -n "$repo_sha" ]] || fail "Release snapshot does not contain SHA for '$repo_name'"

  repo_dir=$(repo_path "$repo_name")

  [[ -d "$repo_dir/.git" ]] || fail "Missing git repo for '$repo_name': $repo_dir"
  if [[ -n "$(git -C "$repo_dir" status --porcelain)" ]]; then
    fail "Repository has uncommitted changes: $repo_dir"
  fi

  git -C "$repo_dir" fetch --prune origin
  log "Rolling back '$repo_name' to ${repo_sha}"
  git -C "$repo_dir" checkout --detach "$repo_sha"
}

main() {
  local backend_port frontend_port repo_name

  parse_args "$@"

  require_command git
  require_command docker
  require_command curl
  require_command flock

  if ((LIST_ONLY == 1)); then
    list_releases
    exit 0
  fi

  resolve_release_file

  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock -n 9 || fail "Another deploy or rollback is already running. Lock file: $LOCK_FILE"

  log "Using release snapshot: $RELEASE_FILE"

  # shellcheck disable=SC1090
  source "$RELEASE_FILE"

  for repo_name in "${MANAGED_REPOS[@]}"; do
    rollback_repo "$repo_name"
  done

  log "Validating docker compose configuration"
  compose config -q

  log "Recreating full stack from selected release"
  compose up -d --build --remove-orphans
  compose ps

  wait_for_stack

  backend_port=$(read_env_var BACKEND_PORT 3000)
  frontend_port=$(read_env_var FRONTEND_PORT 8080)

  check_http "backend-ready" "http://127.0.0.1:${backend_port}/api/health/ready"
  check_http "frontend-home" "http://127.0.0.1:${frontend_port}/"

  cp "$RELEASE_FILE" "$STATE_DIR/last-success.env"
  log "Rollback completed successfully"
}

main "$@"
