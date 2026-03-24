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

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-pending-review",
      "title": "Review the latest bounded follow-up before queueing",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 4,
      "effort": 1,
      "confidence": 0.82,
      "score": 5.9,
      "status": "pending_approval",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z"
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pending_approval_tasks": 1,
  "approved_tasks": 0,
  "task_registry_total": 1,
  "pending_approval_blocked_detected": true,
  "queue_starvation_detected": false,
  "retry_churn_detected": false,
  "low_completion_drain_detected": false
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-pending-blocker.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-pending-blocker.json" <<'PY'
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
assert output["message"] == "No new strategy updates for codex-agent-system; waiting on 1 pending approval task(s)."
assert output["data"]["board_updates"] == []
assert output["data"]["board_tasks"] == [
    {
        "id": "task-pending-review",
        "action": "existing",
        "status": "pending_approval",
        "title": "Review the latest bounded follow-up before queueing",
        "category": "stability",
        "source_task_id": "task-pending-review",
        "updated_at": "2026-03-24T08:00:00Z",
    }
]
assert len(registry["tasks"]) == 1
assert metrics["pending_approval_blocked_detected"] is True
assert metrics["task_registry_total"] == 1
PY

echo "strategy pending approval blocker guard test passed"
