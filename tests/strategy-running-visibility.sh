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
  local port=4900
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
      "id": "task-running-strategy",
      "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 2,
      "confidence": 0.85,
      "score": 6.46,
      "status": "running",
      "strategy_template": "queue_drain_completion_guard",
      "task_intent": {
        "source": "strategy_anomaly",
        "objective": "Keep an executable system-work buffer when the queue drains under low completion rate",
        "project": "codex-agent-system",
        "category": "stability"
      },
      "created_at": "2026-03-23T11:11:02Z",
      "updated_at": "2026-03-23T11:12:23Z"
    },
    {
      "id": "task-failed-normal",
      "title": "Polish card spacing",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 5,
      "effort": 2,
      "confidence": 0.7,
      "score": 2.1,
      "status": "failed",
      "created_at": "2026-03-23T11:00:00Z",
      "updated_at": "2026-03-23T11:01:00Z"
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

tasks = {task["id"]: task for task in payload["tasks"]}
assert tasks["task-running-strategy"]["board_scope"] == "approved"
assert tasks["task-failed-normal"]["board_scope"] == "other"
PY

echo "strategy running visibility test passed"
