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
    "learning": { "weight": 1.0, "success_rate": 0.75 }
  }
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-139-feed-execution-learning",
      "title": "Feed execution learning back into future provider and task decisions",
      "impact": 9,
      "effort": 3,
      "confidence": 0.81,
      "category": "code_quality",
      "project": "codex-agent-system",
      "reason": "The self-improving loop still needs tighter feedback from past runs into future provider routing and task shaping decisions.",
      "score": 2.55,
      "status": "failed",
      "created_at": "2026-03-27T20:33:06Z",
      "updated_at": "2026-03-27T20:47:41Z",
      "failed_at": "2026-03-27T20:47:41Z",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "source_task_title": "Enterprise readiness backlog",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "related_source_task_ids": ["enterprise-readiness::codex-agent-system"],
      "strategy_template": "enterprise_learning_feedback",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Feed execution learning back into future provider and task decisions",
        "project": "codex-agent-system",
        "category": "code_quality",
        "context_hint": "Enterprise readiness backlog",
        "constraints": [],
        "success_signals": [],
        "affected_files": []
      },
      "execution_context": {
        "step_count": 2,
        "failed_step_index": 1,
        "failed_step": "implement the smallest safe change for: Feed execution learning back into future provider and task decisions. Focus on Enterprise readiness backlog.",
        "updated_at": "2026-03-27T20:47:41Z"
      },
      "failure_context": {
        "failed_step_index": 1,
        "failed_step": "implement the smallest safe change for: Feed execution learning back into future provider and task decisions. Focus on Enterprise readiness backlog.",
        "updated_at": "2026-03-27T20:47:41Z"
      }
    },
    {
      "id": "task-141-broad-child",
      "title": "implement the smallest safe change for: Feed execution learning back into future provider and task decisions. Focus on Enterprise readiness ",
      "impact": 8,
      "effort": 2,
      "confidence": 0.81,
      "category": "code_quality",
      "project": "codex-agent-system",
      "reason": "Task task-139-feed-execution-learning failed while still spanning too much scope.",
      "hypothesis": "If the next run executes only the first failed step from the broader task, the system will recover faster than repeating the full multi-step task at the same size.",
      "experiment": "Execute only this bounded child step next: implement the smallest safe change for: Feed execution learning back into future provider and task decisions. Focus on Enterprise readiness backlog. Do not implement later plan steps from the parent task in the same run.",
      "success_criteria": [
        "The child task changes only the code needed for this single failed step."
      ],
      "rollback": "Discard the child-task split and return to the previous whole-task retry behavior.",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "source_task_title": "Feed execution learning back into future provider and task decisions",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "related_source_task_ids": ["enterprise-readiness::codex-agent-system"],
      "strategy_template": "bounded_failed_step_child",
      "strategy_depth": 1,
      "task_intent": {
        "source": "strategy_followup",
        "objective": "implement the smallest safe change for: Feed execution learning back into future provider and task decisions. Focus on Enterprise readiness",
        "project": "codex-agent-system",
        "category": "code_quality",
        "context_hint": "Feed execution learning back into future provider and task decisions",
        "constraints": [],
        "success_signals": [],
        "affected_files": []
      },
      "score": 3.4,
      "status": "pending_approval",
      "created_at": "2026-03-27T20:54:52Z",
      "updated_at": "2026-03-27T20:54:52Z"
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

assert len(registry["tasks"]) == 2

task = next(item for item in registry["tasks"] if item["id"] == "task-141-broad-child")
assert task["status"] == "pending_approval"
assert task["strategy_template"] == "bounded_learning_inventory"
assert task["title"] == "Inventory current decision path for Feed execution learning back into future provider and task decisions"
assert "Do not implement code changes in the same run." in task["experiment"]
assert "codex-memory/strategy-inventory-feed-execution-learning-back-into-future.md" in task["experiment"]
assert task["task_intent"]["source"] == "strategy_followup"
assert task["task_intent"]["context_hint"] == "Feed execution learning back into future provider and task decisions"
assert task["task_intent"]["objective"] == "Inventory current decision path for Feed execution learning back into future provider and task decisions"
assert task["category"] == "learning"
PY

echo "strategy generic failed-step inventory refresh test passed"
