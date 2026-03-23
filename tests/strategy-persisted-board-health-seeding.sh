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
    "learning": { "weight": 1.2, "success_rate": 0.75 }
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-pending-review",
      "title": "Review bounded corrective task",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 3,
      "effort": 1,
      "confidence": 0.82,
      "score": 2.46,
      "status": "pending_approval",
      "created_at": "2026-03-23T10:00:00Z",
      "updated_at": "2026-03-23T10:00:00Z"
    },
    {
      "id": "task-approved-retrying",
      "title": "Retry shaping logic with explicit verification",
      "project": "codex-agent-system",
      "category": "learning",
      "impact": 5,
      "effort": 2,
      "confidence": 0.8,
      "score": 3.0,
      "status": "approved",
      "created_at": "2026-03-23T10:01:00Z",
      "updated_at": "2026-03-23T10:01:00Z",
      "execution": {
        "attempt": 2,
        "max_retries": 2,
        "result": "FAILURE"
      }
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-persisted-health.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-persisted-health.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)
with open(os.path.join(root, "codex-learning", "metrics.json"), "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert output["status"] == "success"
assert len(output["data"]["board_tasks"]) == 1
assert output["data"]["board_tasks"][0]["source_task_id"] == "strategy::retry-churn"

titles = {task["title"] for task in registry["tasks"]}
assert "Detect retry churn and queue starvation before strategy declares the board healthy" in titles
assert metrics["retry_churn_detected"] is True
assert metrics["queue_starvation_detected"] is True
PY

echo "strategy persisted board health seeding test passed"
