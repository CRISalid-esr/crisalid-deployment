#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Usage from docker/ directory:
#   ./scripts/neo4j_offline_restore.sh [dev|prod] [backup-dir-name]
#
# Example:
#   ./scripts/neo4j_offline_restore.sh dev 2026-03-15_05-12-44

ENV_NAME="${1:-dev}"
BACKUP_NAME="${2:-}"

if [[ "$ENV_NAME" == "prod" ]]; then
  echo "Refusing to run against prod." >&2
  exit 1
fi

REQUIRED_CONFIRMATION_1="this is not the production server"
REQUIRED_CONFIRMATION_2="ok"

confirm_not_production() {
  echo
  echo "WARNING: this script will overwrite the Neo4j 'neo4j' database on this server."
  echo "To continue, type exactly:"
  echo
  echo "  ${REQUIRED_CONFIRMATION_1}"
  echo
  printf '> '
  read -r confirmation

  if [[ "$confirmation" != "$REQUIRED_CONFIRMATION_1" ]]; then
    echo "First confirmation failed. Aborting." >&2
    exit 1
  fi
}

confirm_restore_plan() {
  echo
  echo "Restore plan:"
  echo "  environment      : ${ENV_NAME}"
  echo "  backup directory : ${RESTORE_BACKUP_DIR}"
  echo "  database to load : neo4j"
  echo "  system database  : not restored"
  echo
  echo "If this is correct, type exactly:"
  echo
  echo "  ${REQUIRED_CONFIRMATION_2}"
  echo
  printf '> '
  read -r confirmation

  if [[ "$confirmation" != "$REQUIRED_CONFIRMATION_2" ]]; then
    echo "Second confirmation failed. Aborting." >&2
    exit 1
  fi
}

BASE_COMPOSE_FILE="$ROOT_DIR/docker-compose.yaml"
ENV_COMPOSE_FILE="$ROOT_DIR/docker-compose.${ENV_NAME}.yaml"
NEO4J_ENV_FILE="$ROOT_DIR/neo4j/.env"

if [[ ! -f "$BASE_COMPOSE_FILE" ]]; then
  echo "Base compose file not found: $BASE_COMPOSE_FILE" >&2
  exit 1
fi

if [[ ! -f "$ENV_COMPOSE_FILE" ]]; then
  echo "Environment compose file not found: $ENV_COMPOSE_FILE" >&2
  exit 1
fi

if [[ ! -f "$NEO4J_ENV_FILE" ]]; then
  echo "Neo4j env file not found: $NEO4J_ENV_FILE" >&2
  exit 1
fi

if [[ -z "$BACKUP_NAME" ]]; then
  echo "Missing backup directory name." >&2
  echo "Usage: ./neo4j_offline_restore.sh [dev|prod] [backup-dir-name]" >&2
  exit 1
fi

# Load Neo4j environment variables
set -a
source "$NEO4J_ENV_FILE"
set +a

: "${NEO4J_ADMIN_IMAGE:?Missing NEO4J_ADMIN_IMAGE in $NEO4J_ENV_FILE}"

COMPOSE_CMD=(
  docker compose
  -f "$BASE_COMPOSE_FILE"
  -f "$ENV_COMPOSE_FILE"
  --profile neo4j
  --profile ikg
  --profile crisalid-bus
)

NEO4J_DATA_DIR="$ROOT_DIR/neo4j/data"
NEO4J_BACKUPS_DIR="$ROOT_DIR/neo4j/backups"
RESTORE_BACKUP_DIR="$NEO4J_BACKUPS_DIR/$BACKUP_NAME"

if [[ ! -d "$RESTORE_BACKUP_DIR" ]]; then
  echo "Backup directory not found: $RESTORE_BACKUP_DIR" >&2
  exit 1
fi

if [[ ! -f "$RESTORE_BACKUP_DIR/neo4j.dump" ]]; then
  echo "Missing neo4j.dump in $RESTORE_BACKUP_DIR" >&2
  exit 1
fi

IKG_STOP_TIMEOUT="${IKG_STOP_TIMEOUT:-600}"
NEO4J_STOP_TIMEOUT="${NEO4J_STOP_TIMEOUT:-120}"

NEO4J_CONTAINER_NAME="${NEO4J_CONTAINER_NAME:-crisalid-neo4j}"
IKG_SERVICE_NAME="${IKG_SERVICE_NAME:-crisalid-ikg}"
NEO4J_SERVICE_NAME="${NEO4J_SERVICE_NAME:-neo4j}"

log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

wait_for_container_health() {
  local container_name="$1"
  local timeout="${2:-180}"
  local waited=0

  while true; do
    if ! docker inspect "$container_name" >/dev/null 2>&1; then
      echo "Container not found: $container_name" >&2
      return 1
    fi

    local status
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$container_name" 2>/dev/null || true)"

    case "$status" in
      healthy|running)
        return 0
        ;;
      unhealthy|exited|dead)
        echo "Container $container_name is in bad state: $status" >&2
        return 1
        ;;
    esac

    if (( waited >= timeout )); then
      echo "Timeout while waiting for $container_name to become healthy/running" >&2
      return 1
    fi

    sleep 2
    waited=$((waited + 2))
  done
}

restart_stack() {
  log "Restarting Neo4j..."
  "${COMPOSE_CMD[@]}" up -d "$NEO4J_SERVICE_NAME"

  log "Waiting for Neo4j to become healthy..."
  wait_for_container_health "$NEO4J_CONTAINER_NAME" 180

  log "Restarting IKG..."
  "${COMPOSE_CMD[@]}" up -d "$IKG_SERVICE_NAME"

  log "Restart completed."
}

cleanup_on_error() {
  local exit_code=$?
  echo
  echo "Restore failed with exit code $exit_code." >&2
  echo "Attempting to bring Neo4j and IKG back up..." >&2
  restart_stack || true
  exit "$exit_code"
}

trap cleanup_on_error ERR

confirm_not_production
confirm_restore_plan

log "Using environment: $ENV_NAME"
log "Neo4j admin image: $NEO4J_ADMIN_IMAGE"
log "Restore source directory: $RESTORE_BACKUP_DIR"

log "Stopping IKG first (graceful timeout: ${IKG_STOP_TIMEOUT}s)..."
"${COMPOSE_CMD[@]}" stop -t "$IKG_STOP_TIMEOUT" "$IKG_SERVICE_NAME"

log "Stopping Neo4j (graceful timeout: ${NEO4J_STOP_TIMEOUT}s)..."
"${COMPOSE_CMD[@]}" stop -t "$NEO4J_STOP_TIMEOUT" "$NEO4J_SERVICE_NAME"

log "Restoring database: neo4j"
docker run --rm \
  --volume "$NEO4J_DATA_DIR:/data" \
  --volume "$RESTORE_BACKUP_DIR:/backups" \
  "$NEO4J_ADMIN_IMAGE" \
  neo4j-admin database load neo4j --from-path=/backups --overwrite-destination=true

restart_stack

log "Restore successful."