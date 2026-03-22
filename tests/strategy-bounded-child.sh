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
    "stability": {
      "weight": 1.8,
      "success_rate": 0.76
    },
    "ui": {
      "weight": 1.35,
      "success_rate": 0.81
    },
    "performance": {
      "weight": 1.1,
      "success_rate": 0.7
    },
    "code_quality": {
      "weight": 1.05,
      "success_rate": 0.79
    }
  }
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-050-broad-ui-redesign",
      "title": "Redesign the dashboard into an enterprise-grade responsive console for iPhone, iPad, and desktop",
      "impact": 8,
      "effort": 5,
      "confidence": 0.82,
      "category": "ui",
      "project": "codex-agent-system",
      "reason": "The current dashboard still looks too cheap and unfocused.",
      "score": 1.77,
      "status": "failed",
      "created_at": "2026-03-22T18:00:00Z",
      "updated_at": "2026-03-22T18:10:00Z",
      "failed_at": "2026-03-22T18:10:00Z",
      "execution_context": {
        "step_count": 5,
        "failed_step": "Create a tighter mobile-first card shell for the existing task board layout.",
        "updated_at": "2026-03-22T18:10:00Z"
      },
      "failure_context": {
        "failed_step_index": 1,
        "failed_step": "Create a tighter mobile-first card shell for the existing task board layout.",
        "updated_at": "2026-03-22T18:10:00Z"
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-child.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-child.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)

assert output["status"] == "success"
assert len(output["data"]["board_tasks"]) == 1
assert output["data"]["board_tasks"][0]["action"] == "created"

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

tasks = registry["tasks"]
assert len(tasks) == 2
child = next(task for task in tasks if task["id"] != "task-050-broad-ui-redesign")
assert child["strategy_template"] == "bounded_failed_step_child"
assert child["status"] == "pending_approval"
assert child["category"] == "ui"
assert child["source_task_id"] == "task-050-broad-ui-redesign"
assert child["title"] == "Create a tighter mobile-first card shell for the existing task board layout"
assert "first failed plan step" in child["reason"]
assert child["effort"] == 3
assert child["impact"] == 7
PY

echo "strategy bounded child test passed"
