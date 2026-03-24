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
      "id": "task-root-generic-followup",
      "title": "Clarify unstable planner branching",
      "project": "codex-agent-system",
      "category": "code_quality",
      "impact": 7,
      "effort": 4,
      "confidence": 0.79,
      "status": "failed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z",
      "failed_at": "2026-03-23T08:05:00Z"
    },
    {
      "id": "task-first-generic-followup",
      "title": "Persist structured failure context for strategy follow-ups",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 6,
      "effort": 3,
      "confidence": 0.76,
      "status": "failed",
      "created_at": "2026-03-23T08:10:00Z",
      "updated_at": "2026-03-23T08:15:00Z",
      "failed_at": "2026-03-23T08:15:00Z",
      "source_task_id": "task-root-generic-followup",
      "root_source_task_id": "task-root-generic-followup",
      "original_failed_root_id": "task-root-generic-followup",
      "strategy_template": "structured_failure_context",
      "strategy_depth": 1
    },
    {
      "id": "task-second-generic-followup",
      "title": "Persist structured failure context for strategy follow-ups",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 6,
      "effort": 3,
      "confidence": 0.76,
      "status": "failed",
      "created_at": "2026-03-23T08:20:00Z",
      "updated_at": "2026-03-23T08:25:00Z",
      "failed_at": "2026-03-23T08:25:00Z",
      "source_task_id": "task-root-generic-followup",
      "root_source_task_id": "task-root-generic-followup",
      "original_failed_root_id": "task-root-generic-followup",
      "strategy_template": "structured_failure_context",
      "strategy_depth": 2
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-followup-saturation.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-followup-saturation.json" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
output = json.loads(Path(sys.argv[2]).read_text())
registry = json.loads((root / "codex-memory" / "tasks.json").read_text())
tasks = registry["tasks"]

assert output["status"] == "success"
assert all(action["source_task_id"] != "task-root-generic-followup" for action in output["data"]["board_updates"])
assert sum(1 for task in tasks if task["title"] == "Persist structured failure context for strategy follow-ups") == 2
assert any(str(task.get("source_task_id") or "").startswith("enterprise-readiness") for task in tasks)
PY

echo "strategy followup saturation test passed"
