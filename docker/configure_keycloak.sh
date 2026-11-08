#!/usr/bin/env bash
set -euo pipefail

# Paths
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_ENV_FILE="$ROOT_DIR/.env"
KEYCLOAK_ENV_FILE="$ROOT_DIR/keycloak/.env"
# Env files of the services owning a Keycloak client: each one holds the secret of its client
SERVICE_ENV_FILES=(
  "$ROOT_DIR/sovisuplus/.env"
  "$ROOT_DIR/openwebui/.env"
  "$ROOT_DIR/crisalid-agents/.env"
)
KEYCLOAK_CONFIG_TEMPLATE_FILE="$ROOT_DIR/keycloak/config/crisalid-inst.json.template"
KEYCLOAK_CONFIG_FILE="$ROOT_DIR/keycloak/config/crisalid-inst.json"

# 1. Load variables from global .env
if [ -f "$GLOBAL_ENV_FILE" ]; then
  set -a
  source "$GLOBAL_ENV_FILE"
  set +a
else
  echo ".env file not found at $GLOBAL_ENV_FILE"
  exit 1
fi

# 2. Load variables from keycloak/.env
if [ -f "$KEYCLOAK_ENV_FILE" ]; then
  set -a
  source "$KEYCLOAK_ENV_FILE"
  set +a
else
  echo ".env file not found at $KEYCLOAK_ENV_FILE"
  exit 1
fi

# 3. Load the client secrets from the service env files (optional files: a missing one is reported at step 5)
for service_env_file in "${SERVICE_ENV_FILES[@]}"; do
  if [ -f "$service_env_file" ]; then
    set -a
    source "$service_env_file"
    set +a
  fi
done

# 4. Check if required variables are present in keycloak .env
: "${KEYCLOAK_ADMIN:?Missing KEYCLOAK_ADMIN in keycloak .env}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Missing KEYCLOAK_ADMIN_PASSWORD in keycloak .env}"
: "${KEYCLOAK_DB_VENDOR:?Missing KEYCLOAK_DB_VENDOR in keycloak .env}"
: "${KEYCLOAK_DB_PORT:?Missing KEYCLOAK_DB_PORT in keycloak .env}"
: "${KEYCLOAK_DB_NAME:?Missing KEYCLOAK_DB_NAME in keycloak .env}"
: "${KEYCLOAK_DB_USER:?Missing KEYCLOAK_DB_USER in keycloak .env}"
: "${KEYCLOAK_DB_PASSWORD:?Missing KEYCLOAK_DB_PASSWORD in keycloak .env}"

# 5. Check if required variables are present in global .env and in the service env files
: "${SOVISUPLUS_URL:?Missing SOVISUPLUS_URL in global .env}"
: "${OPENWEBUI_URL:?Missing OPENWEBUI_URL in global .env}"
: "${SOVISUPLUS_KEYCLOAK_CLIENT_SECRET:?Missing SOVISUPLUS_KEYCLOAK_CLIENT_SECRET in sovisuplus/.env}"
: "${OPENWEBUI_KEYCLOAK_CLIENT_SECRET:?Missing OPENWEBUI_KEYCLOAK_CLIENT_SECRET in openwebui/.env}"
: "${CRISALID_AGENTS_KEYCLOAK_CLIENT_SECRET:?Missing CRISALID_AGENTS_KEYCLOAK_CLIENT_SECRET in crisalid-agents/.env}"

# 6. Substitute and update the definitions.json for the Keycloak client
if [ -f "$KEYCLOAK_CONFIG_TEMPLATE_FILE" ]; then
  echo "Updating Keycloak client definitions..."

  # Substitute environment variables and create the Keycloak configuration
  envsubst '$KEYCLOAK_REALM $SOVISUPLUS_URL $SOVISUPLUS_KEYCLOAK_CLIENT_SECRET $OPENWEBUI_URL $OPENWEBUI_KEYCLOAK_CLIENT_SECRET $CRISALID_AGENTS_KEYCLOAK_CLIENT_SECRET $ORCID_CLIENT_ID $ORCID_CLIENT_SECRET' < "$KEYCLOAK_CONFIG_TEMPLATE_FILE" > "$KEYCLOAK_CONFIG_FILE"

  echo "Updated definitions file saved as crisalid-inst-updated.json"
else
  echo "Keycloak definitions file not found: $KEYCLOAK_CONFIG_TEMPLATE_FILE"
  exit 1
fi

echo "Keycloak configuration complete."
