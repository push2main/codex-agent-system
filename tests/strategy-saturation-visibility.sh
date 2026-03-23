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
  local port=4800
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-040-detect-low-first-pass-success-before-rep",
      "title": "Detect low first-pass success before repeated retries dominate the board",
      "impact": 9,
      "effort": 2,
      "confidence": 0.87,
      "category": "learning",
      "project": "codex-agent-system",
      "reason": "Low first-pass success still needs bounded corrective work.",
      "score": 4.21,
      "status": "failed",
      "strategy_template": "first_pass_success_guard",
      "root_source_task_id": "strategy::first-pass-success",
      "task_intent": {
        "source": "strategy_anomaly",
        "objective": "Detect low first-pass success before repeated retries dominate the board",
        "project": "codex-agent-system",
        "category": "learning"
      },
      "created_at": "2026-03-22T18:00:00Z",
      "updated_at": "2026-03-22T18:04:00Z",
      "failed_at": "2026-03-22T18:04:00Z"
    },
    {
      "id": "task-043-detect-low-first-pass-success-before-rep",
      "title": "Detect low first-pass success before repeated retries dominate the board",
      "impact": 9,
      "effort": 2,
      "confidence": 0.87,
      "category": "learning",
      "project": "codex-agent-system",
      "reason": "Low first-pass success still needs bounded corrective work.",
      "score": 4.22,
      "status": "failed",
      "strategy_template": "first_pass_success_guard",
      "root_source_task_id": "strategy::first-pass-success",
      "task_intent": {
        "source": "strategy_anomaly",
        "objective": "Detect low first-pass success before repeated retries dominate the board",
        "project": "codex-agent-system",
        "category": "learning"
      },
      "created_at": "2026-03-22T18:10:00Z",
      "updated_at": "2026-03-22T18:14:00Z",
      "failed_at": "2026-03-22T18:14:00Z"
    },
    {
      "id": "task-plain-failed-ui",
      "title": "Polish task card spacing",
      "impact": 5,
      "effort": 2,
      "confidence": 0.7,
      "category": "ui",
      "project": "codex-agent-system",
      "reason": "Regular failed task should not be marked as saturated strategy work.",
      "score": 2.5,
      "status": "failed",
      "created_at": "2026-03-22T19:00:00Z",
      "updated_at": "2026-03-22T19:01:00Z",
      "failed_at": "2026-03-22T19:01:00Z"
    }
  ]
}
EOF

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

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-22T15:00:00Z"
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_PRIORITY_FILE="$TEST_ROOT/codex-memory/priority.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" <<'PY'
import json
import sys
import time
import urllib.request

port = sys.argv[1]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("task registry endpoint did not become ready")

with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
    metrics = json.load(response)

summary = payload["summary"]
assert summary["nextAction"]["state"] == "strategy"
assert "Choose a different bounded experiment" in summary["nextAction"]["message"]
assert summary["strategy"]["saturated_failed_tasks"] == 2
assert summary["strategy"]["topSaturatedFailedTask"]["id"] == "task-043-detect-low-first-pass-success-before-rep"
assert metrics["saturatedFailedTasks"] == 2
assert metrics["strategySaturationDetected"] is True

failed_tasks = {
    task["id"]: task
    for task in payload["tasks"]
}

assert failed_tasks["task-040-detect-low-first-pass-success-before-rep"]["strategy_state"]["saturated"] is True
assert failed_tasks["task-040-detect-low-first-pass-success-before-rep"]["strategy_state"]["failed_equivalent_count"] == 2
assert failed_tasks["task-043-detect-low-first-pass-success-before-rep"]["strategy_state"]["saturated"] is True
assert failed_tasks["task-043-detect-low-first-pass-success-before-rep"]["strategy_state"]["failed_equivalent_count"] == 2
assert failed_tasks["task-plain-failed-ui"]["strategy_state"]["saturated"] is False
assert failed_tasks["task-plain-failed-ui"]["strategy_state"]["failed_equivalent_count"] == 0
PY

echo "strategy saturation visibility test passed"
