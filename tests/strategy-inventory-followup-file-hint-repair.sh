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
      "id": "task-020-persist-deterministic-failure-context",
      "title": "Persist deterministic failure context",
      "impact": 7,
      "effort": 4,
      "confidence": 0.82,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Failure context still needs exact file-backed guidance.",
      "score": 2.4,
      "status": "failed",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:10:00Z",
      "failure_context": {
        "failed_step_index": 1,
        "failed_step": "Inspect `agents/orchestrator.sh` and `scripts/lib.sh` read-only to trace the current failure persistence path, then write one compact inventory artifact with the exact status fields and log writes already emitted.",
        "updated_at": "2026-03-24T08:10:00Z"
      }
    },
    {
      "id": "task-021-inventory-current-state-for-persist-d",
      "title": "Inventory current state for Persist deterministic failure context",
      "impact": 6,
      "effort": 2,
      "confidence": 0.82,
      "category": "learning",
      "project": "codex-agent-system",
      "reason": "This inventory follow-up already exists and should be hydrated in place.",
      "hypothesis": "placeholder",
      "experiment": "Inspect only the files and surfaces named in the failed step, then write one compact inventory artifact at codex-memory/strategy-inventory-persist-deterministic-failure-context.md that records the exact current hooks, fields, selectors, or write paths that matter for the next follow-up. Do not implement code changes in the same run.",
      "success_criteria": [
        "placeholder"
      ],
      "rollback": "placeholder",
      "source_task_id": "task-020-persist-deterministic-failure-context",
      "root_source_task_id": "task-020-persist-deterministic-failure-context",
      "original_failed_root_id": "task-020-persist-deterministic-failure-context",
      "strategy_template": "bounded_learning_inventory",
      "status": "pending_approval",
      "created_at": "2026-03-24T08:10:30Z",
      "updated_at": "2026-03-24T08:11:00Z",
      "task_intent": {
        "source": "strategy_followup",
        "objective": "Inventory current state for Persist deterministic failure context",
        "project": "codex-agent-system",
        "category": "learning",
        "context_hint": "Persist deterministic failure context",
        "constraints": [],
        "success_signals": [],
        "affected_files": []
      },
      "history": []
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-output.json" >/dev/null
)

python3 - "$TEST_ROOT" <<'PY'
import json
import os
import sys

root = sys.argv[1]
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

task = next(item for item in registry["tasks"] if item.get("id") == "task-021-inventory-current-state-for-persist-d")
assert task["task_intent"]["affected_files"] == ["agents/orchestrator.sh", "scripts/lib.sh"]
assert task["history"][-1]["action"] == "auto_repair"
assert "parent failed-step file hints" in task["history"][-1]["note"]
PY

echo "strategy inventory followup file hint repair test passed"
