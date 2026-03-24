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
      "hypothesis": "Only the highest-priority failed follow-up should be created.",
      "experiment": "Do not change this fixture task.",
      "success_criteria": [
        "Fixture remains pending."
      ],
      "rollback": "Remove the fixture task.",
      "score": 1.0,
      "status": "pending_approval",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z"
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
      "hypothesis": "The actionable backlog should stay bounded.",
      "experiment": "Do not change this fixture task.",
      "success_criteria": [
        "Fixture remains approved."
      ],
      "rollback": "Remove the fixture task.",
      "score": 1.0,
      "status": "approved",
      "created_at": "2026-03-24T08:01:00Z",
      "updated_at": "2026-03-24T08:01:00Z"
    },
    {
      "id": "task-missing-context",
      "title": "Keep queue approval state deterministic",
      "impact": 7,
      "effort": 3,
      "confidence": 0.8,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "This failure is newer but did not persist a failed step.",
      "score": 1.0,
      "status": "failed",
      "strategy_depth": 0,
      "created_at": "2026-03-24T08:10:00Z",
      "updated_at": "2026-03-24T08:20:00Z",
      "failed_at": "2026-03-24T08:20:00Z"
    },
    {
      "id": "task-bounded-context",
      "title": "Tighten the queue timeout reconciliation path",
      "impact": 7,
      "effort": 4,
      "confidence": 0.8,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "This older failure kept a concrete bounded step and should win the last slot.",
      "score": 1.0,
      "status": "failed",
      "strategy_depth": 0,
      "created_at": "2026-03-24T08:05:00Z",
      "updated_at": "2026-03-24T08:15:00Z",
      "failed_at": "2026-03-24T08:15:00Z",
      "execution_context": {
        "step_count": 4,
        "failed_step": "Patch only `scripts/lib.sh` so timeout reconciliation ignores recovered queue retries before surfacing unresolved timeout pressure.",
        "updated_at": "2026-03-24T08:15:00Z"
      },
      "failure_context": {
        "failed_step_index": 2,
        "failed_step": "Patch only `scripts/lib.sh` so timeout reconciliation ignores recovered queue retries before surfacing unresolved timeout pressure.",
        "updated_at": "2026-03-24T08:15:00Z"
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-output.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-output.json" <<'PY'
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
        "id": "task-001-patch-only-scripts-lib-sh-so-timeout-rec",
        "action": "created",
        "source_task_id": "task-bounded-context",
    }
]

created = next(task for task in registry["tasks"] if task["id"] == "task-001-patch-only-scripts-lib-sh-so-timeout-rec")
assert created["strategy_template"] == "bounded_failed_step_child"
assert created["source_task_id"] == "task-bounded-context"
assert "Patch only `scripts/lib.sh`" in created["experiment"]
assert not any(
    task.get("source_task_id") == "task-missing-context"
    and task.get("status") == "pending_approval"
    and task.get("id") != "task-pending-approval"
    for task in registry["tasks"]
)
PY

echo "strategy failed step context priority test passed"
