#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

TASKS_FILE="$TMP_DIR/tasks.json"
TASK_LOG_FILE="$TMP_DIR/tasks.log"
METRICS_FILE="$TMP_DIR/metrics.json"

timestamps="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone

now = datetime.now(timezone.utc)
print((now - timedelta(hours=8)).strftime("%Y-%m-%dT%H:%M:%SZ"))
print((now - timedelta(minutes=10)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

SUCCESS_AT="$(printf '%s\n' "$timestamps" | sed -n '1p')"
RUNNING_AT="$(printf '%s\n' "$timestamps" | sed -n '2p')"

python3 - "$TASKS_FILE" "$SUCCESS_AT" "$RUNNING_AT" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-last-success",
            "title": "Last successful completion",
            "project": "codex-agent-system",
            "status": "completed",
            "created_at": sys.argv[2],
            "updated_at": sys.argv[2],
            "completed_at": sys.argv[2],
            "execution": {
                "state": "completed",
                "attempt": 1,
                "max_retries": 2,
                "result": "SUCCESS",
                "updated_at": sys.argv[2],
                "will_retry": False,
            },
        },
        {
            "id": "task-active-running",
            "title": "Recent running task should keep pipeline live",
            "project": "codex-agent-system",
            "status": "running",
            "created_at": sys.argv[3],
            "updated_at": sys.argv[3],
            "execution": {
                "state": "running",
                "attempt": 1,
                "max_retries": 2,
                "result": "RUNNING",
                "updated_at": sys.argv[3],
                "will_retry": False,
            },
        },
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

cat >"$TASK_LOG_FILE" <<EOF
{"timestamp":"$SUCCESS_AT","project":"codex-agent-system","task":"Last successful completion","task_id":"task-last-success","result":"SUCCESS","attempts":1,"score":8}
EOF

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert metrics["running_tasks"] == 1
assert metrics["pipeline_stale"] is False
assert metrics["pipeline_stale_since"] is None
PY

echo "pipeline stale active-running test passed"
