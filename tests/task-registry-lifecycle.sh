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
      "execution_provider": "claude",
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
    },
    {
      "id": "task-run-context-success",
      "title": "document stable success path",
      "impact": 5,
      "effort": 2,
      "confidence": 0.9,
      "category": "stability",
      "project": "registry-smoke",
      "reason": "Success-path fixture for deterministic task run context tests.",
      "execution_provider": "codex",
      "score": 2.25,
      "status": "approved",
      "created_at": "2026-03-22T15:11:00Z",
      "updated_at": "2026-03-22T15:11:00Z",
      "approved_at": "2026-03-22T15:11:00Z",
      "history": [
        {
          "at": "2026-03-22T15:11:00Z",
          "action": "approve",
          "from_status": "pending_approval",
          "to_status": "approved",
          "project": "registry-smoke",
          "queue_task": "document stable success path",
          "note": "Task was approved for later execution."
        }
      ]
    },
    {
      "id": "task-run-context-structured",
      "title": "preserve structured success evidence",
      "impact": 5,
      "effort": 2,
      "confidence": 0.88,
      "category": "stability",
      "project": "registry-smoke",
      "reason": "Structured success-path fixture for deterministic task run context tests.",
      "execution_provider": "codex",
      "score": 2.1,
      "status": "approved",
      "created_at": "2026-03-22T15:12:00Z",
      "updated_at": "2026-03-22T15:12:00Z",
      "approved_at": "2026-03-22T15:12:00Z",
      "execution_context": {
        "acceptance_evidence": [
          {
            "kind": "artifact",
            "path": "codex-memory/tasks.json"
          },
          [
            "verified",
            1
          ]
        ],
        "regression_checks": [
          {
            "command": "bash tests/task-registry-lifecycle.sh",
            "exit_code": 0
          }
        ]
      },
      "history": [
        {
          "at": "2026-03-22T15:12:00Z",
          "action": "approve",
          "from_status": "pending_approval",
          "to_status": "approved",
          "project": "registry-smoke",
          "queue_task": "preserve structured success evidence",
          "note": "Task was approved for later execution."
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
  "2" \
  "claude" \
  "lane-1"

jq -e '
  (.tasks | length) == 3 and
  (.tasks[] | select(.id == "task-registry-lifecycle")) as $task |
  $task.status == "running" and
  $task.execution.state == "running" and
  $task.execution.provider == "claude" and
  $task.execution.lane == "lane-1" and
  $task.execution.lease_state == "claimed" and
  ($task.execution.lease_claimed_at | type == "string") and
  $task.execution.result == "RUNNING" and
  $task.execution.attempt == 1 and
  (($task.history | last).lane == "lane-1") and
  ($task.history | last).action == "execute_start"
' "$TASKS_FILE" >/dev/null

sync_task_registry_execution_state \
  "registry-smoke" \
  "create hello world script in shell" \
  "approved" \
  "execute_retry" \
  "Queue execution failed and was requeued for another attempt." \
  "1" \
  "2" \
  "claude" \
  "lane-1"

jq -e '
  (.tasks[] | select(.id == "task-registry-lifecycle")) as $task |
  $task.status == "approved" and
  $task.execution.state == "retrying" and
  $task.execution.result == "FAILURE" and
  $task.execution.lease_state == "released" and
  ($task.execution.lease_released_at | type == "string") and
  $task.execution.will_retry == true and
  ($task.history | last).action == "execute_retry" and
  ($task.last_retry_at | type) == "string"
' "$TASKS_FILE" >/dev/null

sync_task_registry_execution_state \
  "registry-smoke" \
  "create hello world script in shell" \
  "running" \
  "execute_start" \
  "Queue execution started." \
  "2" \
  "2" \
  "claude" \
  "lane-2"

sync_task_registry_execution_state \
  "registry-smoke" \
  "create hello world script in shell" \
  "completed" \
  "execute_success" \
  "Queue execution completed successfully." \
  "2" \
  "2" \
  "claude" \
  "lane-2"

jq -e '
  (.tasks[] | select(.id == "task-registry-lifecycle")) as $task |
  $task.status == "completed" and
  $task.execution.state == "completed" and
  $task.execution.result == "SUCCESS" and
  $task.execution.lane == "lane-2" and
  $task.execution.lease_state == "released" and
  $task.execution.will_retry == false and
  ($task.completed_at | type) == "string" and
  ($task.history | length) == 5 and
  ($task.history | last).action == "execute_success"
' "$TASKS_FILE" >/dev/null

PLAN_FILE="$TMP_DIR/plan.json"
cat >"$PLAN_FILE" <<'EOF'
{
  "data": {
    "steps": [
      "Inspect the registry write path.",
      "Persist deterministic failure context."
    ]
  }
}
EOF

persist_task_run_context \
  "registry-smoke" \
  "create hello world script in shell" \
  "FAILURE" \
  "run-failure-001" \
  "2" \
  "2" \
  "0" \
  "84" \
  "5" \
  "1" \
  "2" \
  "Persist deterministic failure context." \
  "$PLAN_FILE" \
  "claude" \
  "2026-03-22T16:00:00Z"

persist_task_run_context \
  "registry-smoke" \
  "document stable success path" \
  "SUCCESS" \
  "run-success-001" \
  "1" \
  "1" \
  "9" \
  "41" \
  "3" \
  "3" \
  "0" \
  "" \
  "$PLAN_FILE" \
  "codex" \
  ""

persist_task_run_context \
  "registry-smoke" \
  "preserve structured success evidence" \
  "SUCCESS" \
  "run-success-002" \
  "1" \
  "1" \
  "7" \
  "32" \
  "2" \
  "2" \
  "0" \
  "" \
  "$PLAN_FILE" \
  "codex" \
  ""

jq -e '
  (.tasks | length) == 3 and
  (.tasks[] | select(.id == "task-registry-lifecycle")) as $failed |
  (.tasks[] | select(.id == "task-run-context-success")) as $success_default |
  (.tasks[] | select(.id == "task-run-context-structured")) as $success_structured |
  $failed.execution_context.run_id == "run-failure-001" and
  $failed.execution_context.provider == "claude" and
  $failed.execution_context.result == "FAILURE" and
  $failed.execution_context.attempts == 2 and
  $failed.execution_context.duration_seconds == 84 and
  $failed.execution_context.step_count == 5 and
  $failed.execution_context.completed_steps == 1 and
  $failed.execution_context.failed_step_index == 2 and
  $failed.execution_context.failed_step == "Persist deterministic failure context." and
  $failed.execution_context.plan_steps == [
    "Inspect the registry write path.",
    "Persist deterministic failure context."
  ] and
  $failed.failure_context.run_id == "run-failure-001" and
  $failed.failure_context.provider == "claude" and
  $failed.failure_context.task_id == "task-registry-lifecycle" and
  $failed.failure_context.attempts == 2 and
  $failed.failure_context.failed_step_index == 2 and
  $failed.failure_context.failed_step == "Persist deterministic failure context." and
  $failed.failure_context.timestamp == "2026-03-22T16:00:00Z" and
  ($failed.failure_context | has("result") | not) and
  ($failed.failure_context | has("updated_at") | not) and
  $failed.failure_context.original_failed_root_id == "task-registry-lifecycle" and
  $success_default.title == "document stable success path" and
  $success_default.status == "approved" and
  $success_default.execution_context.run_id == "run-success-001" and
  $success_default.execution_context.result == "SUCCESS" and
  $success_default.execution_context.acceptance_evidence == [] and
  $success_default.execution_context.regression_checks == [] and
  ($success_default | has("failure_context") | not) and
  ($success_default.history | length) == 1 and
  $success_structured.title == "preserve structured success evidence" and
  $success_structured.execution_context.run_id == "run-success-002" and
  $success_structured.execution_context.result == "SUCCESS" and
  $success_structured.execution_context.acceptance_evidence == [
    {
      "kind": "artifact",
      "path": "codex-memory/tasks.json"
    },
    [
      "verified",
      1
    ]
  ] and
  $success_structured.execution_context.regression_checks == [
    {
      "command": "bash tests/task-registry-lifecycle.sh",
      "exit_code": 0
    }
  ] and
  ($success_structured | has("failure_context") | not) and
  ($success_structured.history | length) == 1
' "$TASKS_FILE" >/dev/null

echo "task registry lifecycle test passed"
