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
      "id": "task-timeout-resolved",
      "title": "Cut queue timeout churn before retries burn worker capacity",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 9,
      "effort": 2,
      "confidence": 0.84,
      "score": 7.56,
      "status": "completed",
      "created_at": "2026-03-24T02:00:00Z",
      "updated_at": "2026-03-24T02:06:00Z",
      "completed_at": "2026-03-24T02:06:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-24T02:06:00Z",
        "will_retry": false
      },
      "execution_context": {
        "run_id": "run-timeout-resolved-001",
        "result": "SUCCESS",
        "attempts": 1,
        "total_step_attempts": 1,
        "score": 8,
        "duration_seconds": 240,
        "step_count": 2,
        "completed_steps": 2,
        "failed_step_index": 0,
        "failed_step": "",
        "updated_at": "2026-03-24T02:06:00Z"
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-24T02:05:00Z","project":"codex-agent-system","task":"Cut queue timeout churn before retries burn worker capacity","provider":"codex","result":"FAILURE","attempts":1,"score":0,"branch":"","pr_url":"","run_id":"queue-timeout-lane-1-20260324T020500Z","duration_seconds":300,"total_step_attempts":0,"failure_kind":"timeout","task_id":"task-timeout-resolved"}
EOF

OUTPUT_FILE="$TMP_DIR/strategy-output.json"

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$OUTPUT_FILE" >/dev/null
)

python3 - "$TEST_ROOT/codex-learning/metrics.json" "$OUTPUT_FILE" <<'PY'
import json
import sys

metrics_path = sys.argv[1]
output_path = sys.argv[2]

with open(metrics_path, "r", encoding="utf-8") as handle:
    metrics = json.load(handle)
with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)

assert metrics["timeout_failure_records"] == 0
assert metrics["timeout_failure_rate"] == 0
assert output["status"] == "success"

board_task_ids = [item["id"] for item in output["data"]["board_tasks"]]
assert board_task_ids, "strategy should still keep the board populated"

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)

registry_path = metrics_path.replace("/codex-learning/metrics.json", "/codex-memory/tasks.json")
with open(registry_path, "r", encoding="utf-8") as handle:
    registry = json.load(handle)

created = [task for task in registry["tasks"] if task["id"] in board_task_ids]
assert created, "expected strategy to create follow-up board work"
assert all(task.get("strategy_template") != "enterprise_timeout_stability" for task in created)
PY

echo "strategy timeout task-id reconciliation test passed"
