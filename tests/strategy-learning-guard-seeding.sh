#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 },
    "learning": { "weight": 1.2, "success_rate": 0.75 }
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-existing-actionable-buffer",
      "title": "Keep the current actionable buffer occupied",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 3,
      "effort": 1,
      "confidence": 0.82,
      "score": 2.46,
      "status": "pending_approval",
      "created_at": "2026-03-23T07:55:00Z",
      "updated_at": "2026-03-23T07:55:00Z"
    },
    {
      "id": "task-existing-multi-attempt-success",
      "title": "Existing retried success fixture",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 4,
      "effort": 2,
      "confidence": 0.8,
      "score": 1.6,
      "status": "completed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:10:00Z",
      "execution": {
        "state": "completed",
        "attempt": 2,
        "result": "SUCCESS"
      }
    }
  ]
}
EOF

python3 - <<'PY' >"$TEST_ROOT/codex-memory/tasks.log"
import json
records = [
    {"project": "codex-agent-system", "task": "task-1", "result": "FAILURE", "attempts": 2, "score": 0, "failure_kind": "timeout"},
    {"project": "codex-agent-system", "task": "task-2", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-3", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-4", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-5", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-6", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-7", "result": "SUCCESS", "attempts": 2, "score": 1},
    {"project": "codex-agent-system", "task": "task-8", "result": "SUCCESS", "attempts": 2, "score": 1},
]
for record in records:
    print(json.dumps(record))
PY

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" \
  "$TEST_ROOT/codex-memory/tasks.json" \
  "$TEST_ROOT/codex-memory/tasks.log" \
  "$TEST_ROOT/codex-learning/metrics.json" >/dev/null

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-learning-guard.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-learning-guard.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)
with open(os.path.join(root, "codex-learning", "metrics.json"), "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert output["status"] == "success"
assert len(output["data"]["board_tasks"]) == 2
source_ids = {entry["source_task_id"] for entry in output["data"]["board_tasks"]}
assert source_ids == {"strategy::queue-drain-completion", "enterprise-readiness"}

titles = {task["title"] for task in registry["tasks"]}
assert "Keep an executable system-work buffer when the queue drains under low completion rate" in titles
assert "Make active worker ownership and progress explicit in the dashboard" in titles
assert metrics["first_pass_success_rate"] == 0
assert metrics["success_rate"] == 0.25
assert metrics["timeout_failure_records"] == 1
assert metrics["timeout_failure_rate"] == 0.12
assert metrics["low_first_pass_success_detected"] is True
assert metrics["first_pass_success_count"] == 0
assert metrics["multi_attempt_resolved_count"] == 1
assert metrics["retry_churn_detected"] is True
assert metrics["queue_starvation_detected"] is True
PY

echo "strategy learning guard seeding test passed"
