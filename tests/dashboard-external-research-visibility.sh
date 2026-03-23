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
      "id": "task-external-review",
      "title": "Review external signal: OpenAI Python releases - v2.29.0",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-23T11:55:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-23T11:55:00Z"
}
EOF

cat >"$TEST_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-23T11:52:18Z",
  "signals": [
    {
      "source_id": "openai-python-releases",
      "source_label": "OpenAI Python releases",
      "title": "v2.29.0",
      "url": "https://github.com/openai/openai-python/releases/tag/v2.29.0",
      "published_at": "2026-03-17T17:53:05Z",
      "fresh": true
    }
  ],
  "errors": []
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_EXTERNAL_SIGNALS_FILE="$TEST_ROOT/codex-learning/external-signals.json" \
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
        with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
            metrics = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("metrics endpoint did not become ready")

external = metrics["externalResearch"]
assert external["status"] == "fresh"
assert external["fresh_signals"] == 1
assert external["total_signals"] == 1
assert external["errors"] == 0
assert external["updated_at"] == "2026-03-23T11:52:18Z"
assert external["latest_signal"]["source_label"] == "OpenAI Python releases"
assert external["latest_signal"]["title"] == "v2.29.0"
PY

echo "dashboard external research visibility test passed"
