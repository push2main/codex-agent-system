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
      "id": "task-pending-older",
      "title": "Review the oldest pending approval",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 4,
      "effort": 1,
      "confidence": 0.82,
      "score": 5.9,
      "status": "pending_approval",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z"
    },
    {
      "id": "task-pending-newer",
      "title": "Review the newer pending approval",
      "project": "codex-agent-system",
      "category": "performance",
      "impact": 5,
      "effort": 1,
      "confidence": 0.91,
      "score": 7.4,
      "status": "pending_approval",
      "created_at": "2026-03-24T09:00:00Z",
      "updated_at": "2026-03-24T09:00:00Z"
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pending_approval_tasks": 2,
  "approved_tasks": 0,
  "task_registry_total": 2,
  "pending_approval_blocked_detected": true,
  "queue_starvation_detected": false,
  "retry_churn_detected": false,
  "low_completion_drain_detected": false
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-pending-recommendation.json" >/dev/null
)

python3 - "$TMP_DIR/strategy-pending-recommendation.json" <<'PY'
import json
import sys

output_path = sys.argv[1]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)

assert output["status"] == "success"
assert output["message"] == (
    "No new strategy updates for codex-agent-system; waiting on 2 pending approval task(s)."
    " Review oldest first: Review the oldest pending approval."
)
assert output["data"]["board_updates"] == []
assert output["data"]["board_tasks"][0]["id"] == "task-pending-older"
assert output["data"]["board_tasks"][1]["id"] == "task-pending-newer"
PY

echo "strategy pending approval recommendation test passed"
