#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 [dev|prod] [--reset]"
  echo ""
  echo "  dev|prod   Select docker-compose.{dev|prod}.yaml"
  echo "  --reset    Wipe Airflow metadata DB and other volumes (DANGEROUS)"
}

# ------------------------------------------------------------------------------
# Args parsing
# ------------------------------------------------------------------------------

ENVIRONMENT=""
RESET=false

for arg in "$@"; do
  case "$arg" in
    dev|prod)
      ENVIRONMENT="$arg"
      ;;
    --reset)
      RESET=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${ENVIRONMENT}" ]]; then
  echo "Missing environment."
  usage
  exit 1
fi

COMPOSE_ARGS="-f $ROOT_DIR/docker-compose.yaml -f $ROOT_DIR/docker-compose.${ENVIRONMENT}.yaml"

confirm_reset() {
  echo ""
  echo "⚠️  You are about to RESET Airflow state for environment: ${ENVIRONMENT}"
  echo "This will remove Docker volumes for the CDB profile (Airflow metadata DB, history, users, etc.)."
  echo ""
  read -r -p "Type RESET to confirm: " answer
  if [[ "$answer" != "RESET" ]]; then
    echo "Reset aborted."
    exit 1
  fi
}

# ------------------------------------------------------------------------------
# Paths
# ------------------------------------------------------------------------------

SHARED_ENV_FILE="$ROOT_DIR/.env"
CDB_DIR="$ROOT_DIR/cdb"
DAGS_DIR="$CDB_DIR/dags"
ENV_SAMPLE_FILE="$CDB_DIR/.env.sample"
ENV_FILE="$CDB_DIR/.env"
REPO_URL="https://github.com/CRISalid-esr/crisalid-directory-bridge"
REPO_BRANCH="dev-main"
TEMPLATE_ENV="$DAGS_DIR/.env.template"
FINAL_ENV="$DAGS_DIR/.env"

compose_cdb() {
  docker compose \
    --project-directory "$CDB_DIR" \
    $COMPOSE_ARGS \
    --profile cdb \
    -f "$CDB_DIR/cdb.yaml" \
    "$@"
}

# ------------------------------------------------------------------------------
# 1. Load variables from docker/.env
# ------------------------------------------------------------------------------

if [ -f "$SHARED_ENV_FILE" ]; then
  set -a
  source "$SHARED_ENV_FILE"
  set +a
else
  echo ".env file not found at $SHARED_ENV_FILE"
  exit 1
fi

# ------------------------------------------------------------------------------
# 2. Prepare Airflow directory structure
# ------------------------------------------------------------------------------

echo "Preparing Airflow directories"
mkdir -p "$CDB_DIR/logs" "$CDB_DIR/plugins" "$CDB_DIR/config" "$CDB_DIR/data"
rm -rf "$DAGS_DIR"
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$DAGS_DIR"
rm -rf "$DAGS_DIR/.github" "$DAGS_DIR/.git" "$DAGS_DIR/.gitignore" "$DAGS_DIR/tests" "$DAGS_DIR/test_utils"

# ------------------------------------------------------------------------------
# 3. Generate .env from .env.sample with envsubst
# ------------------------------------------------------------------------------

echo "Generating $ENV_FILE from $ENV_SAMPLE_FILE"
export AIRFLOW_UID=$(id -u)
envsubst < "$ENV_SAMPLE_FILE" > "$ENV_FILE"

# ------------------------------------------------------------------------------
# 4. Generate DAGs .env file if template exists
# ------------------------------------------------------------------------------

if [ -f "$TEMPLATE_ENV" ]; then
  echo "\u2699 Found .env.template in DAGs repo, generating .env"

  export AMQP_USER="$CRISALID_BUS_USER"
  export AMQP_PASSWORD="$CRISALID_BUS_PASSWORD"
  export AMQP_HOST="crisalid-bus"
  export AMQP_PORT="$CRISALID_BUS_AMQP_PORT"
  export CDB_REDIS_HOST=data-versioning-redis
  export CDB_REDIS_PORT=6379
  export CDB_REDIS_DB=0
  export RESTART_TRIGGER="$(date +%s)"

  # Required variables
  : "${LDAP_HOST:?Missing LDAP_HOST in environment}"
  : "${LDAP_BIND_DN:?Missing LDAP_BIND_DN in environment}"
  : "${LDAP_BIND_PASSWORD:?Missing LDAP_BIND_PASSWORD in environment}"

  # Optional paths
  export PEOPLE_SPREADSHEET_PATH="/opt/airflow/data/people.csv"
  export STRUCTURE_SPREADSHEET_PATH="/opt/airflow/data/structures.csv"
  export YAML_EMPLOYEE_TYPE_PATH="/opt/airflow/dags/conf/employee_types.yml"

  envsubst < "$TEMPLATE_ENV" > "$FINAL_ENV"
  echo "Generated $FINAL_ENV"
else
  echo "No .env.template found at $TEMPLATE_ENV, skipping .env generation"
fi

echo "CDB is configured. DAGs are ready in $DAGS_DIR"

# ------------------------------------------------------------------------------
# Compose operations
# ------------------------------------------------------------------------------

DOWN_ARGS=(down --remove-orphans)
if [[ "$RESET" == "true" ]]; then
  confirm_reset
  DOWN_ARGS=(down --volumes --remove-orphans)
fi

echo "Cleaning up old containers..."
compose_cdb "${DOWN_ARGS[@]}"

echo "Running airflow-init..."
compose_cdb run --rm airflow-init

echo "Cleaning up old containers..."
compose_cdb down --remove-orphans
