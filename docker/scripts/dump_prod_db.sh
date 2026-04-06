#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="/opt/crisalid/crisalid-deployment/docker"
DUMP_DIR="/opt/crisalid/db_dumps"

SVP_ENV="${BASE_DIR}/sovisuplus/.env"
HARV_ENV="${BASE_DIR}/harvester/.env"

mkdir -p "${DUMP_DIR}"
chmod 0755 "${DUMP_DIR}"

timestamp="$(date +%Y%m%d_%H%M%S)"

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

  # remove optional surrounding quotes
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"

  printf '%s' "$value"
}

dump_one() {
  local env_file="$1"
  local prefix="$2"
  local host_key="$3"
  local port_key="$4"
  local user_key="$5"
  local pass_key="$6"
  local name_key="$7"

  local host port user pass db outfile

  host="$(get_env_value "$env_file" "$host_key")"
  port="$(get_env_value "$env_file" "$port_key")"
  user="$(get_env_value "$env_file" "$user_key")"
  pass="$(get_env_value "$env_file" "$pass_key")"
  db="$(get_env_value "$env_file" "$name_key")"

  outfile="${DUMP_DIR}/${prefix}_${db}_${timestamp}.dump"

  log "Dumping ${db} from ${host}:${port} to ${outfile}"

  docker run --rm \
    -e PGPASSWORD="${pass}" \
    -v "${DUMP_DIR}:/dumps" \
    postgres:16 \
    pg_dump \
      -h "${host}" \
      -p "${port}" \
      -U "${user}" \
      -d "${db}" \
      -Fc \
      --no-owner \
      --no-privileges \
      -f "/dumps/$(basename "${outfile}")"

  log "Created ${outfile}"
}

dump_one "${SVP_ENV}"  "sovisuplus" "SVP_DB_HOST"       "SVP_DB_PORT"       "SVP_DB_USER"       "SVP_DB_PASSWORD"       "SVP_DB_NAME"
dump_one "${HARV_ENV}" "harvester"  "HARVESTER_DB_HOST" "HARVESTER_DB_PORT" "HARVESTER_DB_USER" "HARVESTER_DB_PASSWORD" "HARVESTER_DB_NAME"

log "Done"
ls -lh "${DUMP_DIR}"/*.dump
