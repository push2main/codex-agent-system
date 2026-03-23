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

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-failed-enterprise-seed",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.83,
      "status": "failed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:10:00Z",
      "failed_at": "2026-03-23T08:10:00Z",
      "strategy_template": "enterprise_live_work_observability",
      "strategy_depth": 1,
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Make active worker ownership and progress explicit in the dashboard",
        "project": "codex-agent-system",
        "category": "stability"
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-diversity.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-diversity.json" <<'PY'
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
assert all(entry["source_task_id"] == "enterprise-readiness" for entry in output["data"]["board_tasks"])

new_tasks = [task for task in registry["tasks"] if task["id"].startswith("task-00")]
assert {task["title"] for task in new_tasks} == {
    "Tighten the mobile dashboard into an enterprise control surface",
    "Make active worker ownership and progress explicit in the dashboard",
}
assert all(task["status"] == "pending_approval" for task in new_tasks)
PY

echo "strategy backlog diversity test passed"
