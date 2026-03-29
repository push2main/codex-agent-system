#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap resolve-automation-memory

PROJECT_NAME="${1:-}"
AUTOMATION_ID="${2:-}"

if [ -z "$PROJECT_NAME" ] || [ -z "$AUTOMATION_ID" ]; then
  python3 - <<'PY'
import json

print(json.dumps({
    "status": "fail",
    "message": "Usage: resolve-automation-memory.sh <project> <automation_id>",
    "data": {},
}, separators=(",", ":"), sort_keys=True))
PY
  exit 1
fi

memory_file=""
message="No automation memory available"
if resolve_automation_memory_read_file "$PROJECT_NAME" "$AUTOMATION_ID" >/dev/null 2>&1; then
  memory_file="${AUTOMATION_MEMORY_RESOLVED_FILE:-}"
  if [ "$AUTOMATION_MEMORY_RESOLVED_SOURCE" = "external" ] && [ "${AUTOMATION_MEMORY_EXTERNAL_HYDRATED:-false}" = "true" ]; then
    message="Hydrated external automation memory from workspace mirror"
  elif [ "$AUTOMATION_MEMORY_RESOLVED_SOURCE" = "external" ]; then
    message="Resolved external automation memory"
  else
    message="Using workspace automation memory mirror"
  fi
fi

python3 - "$memory_file" "$message" "${AUTOMATION_MEMORY_RESOLVED_SOURCE:-none}" "${AUTOMATION_MEMORY_EXTERNAL_HYDRATED:-false}" "${AUTOMATION_MEMORY_EXTERNAL_SYNC_PENDING:-true}" <<'PY'
import json
import os
import sys

memory_file, message, source, hydrated_raw, pending_raw = sys.argv[1:]
hydrated = hydrated_raw.strip().lower() == "true"
pending = pending_raw.strip().lower() == "true"

payload = {
    "status": "success",
    "message": message,
    "data": {
        "exists": bool(memory_file),
        "memory_file": memory_file,
        "source": source,
        "external_hydrated": hydrated,
        "external_sync_pending": pending,
    },
}

if memory_file:
    payload["data"]["readable"] = os.path.isfile(memory_file)

print(json.dumps(payload, separators=(",", ":"), sort_keys=True))
PY
