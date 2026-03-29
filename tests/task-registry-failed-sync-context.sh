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
      "id": "task-explicit-kind",
      "title": "Preserve explicit timeout kind on failed sync",
      "project": "registry-smoke",
      "status": "running",
      "execution_provider": "codex",
      "updated_at": "2026-03-25T10:00:00Z",
      "history": []
    },
    {
      "id": "task-preserved-kind",
      "title": "Preserve prior timeout kind when failed sync omits it",
      "project": "registry-smoke",
      "status": "running",
      "execution_provider": "codex",
      "updated_at": "2026-03-25T10:01:00Z",
      "last_failure_kind": "timeout",
      "failure_context": {
        "task_id": "task-preserved-kind",
        "failure_kind": "timeout",
        "timestamp": "2026-03-25T09:59:00Z"
      },
      "history": []
    }
  ]
}
EOF

TASK_REGISTRY_FILE="$TASKS_FILE"
source "$ROOT_DIR/scripts/lib.sh"

sync_task_registry_execution_state \
  "registry-smoke" \
  "Preserve explicit timeout kind on failed sync" \
  "failed" \
  "execute_failure" \
  "Timed out before any step started." \
  "1" \
  "2" \
  "codex" \
  "lane-1" \
  "" \
  "0" \
  "task-explicit-kind" \
  "timeout"

sync_task_registry_execution_state \
  "registry-smoke" \
  "Preserve prior timeout kind when failed sync omits it" \
  "failed" \
  "non_retryable_guard" \
  "Task blocked by non-retryable failure guard." \
  "2" \
  "2" \
  "codex" \
  "lane-2" \
  "" \
  "0" \
  "task-preserved-kind"

jq -e '
  (.tasks[] | select(.id == "task-explicit-kind")) as $explicit |
  (.tasks[] | select(.id == "task-preserved-kind")) as $preserved |
  $explicit.status == "failed" and
  $explicit.execution.failure_kind == "timeout" and
  $explicit.execution_context.result == "FAILURE" and
  $explicit.execution_context.failure_kind == "timeout" and
  $explicit.execution_context.task_id == "task-explicit-kind" and
  $explicit.execution_context.failed_step == "Timed out before any step started." and
  $explicit.last_failure_kind == "timeout" and
  $explicit.failure_context.failure_kind == "timeout" and
  $explicit.failure_context.task_id == "task-explicit-kind" and
  $explicit.failure_context.provider == "codex" and
  $explicit.failure_context.failed_step_index == 0 and
  $explicit.failure_context.failed_step == "Timed out before any step started." and
  ($explicit.failure_context.timestamp | type) == "string" and
  $preserved.status == "failed" and
  $preserved.execution.failure_kind == "timeout" and
  $preserved.execution_context.result == "FAILURE" and
  $preserved.execution_context.failure_kind == "timeout" and
  $preserved.execution_context.failed_step == "Task blocked by non-retryable failure guard." and
  $preserved.last_failure_kind == "timeout" and
  $preserved.failure_context.failure_kind == "timeout" and
  $preserved.failure_context.task_id == "task-preserved-kind" and
  $preserved.failure_context.provider == "codex" and
  $preserved.failure_context.failed_step == "Task blocked by non-retryable failure guard." and
  $preserved.execution.attempt == 2 and
  ($preserved.failure_context.timestamp | type) == "string"
' "$TASKS_FILE" >/dev/null

echo "task registry failed sync context test passed"
