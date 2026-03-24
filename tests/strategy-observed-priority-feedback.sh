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
    "stability": { "weight": 1.8, "success_rate": 0.76, "observed_success_rate": 0.1 },
    "ui": { "weight": 1.35, "success_rate": 0.81, "observed_success_rate": 0.1 },
    "performance": { "weight": 1.1, "success_rate": 0.7, "observed_success_rate": 0.1 },
    "code_quality": { "weight": 1.05, "success_rate": 0.2, "observed_success_rate": 0.95 }
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-observed-priority.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-observed-priority.json" <<'PY'
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
assert output["data"]["board_tasks"][0] == {
    "id": "task-001-feed-execution-learning-back-into-future",
    "action": "created",
    "source_task_id": "enterprise-readiness",
}

created = {task["id"]: task for task in registry["tasks"] if task["id"].startswith("task-00")}
assert created["task-001-feed-execution-learning-back-into-future"]["strategy_template"] == "enterprise_learning_feedback"
PY

echo "strategy observed priority feedback test passed"
