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
  local port=4750
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

: >"$TEST_ROOT/codex-memory/tasks.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$TEST_ROOT" <<'PY'
import json
import os
import sys
import time
import urllib.request

port = sys.argv[1]
root = sys.argv[2]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/status", timeout=1) as response:
            status = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

assert status["settings"]["approval_mode"] == "manual"

request = urllib.request.Request(
    f"{base_url}/api/settings",
    data=json.dumps({"approval_mode": "auto"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    settings_payload = json.load(response)

assert settings_payload["ok"] is True
assert settings_payload["settings"]["approval_mode"] == "auto"

prompt_text = "\n".join(
    [
        "Show runtime version drift in the dashboard status area.",
        "Add a capability guard around prompt intake route usage.",
    ]
)
request = urllib.request.Request(
    f"{base_url}/api/task-registry/intake",
    data=json.dumps({"project": "codex-agent-system", "prompt": prompt_text}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    created = json.load(response)

assert created["ok"] is True
assert created["created_count"] == 2
assert created["auto_approve"]["approved"] == [
    "task-001-show-runtime-version-drift-in-the-dashbo",
    "task-002-add-a-capability-guard-around-prompt-int",
]
assert all(task["status"] == "approved" for task in created["tasks"])
assert all(task["queue_handoff"]["status"] == "queued" for task in created["tasks"])

queue_file = os.path.join(root, "queues", "codex-agent-system.txt")
with open(queue_file, "r", encoding="utf-8") as handle:
    queue_lines = [line.strip() for line in handle if line.strip()]

assert queue_lines == [
    "Show runtime version drift in the dashboard status area",
    "Add a capability guard around prompt intake route usage",
]

request = urllib.request.Request(
    f"{base_url}/api/settings",
    data=json.dumps({"approval_mode": "manual"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    settings_payload = json.load(response)

assert settings_payload["settings"]["approval_mode"] == "manual"

request = urllib.request.Request(
    f"{base_url}/api/task-registry/intake",
    data=json.dumps({"project": "codex-agent-system", "prompt": "Keep governance history visible on task cards."}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    manual_created = json.load(response)

assert manual_created["ok"] is True
assert manual_created["created_count"] == 1
assert "auto_approve" not in manual_created
assert manual_created["tasks"][0]["status"] == "pending_approval"

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
    registry = json.load(response)

assert registry["summary"]["byStatus"]["approved"] == 2
assert registry["summary"]["byStatus"]["pending_approval"] == 1
PY

echo "task auto approve test passed"
