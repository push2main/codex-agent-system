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
  local port=4870
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs/runtime-sessions/demo" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects/demo" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-session-001",
      "title": "Surface runtime session state in the dashboard",
      "project": "demo",
      "status": "running",
      "created_at": "2026-04-01T10:00:00Z",
      "updated_at": "2026-04-01T10:02:00Z",
      "execution": {
        "state": "running",
        "provider": "codex",
        "lane": "lane-2",
        "attempt": 1,
        "max_retries": 2,
        "updated_at": "2026-04-01T10:02:00Z"
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-logs/runtime-sessions/demo/task-session-001.json" <<'EOF'
{
  "project": "demo",
  "task": "Surface runtime session state in the dashboard",
  "task_id": "task-session-001",
  "run_id": "run-demo-001",
  "state": "running",
  "visibility": "background",
  "result": "RUNNING",
  "provider": "codex",
  "lane": "lane-2",
  "step_count": 3,
  "completed_steps": 1,
  "current_step": "Apply the minimal server-side session projection.",
  "latest_activity": {
    "at": "2026-04-01T10:02:00Z",
    "type": "step_start",
    "summary": "Server projection in progress.",
    "detail": "step=2/3"
  },
  "activity_history": [
    {
      "at": "2026-04-01T10:02:00Z",
      "type": "step_start",
      "summary": "Server projection in progress.",
      "detail": "step=2/3"
    },
    {
      "at": "2026-04-01T10:01:20Z",
      "type": "step_success",
      "summary": "Planning step completed.",
      "detail": "step=1/3"
    }
  ],
  "blockers": [
    {
      "at": "2026-04-01T10:01:45Z",
      "code": "runtime_reload_required",
      "reason": "Helper scripts changed after session start."
    }
  ],
  "permission_requests": [
    {
      "at": "2026-04-01T10:01:50Z",
      "tool": "write_file",
      "target": "codex-dashboard/server.js"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{"approval_mode":"manual","updated_at":"2026-04-01T10:00:00Z"}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=running
project=demo
task=Surface runtime session state in the dashboard
last_result=RUNNING
note=runtime session dashboard test
updated_at=2026-04-01T10:02:00Z
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
DASHBOARD_PROJECTS_DIR="$TEST_ROOT/projects" \
DASHBOARD_QUEUES_DIR="$TEST_ROOT/queues" \
DASHBOARD_RUNTIME_SESSIONS_DIR="$TEST_ROOT/codex-logs/runtime-sessions" \
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
        with urllib.request.urlopen(f"{base_url}/api/runtime-sessions", timeout=1) as response:
            sessions_payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard runtime sessions endpoint did not become ready")

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
    registry_payload = json.load(response)

session = sessions_payload["sessions"][0]
task = registry_payload["tasks"][0]

assert session["task_id"] == "task-session-001"
assert session["visibility"] == "background"
assert session["latest_activity"]["summary"] == "Server projection in progress."
assert session["blockers"][0]["code"] == "runtime_reload_required"
assert session["permission_requests"][0]["tool"] == "write_file"

assert task["runtime_session"]["visibility"] == "background"
assert task["runtime_session"]["blockers"][0]["code"] == "runtime_reload_required"
assert task["runtime_session"]["permission_requests"][0]["tool"] == "write_file"

request = urllib.request.Request(
    f"{base_url}/api/runtime-sessions/focus",
    data=json.dumps({"task_id": "task-session-001", "project": "demo"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    focus_payload = json.load(response)

assert focus_payload["ok"] is True
assert focus_payload["session"]["visibility"] == "foreground"
assert focus_payload["session"]["retrieved_at"]

with urllib.request.urlopen(f"{base_url}/api/runtime-sessions", timeout=2) as response:
    updated_sessions = json.load(response)

assert updated_sessions["sessions"][0]["visibility"] == "foreground"
assert updated_sessions["sessions"][0]["retrieved_at"]
PY

grep -q 'data-session-focus' "$TEST_ROOT/codex-dashboard/index.html"

echo "dashboard runtime sessions test passed"
