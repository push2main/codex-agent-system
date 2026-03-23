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

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "auto",
  "updated_at": "2026-03-23T09:00:00Z"
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-pending-strategy-seed",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.83,
      "status": "pending_approval",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:00:00Z",
      "strategy_template": "enterprise_live_work_observability",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Make active worker ownership and progress explicit in the dashboard",
        "project": "codex-agent-system",
        "category": "stability"
      },
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system"
    },
    {
      "id": "task-other-approved-1",
      "title": "Keep queue status visible",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 5,
      "effort": 2,
      "confidence": 0.82,
      "status": "approved",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:00:00Z"
    },
    {
      "id": "task-other-approved-2",
      "title": "Keep worker ownership visible",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 5,
      "effort": 2,
      "confidence": 0.82,
      "status": "approved",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:00:00Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-auto-backfill.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-auto-backfill.json" <<'PY'
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
        "id": "task-pending-strategy-seed",
        "action": "updated",
        "source_task_id": "enterprise-readiness::codex-agent-system",
    }
]

task = next(task for task in registry["tasks"] if task["id"] == "task-pending-strategy-seed")
assert task["status"] == "approved"
assert task["queue_handoff"]["status"] == "queued"
assert task["execution_brief"]["status"] == "queued"
assert task["execution_provider"] == "codex"
assert task["history"][-1]["action"] == "approve"

with open(os.path.join(root, "queues", "codex-agent-system.txt"), "r", encoding="utf-8") as handle:
    queue_lines = [line.strip() for line in handle if line.strip()]

assert queue_lines == [
    "Make active worker ownership and progress explicit in the dashboard"
]
PY

echo "strategy auto approve backfill test passed"
