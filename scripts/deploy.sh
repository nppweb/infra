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
DEFAULT_BRANCH="${DEPLOY_BRANCH:-main}"
WAIT_TIMEOUT="${DEPLOY_WAIT_TIMEOUT:-300}"
POLL_INTERVAL="${DEPLOY_POLL_INTERVAL:-5}"

MANAGED_REPOS=(infra npp-web npp-backend processing-worker scrape-helper contracts)

TARGET_REPO=""
TARGET_BRANCH="$DEFAULT_BRANCH"
TARGET_SHA=""
SERVICES_OVERRIDE=""
AUTO_ROLLBACK=1
UPDATE_INFRA=1

declare -a UPDATED_REPOS=()
declare -a DEPLOY_SERVICES=()
declare -A BEFORE_SHA=()
declare -A AFTER_SHA=()

HANDLING_ERROR=0

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

warn() {
  log "WARN: $*"
}

fail() {
  log "ERROR: $*"
  return 1
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/deploy.sh --repo <repo-name> [options]

Options:
  --repo <name>           Repository to update. One of:
                          infra, npp-web, npp-backend, processing-worker,
                          scrape-helper, contracts.
  --branch <name>         Git branch to deploy. Default: main.
  --sha <commit>          Commit SHA from CI for logging/verification.
  --services <list>       Comma-separated docker compose services override.
  --no-auto-rollback      Disable automatic rollback on failure.
  --no-update-infra       Do not refresh infra repo before deploy.
  --help                  Show this help.

Examples:
  ./scripts/deploy.sh --repo infra
  ./scripts/deploy.sh --repo npp-web --sha 0123abcd
  ./scripts/deploy.sh --repo contracts --services processing-worker,scraper-service
EOF
}

require_command() {
  local command_name="$1"
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found: $command_name"
}

join_by() {
  local delimiter="$1"
  shift

  local first=1
  local item

  for item in "$@"; do
    if ((first == 1)); then
      printf '%s' "$item"
      first=0
    else
      printf '%s%s' "$delimiter" "$item"
    fi
  done
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

snapshot_var_name() {
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
      fail "Unknown repo for snapshot var: $repo_name"
      ;;
  esac
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --repo)
        TARGET_REPO="${2:-}"
        shift 2
        ;;
      --branch)
        TARGET_BRANCH="${2:-}"
        shift 2
        ;;
      --sha)
        TARGET_SHA="${2:-}"
        shift 2
        ;;
      --services)
        SERVICES_OVERRIDE="${2:-}"
        shift 2
        ;;
      --no-auto-rollback)
        AUTO_ROLLBACK=0
        shift
        ;;
      --no-update-infra)
        UPDATE_INFRA=0
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

  [[ -n "$TARGET_REPO" ]] || fail "--repo is required"
  [[ -n "$TARGET_BRANCH" ]] || fail "--branch cannot be empty"
}

ensure_repo_ready() {
  local repo_name="$1"
  local repo_dir

  repo_dir=$(repo_path "$repo_name")

  [[ -d "$repo_dir" ]] || fail "Repository directory not found: $repo_dir"
  [[ -d "$repo_dir/.git" ]] || fail "Directory is not a git repository: $repo_dir"

  if [[ -n "$(git -C "$repo_dir" status --porcelain)" ]]; then
    fail "Repository has uncommitted changes: $repo_dir"
  fi
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

git_sha() {
  local repo_dir="$1"
  git -C "$repo_dir" rev-parse HEAD
}

update_repo() {
  local repo_name="$1"
  local branch_name="$2"
  local repo_dir current_branch before_sha after_sha

  repo_dir=$(repo_path "$repo_name")
  before_sha=$(git_sha "$repo_dir")
  current_branch=$(git -C "$repo_dir" symbolic-ref -q --short HEAD || true)

  log "Updating repo '$repo_name' in '$repo_dir'"
  log "Repo '$repo_name' before: ${before_sha} (branch: ${current_branch:-detached})"

  git -C "$repo_dir" fetch --prune origin "$branch_name"

  if [[ -z "$current_branch" ]]; then
    warn "Repo '$repo_name' is on detached HEAD, switching back to '$branch_name'"
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch_name"; then
      git -C "$repo_dir" checkout "$branch_name"
    else
      git -C "$repo_dir" checkout -b "$branch_name" "origin/$branch_name"
    fi
  elif [[ "$current_branch" != "$branch_name" ]]; then
    warn "Repo '$repo_name' is on branch '$current_branch', switching to '$branch_name'"
    if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch_name"; then
      git -C "$repo_dir" checkout "$branch_name"
    else
      git -C "$repo_dir" checkout -b "$branch_name" "origin/$branch_name"
    fi
  fi

  git -C "$repo_dir" pull --ff-only origin "$branch_name"

  after_sha=$(git_sha "$repo_dir")
  BEFORE_SHA["$repo_name"]="$before_sha"
  AFTER_SHA["$repo_name"]="$after_sha"
  UPDATED_REPOS+=("$repo_name")

  log "Repo '$repo_name' after:  ${after_sha}"

  if [[ "$repo_name" == "$TARGET_REPO" && -n "$TARGET_SHA" ]]; then
    if git -C "$repo_dir" cat-file -e "${TARGET_SHA}^{commit}" 2>/dev/null; then
      if git -C "$repo_dir" merge-base --is-ancestor "$TARGET_SHA" "$after_sha"; then
        log "Target SHA ${TARGET_SHA} is included in deployed commit for '$repo_name'"
      else
        warn "Target SHA ${TARGET_SHA} is not an ancestor of deployed commit ${after_sha}"
      fi
    else
      warn "Target SHA ${TARGET_SHA} is not present in local git object database for '$repo_name'"
    fi
  fi
}

resolve_services() {
  if [[ -n "$SERVICES_OVERRIDE" ]]; then
    IFS=',' read -r -a DEPLOY_SERVICES <<<"$SERVICES_OVERRIDE"
    return
  fi

  case "$TARGET_REPO" in
    infra)
      DEPLOY_SERVICES=()
      ;;
    npp-web)
      DEPLOY_SERVICES=(frontend)
      ;;
    npp-backend)
      DEPLOY_SERVICES=(backend-api)
      ;;
    processing-worker)
      DEPLOY_SERVICES=(processing-worker)
      ;;
    scrape-helper)
      DEPLOY_SERVICES=(scraper-service)
      ;;
    contracts)
      DEPLOY_SERVICES=(processing-worker scraper-service)
      ;;
    *)
      fail "Unsupported target repo: $TARGET_REPO"
      ;;
  esac
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

wait_for_compose_services() {
  local services=("$@")

  if ((${#services[@]} == 0)); then
    services=(postgres redis rabbitmq minio backend-api processing-worker scraper-service frontend)
  fi

  for service_name in "${services[@]}"; do
    wait_for_service "$service_name"
  done
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

run_http_checks() {
  local backend_port frontend_port

  backend_port=$(read_env_var BACKEND_PORT 3000)
  frontend_port=$(read_env_var FRONTEND_PORT 8080)

  if ((${#DEPLOY_SERVICES[@]} == 0)); then
    check_http "backend-ready" "http://127.0.0.1:${backend_port}/api/health/ready"
    check_http "frontend-home" "http://127.0.0.1:${frontend_port}/"
    return
  fi

  for service_name in "${DEPLOY_SERVICES[@]}"; do
    case "$service_name" in
      backend-api)
        check_http "backend-ready" "http://127.0.0.1:${backend_port}/api/health/ready"
        ;;
      frontend)
        check_http "frontend-home" "http://127.0.0.1:${frontend_port}/"
        ;;
    esac
  done
}

print_compose_status() {
  log "docker compose ps"
  compose ps || true
}

print_recent_logs() {
  local services=("$@")

  if ((${#services[@]} == 0)); then
    services=(backend-api processing-worker scraper-service frontend)
  fi

  log "Recent docker compose logs"
  compose logs --tail=100 "${services[@]}" || true
}

write_release_snapshot() {
  local release_id release_dir release_file repo_name repo_dir repo_sha var_name services_value

  release_id=$(date -u +'%Y%m%dT%H%M%SZ')
  release_dir="$STATE_DIR/releases"
  release_file="$release_dir/${release_id}.env"
  services_value=""

  if ((${#DEPLOY_SERVICES[@]} > 0)); then
    services_value=$(join_by ',' "${DEPLOY_SERVICES[@]}")
  fi

  mkdir -p "$release_dir"

  {
    printf 'RELEASE_ID=%s\n' "$release_id"
    printf 'DEPLOYED_AT=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'TRIGGER_REPO=%s\n' "$TARGET_REPO"
    printf 'TRIGGER_BRANCH=%s\n' "$TARGET_BRANCH"
    printf 'TRIGGER_SHA=%s\n' "$TARGET_SHA"
    printf 'DEPLOY_SERVICES=%s\n' "${SERVICES_OVERRIDE:-$services_value}"
    for repo_name in "${MANAGED_REPOS[@]}"; do
      repo_dir=$(repo_path "$repo_name")
      repo_sha=$(git_sha "$repo_dir")
      var_name=$(snapshot_var_name "$repo_name")
      printf '%s=%s\n' "$var_name" "$repo_sha"
    done
  } >"$release_file"

  cp "$release_file" "$STATE_DIR/last-success.env"
  log "Saved release snapshot: $release_file"
}

restore_repo_to_sha() {
  local repo_name="$1"
  local sha="$2"
  local repo_dir

  repo_dir=$(repo_path "$repo_name")
  log "Restoring repo '$repo_name' to ${sha}"
  git -C "$repo_dir" checkout --detach "$sha"
}

rollback_failed_deploy() {
  local repo_name

  ((AUTO_ROLLBACK == 1)) || return 0
  ((${#UPDATED_REPOS[@]} > 0)) || return 0

  warn "Deployment failed, starting automatic rollback"

  for repo_name in "${UPDATED_REPOS[@]}"; do
    restore_repo_to_sha "$repo_name" "${BEFORE_SHA[$repo_name]}"
  done

  if ((${#DEPLOY_SERVICES[@]} == 0)); then
    compose up -d --build --remove-orphans
  else
    compose up -d --build --remove-orphans "${DEPLOY_SERVICES[@]}"
  fi

  wait_for_compose_services "${DEPLOY_SERVICES[@]}"
  run_http_checks
  warn "Automatic rollback completed successfully"
}

handle_error() {
  local exit_code=$?

  trap - ERR

  if ((HANDLING_ERROR == 1)); then
    exit "$exit_code"
  fi

  HANDLING_ERROR=1

  print_compose_status
  print_recent_logs "${DEPLOY_SERVICES[@]}"
  rollback_failed_deploy || true
  print_compose_status
  print_recent_logs "${DEPLOY_SERVICES[@]}"

  exit "$exit_code"
}

perform_deploy() {
  if ((UPDATE_INFRA == 1)) && [[ "$TARGET_REPO" != "infra" ]]; then
    ensure_repo_ready infra
    update_repo infra "$TARGET_BRANCH"
  fi

  ensure_repo_ready "$TARGET_REPO"
  update_repo "$TARGET_REPO" "$TARGET_BRANCH"
  resolve_services

  log "Validating docker compose configuration"
  compose config -q

  if ((${#DEPLOY_SERVICES[@]} == 0)); then
    log "Deploying full stack"
    compose up -d --build --remove-orphans
  else
    log "Deploying services: $(join_by ', ' "${DEPLOY_SERVICES[@]}")"
    compose up -d --build --remove-orphans "${DEPLOY_SERVICES[@]}"
  fi

  print_compose_status
  wait_for_compose_services "${DEPLOY_SERVICES[@]}"
  run_http_checks
  write_release_snapshot
  log "Production deploy finished successfully"
}

main() {
  parse_args "$@"

  require_command git
  require_command docker
  require_command curl
  require_command flock

  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"

  if ! flock -n 9; then
    log "ERROR: Another deploy is already running. Lock file: $LOCK_FILE"
    exit 1
  fi

  trap handle_error ERR

  log "Starting deploy"
  log "Target repo: $TARGET_REPO"
  log "Target branch: $TARGET_BRANCH"
  log "Target sha: ${TARGET_SHA:-not provided}"
  log "Deploy root: $DEPLOY_ROOT"
  log "Infra dir: $INFRA_DIR"
  log "Compose env file: $COMPOSE_ENV_FILE"
  log "Auto rollback: $AUTO_ROLLBACK"

  perform_deploy
  trap - ERR
}

main "$@"
