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
  local port=4958
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

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-registry-pressure-live",
            "title": "Expose live task-registry pressure metrics",
            "project": "codex-agent-system",
            "category": "performance",
            "status": "pending_approval",
            "created_at": "2026-03-24T08:00:00Z",
            "updated_at": "2026-03-24T08:05:00Z",
            "reason": "x" * 530000,
        }
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 0,
  "success_rate": 0,
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 0,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "task_registry_payload_bytes": 0,
  "task_registry_pressure_detected": false,
  "task_registry_pressure_primary_surface": "",
  "last_task_score": 0,
  "manual_recovery_records": 0
}
EOF

cat >"$TEST_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "",
  "signals": [],
  "errors": []
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-24T08:05:00Z"
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
state=idle
project=
task=
last_result=NONE
note=
updated_at=2026-03-24T08:05:00Z
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_EXTERNAL_SIGNALS_FILE="$TEST_ROOT/codex-learning/external-signals.json" \
DASHBOARD_STRATEGY_LATEST_FILE="$TEST_ROOT/codex-logs/strategy-latest.json" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
DASHBOARD_PROJECTS_DIR="$TEST_ROOT/projects" \
DASHBOARD_QUEUES_DIR="$TEST_ROOT/queues" \
node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import os
import sys
import time
import urllib.request

port = sys.argv[1]
tasks_path = sys.argv[2]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
            payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

expected_payload_bytes = os.path.getsize(tasks_path)

assert payload["taskRegistryTotal"] == 1, payload["taskRegistryTotal"]
assert payload["taskRegistryPayloadBytes"] == expected_payload_bytes, (
    payload["taskRegistryPayloadBytes"],
    expected_payload_bytes,
)
assert payload["taskRegistryPressureDetected"] is True, payload["taskRegistryPressureDetected"]
assert payload["taskRegistryPressurePrimarySurface"] == "dashboard_read_path", payload["taskRegistryPressurePrimarySurface"]
assert payload["task_registry_payload_bytes"] == expected_payload_bytes, (
    payload["task_registry_payload_bytes"],
    expected_payload_bytes,
)
assert payload["task_registry_pressure_detected"] is True, payload["task_registry_pressure_detected"]
assert payload["task_registry_pressure_primary_surface"] == "dashboard_read_path", payload["task_registry_pressure_primary_surface"]
assert payload["taskRegistryPressure"] == {
    "detected": True,
    "payload_bytes": expected_payload_bytes,
    "primary_surface": "dashboard_read_path",
}, payload["taskRegistryPressure"]
PY

echo "dashboard api task registry pressure metrics alignment test passed"
