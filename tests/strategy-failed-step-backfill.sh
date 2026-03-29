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
      "id": "task-existing-pending",
      "title": "Existing approval-ready task",
      "impact": 6,
      "effort": 2,
      "confidence": 0.8,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Keep one pending task so strategy only has one free approval slot.",
      "hypothesis": "Only the repaired failed task should create a new follow-up.",
      "experiment": "Do not change this fixture task.",
      "success_criteria": [
        "Fixture remains pending."
      ],
      "rollback": "Remove the fixture task.",
      "score": 1.0,
      "status": "pending_approval",
      "created_at": "2026-03-24T17:55:00Z",
      "updated_at": "2026-03-24T17:55:00Z"
    },
    {
      "id": "task-existing-approved",
      "title": "Existing approved task",
      "impact": 6,
      "effort": 2,
      "confidence": 0.8,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Keep enterprise seeding disabled once one repaired follow-up is created.",
      "hypothesis": "The actionable backlog should stay bounded.",
      "experiment": "Do not change this fixture task.",
      "success_criteria": [
        "Fixture remains approved."
      ],
      "rollback": "Remove the fixture task.",
      "score": 1.0,
      "status": "approved",
      "created_at": "2026-03-24T17:56:00Z",
      "updated_at": "2026-03-24T17:56:00Z"
    },
    {
      "id": "task-live-work-ownership",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "impact": 8,
      "effort": 4,
      "confidence": 0.83,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "The latest failure snapshot still includes older failed tasks with no persisted failed_step, which prevents bounded follow-up generation from reusing the original task intent.",
      "score": 2.99,
      "status": "failed",
      "created_at": "2026-03-24T18:00:00Z",
      "updated_at": "2026-03-24T18:10:00Z",
      "failed_at": "2026-03-24T18:10:00Z",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Make active worker ownership and progress explicit in the dashboard",
        "project": "codex-agent-system",
        "category": "stability",
        "context_hint": "Surface one additional deterministic live-work ownership signal without changing queue semantics.",
        "constraints": [
          "Keep the change scoped to the dashboard read path.",
          "Do not change queue execution behavior."
        ],
        "affected_files": [
          "codex-dashboard/server.js",
          "codex-dashboard/index.html"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
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

failed = next(task for task in registry["tasks"] if task["id"] == "task-live-work-ownership")
expected = (
    "In `codex-dashboard/server.js`, `codex-dashboard/index.html`, implement the smallest safe change for: "
    "Make active worker ownership and progress explicit in the dashboard. Focus on Surface one additional deterministic "
    "live-work ownership signal without changing queue semantics. Keep these constraints: Keep the change scoped to "
    "the dashboard read path; Do not change queue execution behavior."
)

assert failed["execution_context"]["failed_step"] == expected
assert failed["execution_context"]["result"] == "FAILURE"
assert failed["failure_context"]["failed_step"] == expected
assert failed["failure_context"]["task_id"] == "task-live-work-ownership"

created = next(
    task
    for task in registry["tasks"]
    if task.get("strategy_template") == "bounded_failed_step_child"
    and task.get("source_task_id") == "task-live-work-ownership"
)
assert created["strategy_template"] == "bounded_failed_step_child"
assert created["source_task_id"] == "task-live-work-ownership"
assert created["title"] == expected[:140]
assert expected in created["experiment"]

assert output["status"] == "success"
assert {
    "id": created["id"],
    "action": "created",
    "source_task_id": "task-live-work-ownership",
} in output["data"]["board_tasks"]
PY

echo "strategy failed step backfill test passed"
