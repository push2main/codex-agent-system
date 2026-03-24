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
  local port=4770
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
  "$TEST_ROOT/projects/superheld" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/superheld-memory"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-shared-dependency",
      "title": "Shared dependency fixture",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "pending_approval",
      "score": 9,
      "created_at": "2026-03-24T15:00:00Z",
      "updated_at": "2026-03-24T15:00:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/superheld-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-shared-dependency",
      "title": "Shared dependency fixture",
      "project": "superheld",
      "category": "stability",
      "status": "completed",
      "score": 1,
      "created_at": "2026-03-24T15:01:00Z",
      "updated_at": "2026-03-24T15:03:00Z",
      "completed_at": "2026-03-24T15:03:00Z"
    },
    {
      "id": "task-superheld-dependent",
      "title": "Use the shared dependency inside superheld only",
      "project": "superheld",
      "category": "stability",
      "status": "pending_approval",
      "score": 0,
      "created_at": "2026-03-24T15:04:00Z",
      "updated_at": "2026-03-24T15:04:00Z",
      "depends_on": ["task-shared-dependency"]
    }
  ]
}
EOF

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "/tmp/superheld",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$TEST_ROOT/superheld-memory/memory.md",
  "spec_file": "$TEST_ROOT/superheld-memory/spec.md",
  "policy_file": "$TEST_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$TEST_ROOT/superheld-memory/tasks.json"
}
EOF

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "risk_profile": "standard",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=idle
project=
task=
last_result=NONE
note=Dependency identity fixture
updated_at=2026-03-24T15:00:00Z
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{"approval_mode":"manual","updated_at":"2026-03-24T15:00:00Z"}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

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
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard dependency identity endpoint did not become ready")

dependent = next(
    task for task in payload["tasks"] if task["id"] == "task-superheld-dependent" and task["project"] == "superheld"
)

dependency_state = dependent["dependency_state"]
assert dependency_state["blocked"] is False, dependency_state
assert dependency_state["unmet"] == [], dependency_state
assert dependency_state["satisfied"] == [
    {
        "id": "task-shared-dependency",
        "status": "completed",
        "title": "Shared dependency fixture",
        "project": "superheld",
    }
], dependency_state
PY

echo "task registry dependency project identity test passed"
