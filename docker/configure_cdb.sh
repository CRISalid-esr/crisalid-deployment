#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage: $0 [dev|prod] [--reset | --dags-only]"
  echo ""
  echo "  dev|prod     Select docker-compose.{dev|prod}.yaml"
  echo "  --reset      Wipe Airflow metadata DB and other volumes (DANGEROUS)"
  echo "  --dags-only  Only refresh the DAGs code in cdb/dags, in place:"
  echo "               no .env regeneration, no container stop, no airflow-init"
}

# ------------------------------------------------------------------------------
# Args parsing
# ------------------------------------------------------------------------------

ENVIRONMENT=""
RESET=false
DAGS_ONLY=false

for arg in "$@"; do
  case "$arg" in
    dev|prod)
      ENVIRONMENT="$arg"
      ;;
    --reset)
      RESET=true
      ;;
    --dags-only)
      DAGS_ONLY=true
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

if [[ "$RESET" == "true" && "$DAGS_ONLY" == "true" ]]; then
  echo "--reset and --dags-only are mutually exclusive."
  usage
  exit 1
fi

COMPOSE_ARGS="-f $ROOT_DIR/docker-compose.${ENVIRONMENT}.yaml"

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

if [[ "$ENVIRONMENT" == "prod" ]]; then
  # Load only the value from .env.sample
  if [[ -f "$SHARED_ENV_FILE" ]]; then
    set -a
    source "$SHARED_ENV_FILE"
    set +a
  fi

  REPO_REF="${CDB_DAGS_REF:-main}"
else
  REPO_REF="dev-main"
fi

echo "Configuring CDB for environment: $ENVIRONMENT"
echo "Using DAGs repo ref: $REPO_REF"

TEMPLATE_ENV="$DAGS_DIR/.env.template"
FINAL_ENV="$DAGS_DIR/.env"

# Shallow-clone the DAGs repo into the given (non-existing) directory
# and strip what is not needed at runtime
clone_dags() {
  local target="$1"
  git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$target"
  echo "DAGs commit: $(git -C "$target" log -1 --format='%h %s')"
  rm -rf "$target/.github" "$target/.git" "$target/.gitignore" "$target/tests" "$target/test_utils"
}

# ------------------------------------------------------------------------------
# DAGs-only update: sync the code in place and leave everything else untouched
# ------------------------------------------------------------------------------

if [[ "$DAGS_ONLY" == "true" ]]; then
  if [[ ! -d "$DAGS_DIR" || ! -f "$FINAL_ENV" ]]; then
    echo "$DAGS_DIR is not configured yet: run '$0 $ENVIRONMENT' once first."
    exit 1
  fi

  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  clone_dags "$TMP_DIR/dags"

  if ! cmp -s "$TMP_DIR/dags/.env.template" "$TEMPLATE_ENV"; then
    echo ""
    echo "⚠️  .env.template changed in the DAGs repo:"
    diff -u "$TEMPLATE_ENV" "$TMP_DIR/dags/.env.template" || true
    echo ""
    echo "    $FINAL_ENV is NOT regenerated in --dags-only mode."
    echo "    Edit it by hand or run '$0 $ENVIRONMENT' (full reconfiguration)."
    echo ""
  fi

  # Sync in place (no rm -rf of the directory): the running containers bind-mount
  # cdb/dags and cdb/dags/.env, replacing them would detach the mounts.
  rsync -a --delete --exclude='/.env' --exclude='__pycache__/' "$TMP_DIR/dags/" "$DAGS_DIR/"

  echo "DAGs updated in $DAGS_DIR (containers untouched, Airflow will re-parse the DAG files)."
  exit 0
fi

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
clone_dags "$DAGS_DIR"

# ------------------------------------------------------------------------------
# 3. Generate .env from .env.sample with envsubst
# ------------------------------------------------------------------------------

echo "Generating $ENV_FILE from $ENV_SAMPLE_FILE"
export AIRFLOW_UID=$(id -u)
export AIRFLOW_PROJ_DIR="$CDB_DIR"
envsubst < "$ENV_SAMPLE_FILE" > "$ENV_FILE"

# ------------------------------------------------------------------------------
# 4. Generate DAGs .env file if template exists
# ------------------------------------------------------------------------------

if [ -f "$TEMPLATE_ENV" ]; then
  echo "\u2699 Found .env.template in DAGs repo, generating .env"

  export AMQP_USER="$CRISALID_BUS_USER"
  export AMQP_PASSWORD="$CRISALID_BUS_PASSWORD"
  export AMQP_HOST="${CRISALID_BUS_HOST:-crisalid-bus}"
  export AMQP_PORT="$CRISALID_BUS_AMQP_PORT"
  export CDB_REDIS_HOST=cdb-data-versioning-redis
  export CDB_REDIS_PORT=6379
  export CDB_REDIS_DB=0
  export RESTART_TRIGGER="$(date +%s)"
  export OVERRIDE_LDAP_STRUCTURE_DATA_FROM_SPREADSHEET="${OVERRIDE_LDAP_STRUCTURE_DATA_FROM_SPREADSHEET:-False}"

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
docker compose $COMPOSE_ARGS --profile cdb -f "$CDB_DIR/cdb.yaml" "${DOWN_ARGS[@]}"

echo "Running airflow-init..."
docker compose $COMPOSE_ARGS --profile cdb -f "$CDB_DIR/cdb.yaml" run --rm airflow-init

echo "Cleaning up old containers..."
docker compose $COMPOSE_ARGS --profile cdb -f "$CDB_DIR/cdb.yaml" down --remove-orphans
