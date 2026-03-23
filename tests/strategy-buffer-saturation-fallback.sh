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
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-buffer-failed-oldest",
      "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 2,
      "confidence": 0.85,
      "score": 6.12,
      "status": "failed",
      "strategy_template": "system_work_buffer",
      "strategy_depth": 1,
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z",
      "failed_at": "2026-03-23T08:05:00Z"
    },
    {
      "id": "task-002-buffer-failed-latest",
      "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 2,
      "confidence": 0.85,
      "score": 6.12,
      "status": "failed",
      "strategy_template": "system_work_buffer",
      "strategy_depth": 1,
      "created_at": "2026-03-23T08:10:00Z",
      "updated_at": "2026-03-23T08:15:00Z",
      "failed_at": "2026-03-23T08:15:00Z"
    }
  ]
}
EOF

python3 - <<'PY' >"$TEST_ROOT/codex-memory/tasks.log"
import json
records = [
    {"project": "codex-agent-system", "task": "task-1", "result": "FAILURE", "score": 0},
    {"project": "codex-agent-system", "task": "task-2", "result": "FAILURE", "score": 0},
    {"project": "codex-agent-system", "task": "task-3", "result": "FAILURE", "score": 0},
    {"project": "codex-agent-system", "task": "task-4", "result": "SUCCESS", "score": 1},
]
for record in records:
    print(json.dumps(record))
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-buffer-saturation.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-buffer-saturation.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

assert output["status"] == "success"
assert len(output["data"]["board_tasks"]) == 2
source_ids = {entry["source_task_id"] for entry in output["data"]["board_tasks"]}
assert source_ids == {"enterprise-readiness"}

tasks = registry["tasks"]
titles = {task["title"] for task in tasks}
assert "Keep an executable system-work buffer when the queue drains under low completion rate" in titles
assert "Tighten the mobile dashboard into an enterprise control surface" in titles
assert "Make active worker ownership and progress explicit in the dashboard" in titles

enterprise_tasks = [task for task in tasks if task.get("source_task_id") == "enterprise-readiness::codex-agent-system"]
assert len(enterprise_tasks) == 2
assert all(task["status"] == "pending_approval" for task in enterprise_tasks)
assert not any(task.get("strategy_template") == "system_work_buffer" and task.get("status") == "pending_approval" for task in tasks)
PY

echo "strategy buffer saturation fallback test passed"
