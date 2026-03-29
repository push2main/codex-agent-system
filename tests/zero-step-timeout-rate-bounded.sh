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

python3 - "$TASKS_FILE" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-timeout-resolved",
            "title": "Resolved timeout task",
            "project": "codex-agent-system",
            "category": "stability",
            "status": "completed",
            "created_at": "2026-03-25T08:00:00Z",
            "updated_at": "2026-03-25T08:10:00Z",
            "completed_at": "2026-03-25T08:10:00Z",
            "execution": {
                "state": "completed",
                "attempt": 3,
                "max_retries": 2,
                "result": "SUCCESS",
                "updated_at": "2026-03-25T08:10:00Z",
                "will_retry": False,
            },
            "execution_context": {
                "run_id": "run-timeout-resolved",
                "result": "SUCCESS",
                "attempts": 3,
                "updated_at": "2026-03-25T08:10:00Z",
            },
        }
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

cat >"$TASK_LOG_FILE" <<'EOF'
{"timestamp":"2026-03-25T08:01:00Z","project":"codex-agent-system","task":"Resolved timeout task","result":"FAILURE","failure_kind":"timeout","task_id":"task-timeout-resolved","attempts":1,"score":0,"run_id":"run-timeout-1","total_step_attempts":0}
{"timestamp":"2026-03-25T08:02:00Z","project":"codex-agent-system","task":"Resolved timeout task","result":"FAILURE","failure_kind":"timeout","task_id":"task-timeout-resolved","attempts":2,"score":0,"run_id":"run-timeout-2","total_step_attempts":0}
{"timestamp":"2026-03-25T08:03:00Z","project":"codex-agent-system","task":"Resolved timeout task","result":"FAILURE","failure_kind":"timeout","task_id":"task-timeout-resolved","attempts":3,"score":0,"run_id":"run-timeout-3","total_step_attempts":2}
EOF

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert metrics["timeout_failure_records"] == 0
assert metrics["zero_step_timeout_count"] == 2
assert metrics["zero_step_timeout_rate"] == 0.67
assert metrics["zero_step_timeout_rate"] <= 1
PY

echo "zero-step timeout rate bounded test passed"
