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

python3 - <<'PY' >"$TEST_ROOT/codex-memory/tasks.json"
import json
from datetime import datetime, timedelta, timezone

recent = (datetime.now(timezone.utc) - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")

tasks = [
    {
        "id": "task-001-buffer-recent-completed",
        "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
        "project": "codex-agent-system",
        "category": "stability",
        "status": "completed",
        "strategy_template": "queue_drain_completion_guard",
        "source_task_id": "strategy::queue-drain-completion",
        "root_source_task_id": "strategy::queue-drain-completion",
        "original_failed_root_id": "strategy::queue-drain-completion",
        "created_at": recent,
        "updated_at": recent,
        "completed_at": recent,
    },
    {
        "id": "task-010-enterprise-mobile-console",
        "title": "Tighten the mobile dashboard into an enterprise control surface",
        "project": "codex-agent-system",
        "category": "ui",
        "status": "completed",
        "strategy_template": "enterprise_mobile_console",
        "created_at": recent,
        "updated_at": recent,
        "completed_at": recent,
    },
    {
        "id": "task-011-enterprise-live-work-observability",
        "title": "Make active worker ownership and progress explicit in the dashboard",
        "project": "codex-agent-system",
        "category": "stability",
        "status": "completed",
        "strategy_template": "enterprise_live_work_observability",
        "created_at": recent,
        "updated_at": recent,
        "completed_at": recent,
    },
    {
        "id": "task-012-enterprise-audit-governance",
        "title": "Surface security, audit, and governance readiness in the dashboard",
        "project": "codex-agent-system",
        "category": "stability",
        "status": "completed",
        "strategy_template": "enterprise_audit_governance",
        "created_at": recent,
        "updated_at": recent,
        "completed_at": recent,
    },
    {
        "id": "task-013-enterprise-learning-feedback",
        "title": "Feed execution learning back into future provider and task decisions",
        "project": "codex-agent-system",
        "category": "code_quality",
        "status": "completed",
        "strategy_template": "enterprise_learning_feedback",
        "created_at": recent,
        "updated_at": recent,
        "completed_at": recent,
    },
    {
        "id": "task-014-enterprise-registry-pressure",
        "title": "Cut task-registry read amplification before growth stalls the loop",
        "project": "codex-agent-system",
        "category": "performance",
        "status": "completed",
        "strategy_template": "enterprise_registry_pressure_relief",
        "created_at": recent,
        "updated_at": recent,
        "completed_at": recent,
    },
]

print(json.dumps({"tasks": tasks}, indent=2))
PY

python3 - <<'PY' >"$TEST_ROOT/codex-memory/tasks.log"
import json

records = [
    {"project": "codex-agent-system", "task": "failure-1", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "failure-2", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "failure-3", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "success-1", "result": "SUCCESS", "attempts": 1, "score": 1},
]

for record in records:
    print(json.dumps(record))
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-buffer-cooldown.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-buffer-cooldown.json" <<'PY'
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
assert output["data"]["board_tasks"] == []

tasks = registry["tasks"]
assert len(tasks) == 6
assert sum(
    1
    for task in tasks
    if task["title"] == "Keep an executable system-work buffer when the queue drains under low completion rate"
) == 1
PY

echo "strategy buffer recent resolution cooldown test passed"
