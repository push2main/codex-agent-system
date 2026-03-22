#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TASKS_FILE="$TMP_DIR/tasks.json"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

cat >"$TASKS_FILE" <<'EOF'
{
  "tasks": [
    {
      "id": "task-registry-lifecycle",
      "title": "create hello world script in shell",
      "impact": 7,
      "effort": 3,
      "confidence": 0.84,
      "category": "stability",
      "project": "registry-smoke",
      "reason": "Lifecycle fixture for deterministic registry execution tests.",
      "score": 2.94,
      "status": "approved",
      "created_at": "2026-03-22T15:10:00Z",
      "updated_at": "2026-03-22T15:10:00Z",
      "approved_at": "2026-03-22T15:10:00Z",
      "queue_handoff": {
        "at": "2026-03-22T15:10:00Z",
        "project": "registry-smoke",
        "task": "create hello world script in shell",
        "status": "queued"
      },
      "history": [
        {
          "at": "2026-03-22T15:10:00Z",
          "action": "approve",
          "from_status": "pending_approval",
          "to_status": "approved",
          "project": "registry-smoke",
          "queue_task": "create hello world script in shell",
          "note": "Task was enqueued after approval."
        }
      ]
    }
  ]
}
EOF

TASK_REGISTRY_FILE="$TASKS_FILE"
source "$ROOT_DIR/scripts/lib.sh"

sync_task_registry_execution_state \
  "registry-smoke" \
  "create hello world script in shell" \
  "running" \
  "execute_start" \
  "Queue execution started." \
  "1" \
  "2"

jq -e '
  (.tasks | length) == 1 and
  .tasks[0].status == "running" and
  .tasks[0].execution.state == "running" and
  .tasks[0].execution.result == "RUNNING" and
  .tasks[0].execution.attempt == 1 and
  (.tasks[0].history | last).action == "execute_start"
' "$TASKS_FILE" >/dev/null

sync_task_registry_execution_state \
  "registry-smoke" \
  "create hello world script in shell" \
  "approved" \
  "execute_retry" \
  "Queue execution failed and was requeued for another attempt." \
  "1" \
  "2"

jq -e '
  .tasks[0].status == "approved" and
  .tasks[0].execution.state == "retrying" and
  .tasks[0].execution.result == "FAILURE" and
  .tasks[0].execution.will_retry == true and
  (.tasks[0].history | last).action == "execute_retry" and
  (.tasks[0].last_retry_at | type) == "string"
' "$TASKS_FILE" >/dev/null

sync_task_registry_execution_state \
  "registry-smoke" \
  "create hello world script in shell" \
  "running" \
  "execute_start" \
  "Queue execution started." \
  "2" \
  "2"

sync_task_registry_execution_state \
  "registry-smoke" \
  "create hello world script in shell" \
  "completed" \
  "execute_success" \
  "Queue execution completed successfully." \
  "2" \
  "2"

jq -e '
  .tasks[0].status == "completed" and
  .tasks[0].execution.state == "completed" and
  .tasks[0].execution.result == "SUCCESS" and
  .tasks[0].execution.will_retry == false and
  (.tasks[0].completed_at | type) == "string" and
  (.tasks[0].history | length) == 5 and
  (.tasks[0].history | last).action == "execute_success"
' "$TASKS_FILE" >/dev/null

echo "task registry lifecycle test passed"
