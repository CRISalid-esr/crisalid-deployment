#!/usr/bin/env bash
set -euo pipefail

# Paths
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_ENV_FILE="$ROOT_DIR/.env"
CDB_DIR="$ROOT_DIR/cdb"
DAGS_DIR="$CDB_DIR/dags"
ENV_SAMPLE_FILE="$CDB_DIR/.env.sample"
ENV_FILE="$CDB_DIR/.env"
REPO_URL="https://github.com/CRISalid-esr/crisalid-directory-bridge"
REPO_BRANCH="dev-main"
TEMPLATE_ENV="$DAGS_DIR/.env.template"
FINAL_ENV="$DAGS_DIR/.env"

# 1. Load variables from docker/.env
if [ -f "$SHARED_ENV_FILE" ]; then
  set -a
  source "$SHARED_ENV_FILE"
  set +a
else
  echo ".env file not found at $SHARED_ENV_FILE"
  exit 1
fi

# 2. Prepare Airflow directory structure
echo "Preparing Airflow directories"
mkdir -p "$CDB_DIR/logs" "$CDB_DIR/plugins" "$CDB_DIR/config" "$CDB_DIR/data"
rm -rf "$DAGS_DIR"
git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$DAGS_DIR"
rm -rf "$DAGS_DIR/.github" "$DAGS_DIR/.git" "$DAGS_DIR/.gitignore" "$DAGS_DIR/tests" "$DAGS_DIR/test_utils"

# 3. Generate .env from .env.sample with envsubst
echo "Generating $ENV_FILE from $ENV_SAMPLE_FILE"
export AIRFLOW_UID=$(id -u)
envsubst < "$ENV_SAMPLE_FILE" > "$ENV_FILE"

# 4. Generate DAGs .env file if template exists
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

echo "Cleaning up old containers and volumes..."
docker compose --profile cdb -f "$CDB_DIR/cdb.yaml" down --volumes --remove-orphans

echo "Running airflow-init..."
docker compose --profile cdb -f "$CDB_DIR/cdb.yaml" run --rm airflow-init

echo "Cleaning up old containers..."
docker compose --profile cdb -f "$CDB_DIR/cdb.yaml" down