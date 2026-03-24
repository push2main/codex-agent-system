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
      "id": "task-050-mobile-dashboard-restyle",
      "title": "Tighten the mobile dashboard into an enterprise control surface",
      "impact": 8,
      "effort": 4,
      "confidence": 0.81,
      "category": "ui",
      "project": "codex-agent-system",
      "reason": "The current dashboard still needs a denser enterprise baseline.",
      "score": 1.8,
      "status": "failed",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:10:00Z",
      "failed_at": "2026-03-24T08:10:00Z",
      "execution_context": {
        "step_count": 5,
        "failed_step": "Inspect `codex-dashboard/index.html` and list the exact existing mobile dashboard containers and hooks that must remain intact during the restyle: main sections, `.task-board*` blocks, `.task-board-toolbar`, `.task-filter-row`, `.task-summary*`, `.live-work-strip`, and the current mobile media-query blocks.",
        "updated_at": "2026-03-24T08:10:00Z"
      },
      "failure_context": {
        "failed_step_index": 1,
        "failed_step": "Inspect `codex-dashboard/index.html` and list the exact existing mobile dashboard containers and hooks that must remain intact during the restyle: main sections, `.task-board*` blocks, `.task-board-toolbar`, `.task-filter-row`, `.task-summary*`, `.live-work-strip`, and the current mobile media-query blocks.",
        "updated_at": "2026-03-24T08:10:00Z"
      }
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

task = next(item for item in registry["tasks"] if item.get("strategy_template") == "bounded_learning_inventory")
assert task["status"] == "pending_approval"
assert task["category"] == "learning"
assert task["source_task_id"] == "task-050-mobile-dashboard-restyle"
assert task["title"] == "Inventory current state for Tighten the mobile dashboard into an enterprise control surface"
assert "Do not implement code changes in the same run." in task["experiment"]
assert "codex-memory/strategy-inventory-tighten-the-mobile-dashboard-into-an-ent.md" in task["experiment"]
PY

echo "strategy inspect-only inventory followup test passed"
