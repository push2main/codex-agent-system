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
      "status": "failed",
      "strategy_template": "system_work_buffer",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z",
      "failed_at": "2026-03-23T08:05:00Z"
    },
    {
      "id": "task-002-buffer-failed-latest",
      "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "strategy_template": "queue_drain_completion_guard",
      "source_task_id": "strategy::queue-drain-completion",
      "root_source_task_id": "strategy::queue-drain-completion",
      "original_failed_root_id": "strategy::queue-drain-completion",
      "created_at": "2026-03-23T08:10:00Z",
      "updated_at": "2026-03-23T08:15:00Z",
      "failed_at": "2026-03-23T08:15:00Z"
    },
    {
      "id": "task-003-buffer-recovered",
      "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "completed",
      "strategy_template": "queue_drain_completion_guard",
      "source_task_id": "strategy::queue-drain-completion",
      "root_source_task_id": "strategy::queue-drain-completion",
      "original_failed_root_id": "strategy::queue-drain-completion",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:05:00Z",
      "completed_at": "2026-03-23T09:05:00Z"
    },
    {
      "id": "task-004-existing-pending-a",
      "title": "Keep dashboard task shaping deterministic",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "pending_approval",
      "created_at": "2026-03-23T09:05:30Z",
      "updated_at": "2026-03-23T09:05:30Z"
    },
    {
      "id": "task-005-existing-pending-b",
      "title": "Keep queue health signals visible",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "pending_approval",
      "created_at": "2026-03-23T09:05:45Z",
      "updated_at": "2026-03-23T09:05:45Z"
    },
    {
      "id": "task-010-enterprise-mobile-console",
      "title": "Tighten the mobile dashboard into an enterprise control surface",
      "project": "codex-agent-system",
      "category": "ui",
      "status": "completed",
      "strategy_template": "enterprise_mobile_console",
      "created_at": "2026-03-23T09:06:00Z",
      "updated_at": "2026-03-23T09:10:00Z"
    },
    {
      "id": "task-011-enterprise-live-work-observability",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "completed",
      "strategy_template": "enterprise_live_work_observability",
      "created_at": "2026-03-23T09:11:00Z",
      "updated_at": "2026-03-23T09:15:00Z"
    },
    {
      "id": "task-012-enterprise-audit-governance",
      "title": "Surface security, audit, and governance readiness in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "completed",
      "strategy_template": "enterprise_audit_governance",
      "created_at": "2026-03-23T09:16:00Z",
      "updated_at": "2026-03-23T09:20:00Z"
    },
    {
      "id": "task-013-enterprise-learning-feedback",
      "title": "Feed execution learning back into future provider and task decisions",
      "project": "codex-agent-system",
      "category": "code_quality",
      "status": "completed",
      "strategy_template": "enterprise_learning_feedback",
      "created_at": "2026-03-23T09:21:00Z",
      "updated_at": "2026-03-23T09:25:00Z"
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
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-buffer-success-recovery.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-buffer-success-recovery.json" <<'PY'
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

buffer_tasks = [
    task for task in registry["tasks"]
    if task.get("strategy_template") == "system_work_buffer" and task.get("status") == "pending_approval"
]
assert len(buffer_tasks) == 1
assert buffer_tasks[0]["title"] == "Keep an executable system-work buffer when the queue drains under low completion rate"
PY

echo "strategy buffer success recovery test passed"
