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

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-24T18:20:00Z","project":"codex-agent-system","task":"Reduce unresolved timeout pressure","result":"FAILURE","attempts":2,"score":0,"run_id":"run-timeout-pressure","duration_seconds":420,"provider":"codex","failure_kind":"timeout","task_id":"task-timeout-pressure","failed_step_index":2,"failed_step":"Patch only `scripts/lib.sh` so timeout reconciliation ignores recovered queue retries before surfacing unresolved timeout pressure."}
EOF

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
      "id": "task-timeout-pressure",
      "title": "Reduce unresolved timeout pressure",
      "impact": 8,
      "effort": 3,
      "confidence": 0.83,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Generic retry-wrapper failure text should be replaced with richer task-log evidence before strategy generates a bounded follow-up.",
      "score": 2.99,
      "status": "failed",
      "created_at": "2026-03-24T18:00:00Z",
      "updated_at": "2026-03-24T18:10:00Z",
      "failed_at": "2026-03-24T18:10:00Z",
      "last_failure_kind": "timeout",
      "failure_context": {
        "failure_kind": "timeout",
        "failed_step": "Task blocked by non-retryable failure guard.",
        "timestamp": "2026-03-24T18:10:00Z"
      },
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Reduce unresolved timeout pressure",
        "project": "codex-agent-system",
        "category": "stability",
        "context_hint": "Keep timeout reconciliation aligned with persisted success evidence.",
        "constraints": [
          "Limit the change to timeout reconciliation surfaces.",
          "Do not broaden queue semantics."
        ],
        "affected_files": [
          "scripts/lib.sh"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/queue-worker-timeout-failure-reconciliation.sh"
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

failed = next(task for task in registry["tasks"] if task["id"] == "task-timeout-pressure")
expected = "Patch only `scripts/lib.sh` so timeout reconciliation ignores recovered queue retries before surfacing unresolved timeout pressure."

assert failed["execution_context"]["failed_step"] == expected
assert failed["execution_context"]["failed_step_source"] == "task_log_backfill"
assert failed["execution_context"]["result"] == "FAILURE"
assert failed["failure_context"]["failed_step"] == expected
assert failed["failure_context"]["failed_step_source"] == "task_log_backfill"
assert failed["failure_context"]["task_id"] == "task-timeout-pressure"
assert failed["failure_context"]["failed_step"] != "Task blocked by non-retryable failure guard."

created = next(
    task
    for task in registry["tasks"]
    if task["id"] == "task-timeout-pressure"
)

assert output["status"] == "success"
PY

echo "strategy failed step placeholder upgrade test passed"
