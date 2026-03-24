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
  local port=4970
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
  "$TEST_ROOT/projects/registry-smoke" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-snapshot-pending",
      "title": "Review dashboard snapshot endpoint",
      "project": "registry-smoke",
      "category": "stability",
      "status": "pending_approval",
      "score": 2.5,
      "created_at": "2026-03-24T00:00:00Z",
      "updated_at": "2026-03-24T00:00:00Z"
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
  "updated_at": "2026-03-24T00:00:00Z"
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
project=registry-smoke
task=Review dashboard snapshot endpoint
last_result=NONE
note=queued_at=2026-03-24T00:00:00Z
updated_at=2026-03-24T00:00:00Z
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
  "last_task_score": 2.5,
  "manual_recovery_records": 0
}
EOF

printf "Review dashboard snapshot endpoint\n" >"$TEST_ROOT/queues/registry-smoke.txt"
: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_PRIORITY_FILE="$TEST_ROOT/codex-memory/priority.json" \
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

python3 - "$DASHBOARD_PORT" <<'PY'
import json
import sys
import time
import urllib.request

port = sys.argv[1]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/dashboard", timeout=1) as response:
            payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard snapshot endpoint did not become ready")

assert "registry-smoke" in payload["projects"]
assert payload["status"]["project"] == "registry-smoke"
assert payload["status"]["task"] == "Review dashboard snapshot endpoint"
assert payload["status"]["strategy"]["status"] in {"running", "stale", "failed", "unknown"}
assert payload["metrics"]["taskRegistryTotal"] == 1
assert payload["metrics"]["pendingApproval"] == 1
assert payload["metrics"]["queued"] == 1
assert payload["metrics"]["externalResearch"]["status"] == "fresh"
assert len(payload["queue"]["tasks"]) == 1
assert payload["queue"]["tasks"][0]["task"] == "Review dashboard snapshot endpoint"
assert len(payload["taskRegistry"]["tasks"]) == 1
assert payload["taskRegistry"]["summary"]["byStatus"]["pending_approval"] == 1
assert payload["taskRegistry"]["tasks"][0]["id"] == "task-snapshot-pending"
PY

echo "dashboard snapshot endpoint test passed"
