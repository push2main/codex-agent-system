#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/queues" "$TEST_ROOT/projects"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-100-root-ui-epic",
      "title": "Tighten the mobile dashboard into an enterprise control surface",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 8,
      "effort": 4,
      "confidence": 0.8,
      "status": "failed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z",
      "execution_context": {
        "step_count": 5,
        "failed_step": "Create a tighter mobile-first card shell for the existing task board layout."
      },
      "failure_context": {
        "failed_step": "Create a tighter mobile-first card shell for the existing task board layout."
      }
    },
    {
      "id": "task-101-first-ui-child",
      "title": "Create a tighter mobile-first card shell for the existing task board layout",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 7,
      "effort": 3,
      "confidence": 0.82,
      "status": "failed",
      "created_at": "2026-03-23T08:06:00Z",
      "updated_at": "2026-03-23T08:10:00Z",
      "source_task_id": "task-100-root-ui-epic",
      "root_source_task_id": "task-100-root-ui-epic",
      "original_failed_root_id": "task-100-root-ui-epic",
      "strategy_template": "bounded_failed_step_child",
      "strategy_depth": 1,
      "execution_context": {
        "step_count": 4,
        "failed_step": "Tighten the spacing and metadata hierarchy inside the existing task cards."
      },
      "failure_context": {
        "failed_step": "Tighten the spacing and metadata hierarchy inside the existing task cards."
      }
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-ui-rescue.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-ui-rescue.json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
output = Path(sys.argv[2])
payload = json.loads(output.read_text())
actions = payload["data"]["board_tasks"]
assert any(action["action"] == "created" for action in actions)

registry = json.loads((root / "codex-memory" / "tasks.json").read_text())
tasks = registry["tasks"]

created = next(task for task in tasks if task.get("strategy_depth") == 2)
assert created["status"] == "pending_approval"
assert created["category"] == "ui"
assert created["root_source_task_id"] == "task-100-root-ui-epic"
assert created["original_failed_root_id"] == "task-100-root-ui-epic"
assert created["source_task_id"] == "task-100-root-ui-epic"
assert created["title"] == "Tighten the spacing and metadata hierarchy inside the existing task cards"
PY

echo "strategy ui requirement rescue test passed"
