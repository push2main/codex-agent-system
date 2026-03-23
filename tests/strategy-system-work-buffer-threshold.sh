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

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-only-executable-work",
      "title": "Keep the only executable task available",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 5,
      "effort": 2,
      "confidence": 0.8,
      "score": 3.6,
      "status": "approved",
      "created_at": "2026-03-23T10:00:00Z",
      "updated_at": "2026-03-23T10:00:00Z",
      "approved_at": "2026-03-23T10:00:00Z"
    },
    {
      "id": "task-010-enterprise-mobile-console",
      "title": "Tighten the mobile dashboard into an enterprise control surface",
      "project": "codex-agent-system",
      "category": "ui",
      "status": "completed",
      "strategy_template": "enterprise_mobile_console",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:05:00Z"
    },
    {
      "id": "task-011-enterprise-live-work-observability",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "completed",
      "strategy_template": "enterprise_live_work_observability",
      "created_at": "2026-03-23T09:06:00Z",
      "updated_at": "2026-03-23T09:10:00Z"
    },
    {
      "id": "task-012-enterprise-audit-governance",
      "title": "Surface security, audit, and governance readiness in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "completed",
      "strategy_template": "enterprise_audit_governance",
      "created_at": "2026-03-23T09:11:00Z",
      "updated_at": "2026-03-23T09:15:00Z"
    },
    {
      "id": "task-013-enterprise-learning-feedback",
      "title": "Feed execution learning back into future provider and task decisions",
      "project": "codex-agent-system",
      "category": "code_quality",
      "status": "completed",
      "strategy_template": "enterprise_learning_feedback",
      "created_at": "2026-03-23T09:16:00Z",
      "updated_at": "2026-03-23T09:20:00Z"
    }
  ]
}
EOF

python3 - <<'PY' >"$TEST_ROOT/codex-memory/tasks.log"
import json

records = [
    {"project": "codex-agent-system", "task": "task-a", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-b", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-c", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-d", "result": "SUCCESS", "attempts": 2, "score": 1}
]

for record in records:
    print(json.dumps(record))
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-buffer-threshold.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-buffer-threshold.json" <<'PY'
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
assert output["data"]["board_tasks"] == [
    {
        "id": "task-014-keep-an-executable-system-work-buffer-wh",
        "action": "created",
        "source_task_id": "strategy::queue-drain-completion",
    }
]

tasks = registry["tasks"]
buffer_tasks = [task for task in tasks if task.get("strategy_template") == "system_work_buffer"]
assert len(buffer_tasks) == 1
buffer_task = buffer_tasks[0]
assert buffer_task["title"] == "Keep an executable system-work buffer when the queue drains under low completion rate"
assert buffer_task["status"] == "pending_approval"
assert buffer_task["source_task_id"] == "strategy::queue-drain-completion"

approved_or_running = [
    task for task in tasks
    if task.get("project") == "codex-agent-system" and str(task.get("status") or "").lower() in {"approved", "running"}
]
assert len(approved_or_running) == 1
assert approved_or_running[0]["id"] == "task-001-only-executable-work"
PY

echo "strategy system work buffer threshold test passed"
