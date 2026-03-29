#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
OUTPUT_FILE="$TMP_DIR/strategy-zombie-shelve.json"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-zombie-pending",
      "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 2,
      "confidence": 0.85,
      "score": 7.65,
      "status": "pending_approval",
      "created_at": "2026-03-26T00:55:00Z",
      "updated_at": "2026-03-26T00:55:00Z",
      "source_task_id": "strategy::queue-drain-completion",
      "root_source_task_id": "strategy::queue-drain-completion",
      "original_failed_root_id": "strategy::queue-drain-completion"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T09:00:00Z","project":"codex-agent-system","task":"Keep an executable system-work buffer when the queue drains under low completion rate","result":"FAILURE","failure_kind":"step_failure","task_id":"task-zombie-1"}
{"timestamp":"2026-03-25T09:10:00Z","project":"codex-agent-system","task":"Keep an executable system-work buffer when the queue drains under low completion rate","result":"FAILURE","failure_kind":"step_failure","task_id":"task-zombie-2"}
{"timestamp":"2026-03-25T09:20:00Z","project":"codex-agent-system","task":"Keep an executable system-work buffer when the queue drains under low completion rate","result":"FAILURE","failure_kind":"step_failure","task_id":"task-zombie-3"}
{"timestamp":"2026-03-25T09:30:00Z","project":"codex-agent-system","task":"Keep an executable system-work buffer when the queue drains under low completion rate","result":"FAILURE","failure_kind":"step_failure","task_id":"task-zombie-4"}
{"timestamp":"2026-03-25T09:40:00Z","project":"codex-agent-system","task":"Keep an executable system-work buffer when the queue drains under low completion rate","result":"FAILURE","failure_kind":"step_failure","task_id":"task-zombie-5"}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pending_approval_tasks": 1,
  "approved_tasks": 0,
  "task_registry_total": 1,
  "queue_starvation_detected": false,
  "retry_churn_detected": false,
  "low_completion_drain_detected": false
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$OUTPUT_FILE" >/dev/null
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$OUTPUT_FILE" <<'PY'
import json
import sys
from pathlib import Path

registry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
output = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

matching_tasks = [
    task for task in registry["tasks"]
    if task["title"] == "Keep an executable system-work buffer when the queue drains under low completion rate"
]
assert len(matching_tasks) == 1, matching_tasks
task = matching_tasks[0]
assert task["status"] == "shelved", task
assert task["shelved_reason"] == "zombie_guard: 5 prior failures exceed threshold of 5", task
assert task["history"][-1]["action"] == "zombie_guard", task["history"][-1]
assert task["history"][-1]["from_status"] == "pending_approval", task["history"][-1]
assert task["history"][-1]["to_status"] == "shelved", task["history"][-1]
assert task["history"][-1]["note"] == "Task shelved by zombie guard: 5 prior failures exceed threshold of 5.", task["history"][-1]

assert output["status"] == "success", output
assert output["message"].startswith("Applied "), output
assert {
    "id": "task-zombie-pending",
    "action": "shelved",
    "source_task_id": "strategy::queue-drain-completion",
} in output["data"]["board_updates"], output["data"]["board_updates"]
assert not any(
    task["title"] == "Keep an executable system-work buffer when the queue drains under low completion rate"
    and task["status"] in {"pending_approval", "approved", "running"}
    for task in registry["tasks"]
), registry["tasks"]
PY

echo "strategy zombie pending shelve test passed"
