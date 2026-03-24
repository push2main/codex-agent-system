#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
DASHBOARD_PID=""

cleanup() {
  if [ -n "$DASHBOARD_PID" ]; then
    kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
    wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

port_in_use() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

find_free_port() {
  local port=4950
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-failed-a",
      "title": "Tighten dashboard retry visibility",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "score": 1.0,
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z",
      "failed_at": "2026-03-23T08:05:00Z",
      "execution_context": {
        "plan_steps": [
          "Inspect the retry visibility summary",
          "Add one bounded regression test"
        ],
        "failed_step_index": 0
      }
    },
    {
      "id": "task-002-failed-b",
      "title": "Keep queue drift visible in the board",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "score": 1.0,
      "created_at": "2026-03-23T08:10:00Z",
      "updated_at": "2026-03-23T08:15:00Z",
      "failed_at": "2026-03-23T08:15:00Z",
      "execution_context": {
        "plan_steps": [
          "Inspect queue drift visibility",
          "Add one bounded regression test"
        ],
        "failed_step_index": 0
      }
    }
  ]
}
EOF

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

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-23T11:00:00Z"
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=idle
project=
task=
last_result=NONE
note=waiting_for_tasks=1
updated_at=2026-03-23T08:00:00Z
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 4,
  "success_rate": 0.25,
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 2,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 2,
  "last_task_score": 1.0,
  "manual_recovery_records": 0,
  "low_first_pass_success_detected": true,
  "retry_churn_detected": true,
  "queue_starvation_detected": false,
  "pending_approval_blocked_detected": false,
  "low_completion_drain_detected": true,
  "first_pass_success_rate": 0.25,
  "first_pass_success_count": 1,
  "multi_attempt_resolved_count": 3
}
EOF

python3 - <<'PY' >"$TEST_ROOT/codex-memory/tasks.log"
import json

records = [
    {"project": "codex-agent-system", "task": "task-a", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-b", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-c", "result": "FAILURE", "attempts": 2, "score": 0},
    {"project": "codex-agent-system", "task": "task-d", "result": "SUCCESS", "attempts": 2, "score": 1}
]

for record in records:
    print(json.dumps(record))
PY

cat >"$TEST_ROOT/codex-logs/strategy-latest.json" <<'EOF'
{
  "status": "success",
  "message": "Strategy health is available.",
  "data": {
    "board_updates": [],
    "board_tasks": []
  }
}
EOF

: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_PRIORITY_FILE="$TEST_ROOT/codex-memory/priority.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_STRATEGY_LATEST_FILE="$TEST_ROOT/codex-logs/strategy-latest.json" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
import time
import urllib.request
from pathlib import Path

port = sys.argv[1]
tasks_path = Path(sys.argv[2])
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/status", timeout=1) as response:
            json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

before = json.loads(tasks_path.read_text(encoding="utf-8"))
before_ids = [task["id"] for task in before["tasks"]]
before_count = len(before_ids)

for route in ("/api/status", "/api/metrics", "/api/task-registry"):
    with urllib.request.urlopen(f"{base_url}{route}", timeout=2) as response:
        json.load(response)

after = json.loads(tasks_path.read_text(encoding="utf-8"))
after_ids = [task["id"] for task in after["tasks"]]

assert before_count == 2
assert after_ids == before_ids
assert len(after_ids) == before_count
assert not any(task.get("status") == "pending_approval" for task in after["tasks"])
PY

echo "dashboard read paths no side effects test passed"
