#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Usage:
#   ./neo4j_offline_backup.sh [dev|prod]

ENV_NAME="${1:-dev}"

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
)

NEO4J_DATA_DIR="$ROOT_DIR/neo4j/data"
NEO4J_BACKUPS_DIR="$ROOT_DIR/neo4j/backups"

mkdir -p "$NEO4J_DATA_DIR"
mkdir -p "$NEO4J_BACKUPS_DIR"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
RUN_BACKUP_DIR="$NEO4J_BACKUPS_DIR/$TIMESTAMP"
mkdir -p "$RUN_BACKUP_DIR"

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
  echo "Backup failed with exit code $exit_code." >&2
  echo "Attempting to bring Neo4j and IKG back up..." >&2
  restart_stack || true
  exit "$exit_code"
}

trap cleanup_on_error ERR

log "Using environment: $ENV_NAME"
log "Neo4j admin image: $NEO4J_ADMIN_IMAGE"
log "Backup directory for this run: $RUN_BACKUP_DIR"

log "Stopping IKG first (graceful timeout: ${IKG_STOP_TIMEOUT}s)..."
"${COMPOSE_CMD[@]}" stop -t "$IKG_STOP_TIMEOUT" "$IKG_SERVICE_NAME"

log "Stopping Neo4j (graceful timeout: ${NEO4J_STOP_TIMEOUT}s)..."
"${COMPOSE_CMD[@]}" stop -t "$NEO4J_STOP_TIMEOUT" "$NEO4J_SERVICE_NAME"

log "Running offline Neo4j dump for databases: system, neo4j"
docker run --rm \
  --volume "$NEO4J_DATA_DIR:/data" \
  --volume "$RUN_BACKUP_DIR:/backups" \
  "$NEO4J_ADMIN_IMAGE" \
  neo4j-admin database dump system --to-path=/backups

docker run --rm \
  --volume "$NEO4J_DATA_DIR:/data" \
  --volume "$RUN_BACKUP_DIR:/backups" \
  "$NEO4J_ADMIN_IMAGE" \
  neo4j-admin database dump neo4j --to-path=/backups

log "Dump completed. Files created:"
ls -lh "$RUN_BACKUP_DIR"

restart_stack

log "Backup successful."