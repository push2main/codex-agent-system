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
      "id": "task-pending-approval",
      "title": "Existing approval-ready task",
      "impact": 6,
      "effort": 2,
      "confidence": 0.8,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Keep one pending task so strategy only has one free approval slot.",
      "hypothesis": "If one slot is open, failed follow-up ordering decides which family gets the next task.",
      "experiment": "Do not change this fixture task.",
      "success_criteria": [
        "Fixture remains pending."
      ],
      "rollback": "Remove the fixture task.",
      "score": 1.0,
      "status": "pending_approval",
      "created_at": "2026-03-23T10:00:00Z",
      "updated_at": "2026-03-23T10:00:00Z"
    },
    {
      "id": "task-approved-actionable",
      "title": "Existing approved task",
      "impact": 6,
      "effort": 2,
      "confidence": 0.8,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Keep enterprise seeding disabled once one follow-up is created.",
      "hypothesis": "The actionable backlog should stay at three after the chosen follow-up is added.",
      "experiment": "Do not change this fixture task.",
      "success_criteria": [
        "Fixture remains approved."
      ],
      "rollback": "Remove the fixture task.",
      "score": 1.0,
      "status": "approved",
      "created_at": "2026-03-23T10:01:00Z",
      "updated_at": "2026-03-23T10:01:00Z"
    },
    {
      "id": "task-stability-completed",
      "title": "Keep queue approvals deterministic",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "A prior stability task completed successfully.",
      "score": 1.0,
      "status": "completed",
      "created_at": "2026-03-23T10:02:00Z",
      "updated_at": "2026-03-23T10:05:00Z",
      "completed_at": "2026-03-23T10:05:00Z"
    },
    {
      "id": "task-stability-failed",
      "title": "Tighten queue worker recovery",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "This older failed family should win the next follow-up slot because stability already has a project-local success.",
      "score": 1.0,
      "status": "failed",
      "strategy_depth": 0,
      "created_at": "2026-03-23T10:10:00Z",
      "updated_at": "2026-03-23T10:11:00Z",
      "failed_at": "2026-03-23T10:11:00Z"
    },
    {
      "id": "task-learning-failed",
      "title": "Align persisted first-pass success metrics",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "category": "learning",
      "project": "codex-agent-system",
      "reason": "This newer failed family has no observed wins and should lose the last open follow-up slot.",
      "score": 1.0,
      "status": "failed",
      "strategy_depth": 0,
      "created_at": "2026-03-23T10:12:00Z",
      "updated_at": "2026-03-23T10:13:00Z",
      "failed_at": "2026-03-23T10:13:00Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-followup-learning-order.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-followup-learning-order.json" <<'PY'
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
        "id": "task-001-persist-structured-failure-context-for-s",
        "action": "created",
        "source_task_id": "task-stability-failed",
    }
]

created = next(task for task in registry["tasks"] if task["id"] == "task-001-persist-structured-failure-context-for-s")
assert created["source_task_id"] == "task-stability-failed"
assert created["strategy_template"] == "structured_failure_context"
assert created["status"] == "pending_approval"
assert not any(
    task.get("source_task_id") == "task-learning-failed"
    and task.get("status") == "pending_approval"
    and task.get("id") != "task-pending-approval"
    for task in registry["tasks"]
)
PY

echo "strategy followup learning order test passed"
