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
  local port=4500
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
mkdir -p "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-memory" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-auth-approved",
      "title": "Surface Codex auth health before queue execution",
      "impact": 8,
      "effort": 3,
      "confidence": 0.87,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Operators should see cached Codex auth failures before approving more work.",
      "score": 4.06,
      "status": "approved",
      "created_at": "2026-03-22T15:49:35Z",
      "updated_at": "2026-03-22T15:54:53Z",
      "approved_at": "2026-03-22T15:54:53Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=blocked
project=
task=
last_result=DEGRADED
note=waiting_for_codex_auth reason: 401 Unauthorized: Missing bearer or basic authentication in header
updated_at=2026-03-22T15:55:00Z
EOF

cat >"$TEST_ROOT/codex-logs/codex-auth-failure.json" <<'EOF'
{
  "detected_at": "2026-03-22T15:51:12Z",
  "reason": "401 Unauthorized: Missing bearer or basic authentication in header"
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
import urllib.request

port = sys.argv[1]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/status", timeout=1) as response:
            status = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard auth status endpoint did not become ready")

auth = status["authHealth"]
assert auth["active"] is True
assert auth["blocks_queue"] is True
assert auth["status"] == "blocked"
assert auth["remaining_seconds"] > 0
assert "401 Unauthorized" in auth["reason"]
assert status["protocol"] == "http"

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
    registry = json.load(response)

assert registry["authHealth"]["active"] is True
assert registry["summary"]["nextAction"]["state"] == "blocked"
assert "Resolve Codex auth before executing" in registry["summary"]["nextAction"]["message"]

with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
    metrics = json.load(response)

assert metrics["authHealth"]["active"] is True
assert metrics["nextAction"]["state"] == "blocked"

with urllib.request.urlopen(f"{base_url}/", timeout=1) as response:
    html = response.read().decode("utf-8")

assert "Codex Auth" in html
assert "auth-health" in html
PY
