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
  local port=4980
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
  "$TEST_ROOT/projects/pressure-smoke" \
  "$TEST_ROOT/queues"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-pressure-summary",
            "title": "Surface task registry pressure in summaries",
            "project": "pressure-smoke",
            "category": "performance",
            "status": "pending_approval",
            "score": 3.4,
            "created_at": "2026-03-24T14:00:00Z",
            "updated_at": "2026-03-24T14:00:00Z",
            "reason": "x" * 530000,
        }
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-24T14:00:00Z"
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 1,
  "success_rate": 0,
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 1,
  "pending_approval_tasks": 1,
  "approved_tasks": 0,
  "task_registry_total": 1,
  "last_task_score": 3.4,
  "manual_recovery_records": 0
}
EOF

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

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=queued
project=pressure-smoke
task=Surface task registry pressure in summaries
last_result=NONE
note=queued_at=2026-03-24T14:00:00Z
updated_at=2026-03-24T14:00:00Z
EOF

printf "Surface task registry pressure in summaries\n" >"$TEST_ROOT/queues/pressure-smoke.txt"
: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_TASKS_FILE="$TEST_ROOT/codex-memory/tasks.json"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$DASHBOARD_TASKS_FILE" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_STRATEGY_LATEST_FILE="$TEST_ROOT/codex-logs/strategy-latest.json" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
DASHBOARD_PROJECTS_DIR="$TEST_ROOT/projects" \
DASHBOARD_QUEUES_DIR="$TEST_ROOT/queues" \
node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$DASHBOARD_TASKS_FILE" <<'PY'
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
            status_payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
    registry_payload = json.load(response)

payload_bytes = tasks_path.stat().st_size

status_pressure = status_payload["taskRegistryPressure"]
assert status_pressure["detected"] is True
assert status_pressure["payload_bytes"] == payload_bytes
assert status_pressure["primary_surface"] == "dashboard_read_path"
assert status_pressure["primary_source"]["project"] == "codex-agent-system"
assert status_pressure["primary_source"]["payload_bytes"] == payload_bytes
assert status_pressure["sources"] == [status_pressure["primary_source"]]
assert status_payload["task_registry_payload_bytes"] == payload_bytes
assert status_payload["task_registry_pressure_detected"] is True
assert status_payload["task_registry_pressure_primary_surface"] == "dashboard_read_path"
assert status_payload["task_registry_pressure_primary_source"] == status_pressure["primary_source"]
assert status_payload["task_registry_pressure_sources"] == status_pressure["sources"]

registry_pressure = registry_payload["summary"]["taskRegistryPressure"]
assert registry_pressure["detected"] is True
assert registry_pressure["payload_bytes"] == payload_bytes
assert registry_pressure["primary_surface"] == "dashboard_read_path"
assert registry_pressure["primary_source"]["project"] == "codex-agent-system"
assert registry_pressure["primary_source"]["payload_bytes"] == payload_bytes
assert registry_pressure["sources"] == [registry_pressure["primary_source"]]
PY

echo "task registry pressure summary test passed"
