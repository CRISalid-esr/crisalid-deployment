#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SAMPLE_FILE="$ROOT_DIR/crisalid-bus/definitions.sample.json"
OUTPUT_FILE="$ROOT_DIR/crisalid-bus/definitions.json"
ENCODER="$ROOT_DIR/encode_rabbitmq_password.sh"

# 1. Load variables from .env
if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
else
  echo ".env file not found at $ENV_FILE"
  exit 1
fi

# 2. Check required variables
: "${CRISALID_BUS_USER:?Missing CRISALID_BUS_USER}"
: "${CRISALID_BUS_PASSWORD:?Missing CRISALID_BUS_PASSWORD}"

# 3. Hash password
if [ ! -f "$ENCODER" ]; then
  echo "Password encoder script not found: $ENCODER"
  exit 1
fi

echo "Generating password hash for RabbitMQ user..."
export CRISALID_BUS_PASSWORD_HASH=$("$ENCODER" "$CRISALID_BUS_PASSWORD")

if [ -z "$CRISALID_BUS_PASSWORD_HASH" ]; then
  echo "Failed to generate password hash"
  exit 1
fi

# 4. Substitute into sample
echo "Generating definitions.json..."
envsubst '$CRISALID_BUS_USER $CRISALID_BUS_PASSWORD_HASH' < "$SAMPLE_FILE" > "$OUTPUT_FILE"

echo "Created $OUTPUT_FILE"
