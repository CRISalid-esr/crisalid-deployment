#!/usr/bin/env bash
# Downloads OpenAlex topics/domains/fields/subfields snapshots for the services that consume them.
# Requires only curl (standard on Debian/Ubuntu). Idempotent: skips existing files.
#
# Usage: download_openalex_tree.sh [crisalid-ikg|crisalid-taxi]
#   crisalid-ikg   -> docker/ikg/data/openalex
#   crisalid-taxi  -> docker/crisalid-taxi/data/openalex
#   (no argument)  -> both (each file is fetched once and copied to the other directory)
#
# Each service gets its own copy: IKG wipes its directory after importing the tree into Neo4j,
# while crisalid-taxi keeps reading its copy at every startup.
set -euo pipefail

BUCKET="https://openalex.s3.amazonaws.com"
ENTITIES=(topics domains fields subfields)
DOCKER_DIR="$(dirname "$(realpath "$0")")/.."

case "${1:-}" in
  "")            DESTS=("${DOCKER_DIR}/ikg/data/openalex" "${DOCKER_DIR}/crisalid-taxi/data/openalex") ;;
  crisalid-ikg)  DESTS=("${DOCKER_DIR}/ikg/data/openalex") ;;
  crisalid-taxi) DESTS=("${DOCKER_DIR}/crisalid-taxi/data/openalex") ;;
  *) echo "Usage: $0 [crisalid-ikg|crisalid-taxi]" >&2; exit 2 ;;
esac

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
    rel_path="${key#data/jsonl/}"
    rel_path="${rel_path%.gz}"   # store decompressed
    downloaded=""
    for dest in "${DESTS[@]}"; do
      local_path="${dest}/${rel_path}"
      [ -f "$local_path" ] && continue
      mkdir -p "$(dirname "$local_path")"
      chmod a+rwx "$(dirname "$local_path")"
      if [ -n "$downloaded" ]; then
        echo "  ${rel_path} -> ${dest} (copy)"
        cp "$downloaded" "$local_path"
      else
        echo "  ${rel_path} -> ${dest}"
        curl -sf "${BUCKET}/${key}" | gunzip > "${local_path}.tmp"
        mv "${local_path}.tmp" "$local_path"
        downloaded="$local_path"
      fi
      chmod a+rw "$local_path"
    done
  done <<< "$keys"
done

echo "Done. Data written to: ${DESTS[*]}"
