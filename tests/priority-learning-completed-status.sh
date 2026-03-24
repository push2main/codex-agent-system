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
  local port=4700
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
      "id": "task-stability-completed",
      "title": "Keep queue approvals deterministic",
      "category": "stability",
      "project": "codex-agent-system",
      "status": "completed",
      "confidence": 0.8,
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:10:00Z",
      "completed_at": "2026-03-24T08:10:00Z"
    },
    {
      "id": "task-stability-failed",
      "title": "Tighten queue worker recovery",
      "category": "stability",
      "project": "codex-agent-system",
      "status": "failed",
      "confidence": 0.6,
      "created_at": "2026-03-24T08:20:00Z",
      "updated_at": "2026-03-24T08:30:00Z",
      "failed_at": "2026-03-24T08:30:00Z"
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
        with urllib.request.urlopen(f"{base_url}/api/status", timeout=1):
            break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

request = urllib.request.Request(
    f"{base_url}/api/task-registry",
    data=json.dumps(
        {
            "project": "codex-agent-system",
            "task": "Trigger priority learning refresh"
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    assert response.status == 201

with open(os.path.join(root, "codex-memory", "priority.json"), "r", encoding="utf-8") as handle:
    payload = json.load(handle)

stability = payload["categories"]["stability"]
assert stability["observed_success_rate"] == 0.5
assert stability["predicted_confidence"] == 0.7
assert stability["confidence_drift"] == -0.2
assert stability["learned_adjustment"] == 0.12
assert stability["updated_at"] == "2026-03-24T08:30:00Z"
assert "observed_success_rate" not in payload["categories"]["code_quality"]
PY

echo "priority learning completed-status test passed"
