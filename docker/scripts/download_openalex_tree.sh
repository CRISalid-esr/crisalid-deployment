#!/usr/bin/env bash
# Downloads OpenAlex topics/domains/fields/subfields snapshots.
# Requires only curl (standard on Debian/Ubuntu). Idempotent: skips existing files.
set -euo pipefail

BUCKET="https://openalex.s3.amazonaws.com"
ENTITIES=(topics domains fields subfields)
DEST="${1:-$(dirname "$(realpath "$0")")/../ikg/data/openalex}"

for entity in "${ENTITIES[@]}"; do
  echo "[$entity] fetching manifest..."
  manifest=$(curl -sf "${BUCKET}/data/jsonl/${entity}/manifest.json") || {
    echo "[$entity] ERROR: failed to fetch manifest" >&2; exit 1;
  }
  keys=$(echo "$manifest" | grep -oP '(?<="s3://openalex/)[^"]+\.gz')
  total=$(echo "$keys" | wc -l)
  echo "[$entity] $total file(s)"
  while IFS= read -r key; do
    # key = data/jsonl/<entity>/updated_date=.../part_XXXX.gz — strip leading "data/jsonl/"
    local_path="${DEST}/${key#data/jsonl/}"
    local_path="${local_path%.gz}"   # store decompressed
    [ -f "$local_path" ] && continue
    mkdir -p "$(dirname "$local_path")"
    chmod a+rwx "$(dirname "$local_path")"
    echo "  ${key#data/jsonl/}"
    curl -sf "${BUCKET}/${key}" | gunzip > "${local_path}.tmp"
    mv "${local_path}.tmp" "$local_path"
    chmod a+rw "$local_path"
  done <<< "$keys"
done

echo "Done. Data written to ${DEST}"