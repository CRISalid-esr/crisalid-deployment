#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/opt/crisalid/crisalid-deployment/docker"
DUMP_DIR="/opt/crisalid/backups"

SVP_ENV="${BASE_DIR}/sovisuplus/.env"
HARV_ENV="${BASE_DIR}/harvester/.env"

REQUIRED_CONFIRMATION_1="this is not the production server"
REQUIRED_CONFIRMATION_2="ok"

COMPOSE_CMD="docker compose -f docker-compose.yaml -f docker-compose.dev.yaml --profile sovisuplus --profile keycloak --profile crisalid-bus --profile harvester --profile cdb"

log() {
  printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*"
}

get_env_value() {
  local env_file="$1"
  local key="$2"
  local line value

  line="$(grep -E "^${key}=" "$env_file" | tail -n 1 || true)"

  if [ -z "$line" ]; then
    echo "Missing key ${key} in ${env_file}" >&2
    exit 1
  fi

  value="${line#*=}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"

  printf '%s' "$value"
}

validate_dump_file() {
  local dump_file="$1"
  local expected_prefix="$2"

  if [ ! -f "${dump_file}" ]; then
    echo "Dump file not found: ${dump_file}" >&2
    exit 1
  fi

  case "$(basename "${dump_file}")" in
    "${expected_prefix}"_*.dump)
      ;;
    *)
      echo "Unexpected dump filename: ${dump_file}" >&2
      echo "Expected a file starting with: ${expected_prefix}_" >&2
      exit 1
      ;;
  esac
}

confirm_not_production() {
  echo
  echo "WARNING: this script will overwrite development databases and restart services."
  echo "To continue, type exactly:"
  echo
  echo "  ${REQUIRED_CONFIRMATION_1}"
  echo
  printf '> '
  read -r confirmation

  if [ "${confirmation}" != "${REQUIRED_CONFIRMATION_1}" ]; then
    echo "First confirmation failed. Aborting." >&2
    exit 1
  fi
}

confirm_mapping() {
  local svp_dump="$1"
  local harv_dump="$2"
  local svp_db="$3"
  local harv_db="$4"

  echo
  echo "You confirmed that this is not the production server."
  echo
  echo "Restore plan:"
  echo "  sovisuplus database (${svp_db}) <- $(basename "${svp_dump}")"
  echo "  harvester database  (${harv_db}) <- $(basename "${harv_dump}")"
  echo
  echo "If this is correct, type exactly:"
  echo
  echo "  ${REQUIRED_CONFIRMATION_2}"
  echo
  printf '> '
  read -r confirmation

  if [ "${confirmation}" != "${REQUIRED_CONFIRMATION_2}" ]; then
    echo "Second confirmation failed. Aborting." >&2
    exit 1
  fi
}

stop_services() {
  log "Stopping services..."

  set +e
  ${COMPOSE_CMD} stop sovisuplus
  ${COMPOSE_CMD} stop harvester-ui
  ${COMPOSE_CMD} stop harvester-worker
  set -e

  log "Services stopped"
}

start_services() {
  log "Starting services..."

  ${COMPOSE_CMD} up -d sovisuplus harvester-ui harvester-worker

  log "Services started"
}

restore_one() {
  local env_file="$1"
  local dump_file="$2"
  local host_key="$3"
  local port_key="$4"
  local user_key="$5"
  local pass_key="$6"
  local name_key="$7"

  local host port user pass db

  host="$(get_env_value "$env_file" "$host_key")"
  port="$(get_env_value "$env_file" "$port_key")"
  user="$(get_env_value "$env_file" "$user_key")"
  pass="$(get_env_value "$env_file" "$pass_key")"
  db="$(get_env_value "$env_file" "$name_key")"

  log "Restoring ${dump_file} into ${db} (${host}:${port})"

  docker run --rm \
    -e PGPASSWORD="${pass}" \
    -v "$(dirname "${dump_file}"):/dumps" \
    postgres:16 \
    pg_restore \
      -h "${host}" \
      -p "${port}" \
      -U "${user}" \
      -d "${db}" \
      --clean \
      --if-exists \
      --no-owner \
      --no-privileges \
      "/dumps/$(basename "${dump_file}")"

  log "Restore completed for ${db}"
}

# --- arguments ---
if [ "$#" -ne 2 ]; then
  echo "Usage:"
  echo "  $0 <sovisuplus_dump> <harvester_dump>"
  exit 1
fi

SVP_DUMP="$1"
HARV_DUMP="$2"

validate_dump_file "${SVP_DUMP}" "sovisuplus"
validate_dump_file "${HARV_DUMP}" "harvester"

SVP_DB_NAME="$(get_env_value "${SVP_ENV}" "SVP_DB_NAME")"
HARV_DB_NAME="$(get_env_value "${HARV_ENV}" "HARVESTER_DB_NAME")"
SVP_DB_PORT="$(get_env_value "${SVP_ENV}" "SVP_DB_PORT")"
HARV_DB_PORT="$(get_env_value "${HARV_ENV}" "HARVESTER_DB_PORT")"

if [ "${SVP_DB_PORT}" = "5434" ] || [ "${HARV_DB_PORT}" = "5434" ]; then
  echo "Refusing to run: one target database uses port 5434, which looks like production." >&2
  exit 1
fi

confirm_not_production
confirm_mapping "${SVP_DUMP}" "${HARV_DUMP}" "${SVP_DB_NAME}" "${HARV_DB_NAME}"

stop_services

restore_one "${SVP_ENV}"  "${SVP_DUMP}"  "SVP_DB_HOST"       "SVP_DB_PORT"       "SVP_DB_USER"       "SVP_DB_PASSWORD"       "SVP_DB_NAME"
restore_one "${HARV_ENV}" "${HARV_DUMP}" "HARVESTER_DB_HOST" "HARVESTER_DB_PORT" "HARVESTER_DB_USER" "HARVESTER_DB_PASSWORD" "HARVESTER_DB_NAME"

start_services

log "All done"
