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
  local port=4780
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

python3 - "$DASHBOARD_PORT" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

port = sys.argv[1]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/status", timeout=1):
            break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

create_request = urllib.request.Request(
    f"{base_url}/api/task-registry",
    data=json.dumps(
        {
            "project": "codex-agent-system",
            "title": "Edit only those existing CSS rules in `codex-dashboard/index.html` to tighten the title strip, then verify deterministically with dashboard screenshots",
            "category": "ui",
            "impact": 7,
            "effort": 3,
            "confidence": 0.82,
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(create_request, timeout=2) as response:
    created = json.load(response)

assert created["ok"] is True
task = created["task"]
assert task["status"] == "pending_approval"
assert task["task_shape"]["approval_ready"] is False
assert task["task_shape"]["verification_command"] == "bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh"

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
    registry = json.load(response)

repaired = next(entry for entry in registry["tasks"] if entry["id"] == task["id"])
assert repaired["status"] == "pending_approval"
assert repaired["task_shape"]["approval_ready"] is True
assert repaired["title"] == "Edit only those existing CSS rules in codex-dashboard/index.html to tighten the title strip"

approve_request = urllib.request.Request(
    f"{base_url}/api/task-registry/action",
    data=json.dumps({"id": task["id"], "action": "approve"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(approve_request, timeout=2) as response:
    approved = json.load(response)

assert approved["ok"] is True
assert approved["task"]["status"] == "approved"
assert approved["task"]["queue_handoff"]["task"] == "Edit only those existing CSS rules in codex-dashboard/index.html to tighten the title strip"
PY

echo "task shaper approval guard test passed"
