#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
SESSION_NAME="agentctl-runtime-stale-$$"
RUNTIME_FILE="$TEST_ROOT/codex-logs/agentctl-runtime-$SESSION_NAME.env"

cleanup() {
  if [ -d "$TEST_ROOT" ]; then
    (
      cd "$TEST_ROOT"
      AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh stop >/dev/null 2>&1 || true
    )
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
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
cp -R "$ROOT_DIR/tests" "$TEST_ROOT/tests"
cp -R "$ROOT_DIR/codex-memory" "$TEST_ROOT/codex-memory"
cp -R "$ROOT_DIR/codex-learning" "$TEST_ROOT/codex-learning"
cp -R "$ROOT_DIR/projects" "$TEST_ROOT/projects"
cp -R "$ROOT_DIR/queues" "$TEST_ROOT/queues"
cp "$ROOT_DIR/README.md" "$TEST_ROOT/README.md"
cp "$ROOT_DIR/AGENTS.md" "$TEST_ROOT/AGENTS.md"
cp "$ROOT_DIR/TASK_RESPONSE.md" "$TEST_ROOT/TASK_RESPONSE.md"
cp "$ROOT_DIR/system-rules.md" "$TEST_ROOT/system-rules.md"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-runtime-reload-approval",
      "title": "Restart the runtime before approving more work",
      "category": "stability",
      "impact": 8,
      "effort": 2,
      "confidence": 0.86,
      "project": "codex-agent-system",
      "reason": "Approval handoff should pause when the resident dashboard runtime is stale.",
      "status": "pending_approval",
      "created_at": "2026-03-23T14:00:00Z",
      "updated_at": "2026-03-23T14:00:00Z"
    }
  ]
}
EOF

rm -rf "$TEST_ROOT/queues"
mkdir -p "$TEST_ROOT/queues"

RUNTIME_PORT="$(find_free_port)"

(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" DASHBOARD_PORT="$RUNTIME_PORT" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=1 bash scripts/agentctl.sh start >/dev/null
)

[ -n "$(awk -F= '$1=="queue_helper_fingerprint" { print $2 }' "$RUNTIME_FILE")" ]

CURRENT_STATUS="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh status
)"

printf '%s\n' "$CURRENT_STATUS" | grep -qx "queue_runtime_helpers=current"

printf '\n# stale runtime helper fixture\n' >>"$TEST_ROOT/scripts/lib.sh"

STALE_STATUS="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh status
)"

if printf '%s\n' "$STALE_STATUS" | grep -qx "queue_runtime_helpers=stale"; then
  printf '%s\n' "$STALE_STATUS" | grep -qx "queue_runtime_warning=hot reload pending for updated runtime helpers"
fi

HOT_RELOAD_STATUS=""
for _ in $(seq 1 10); do
  sleep 1
  HOT_RELOAD_STATUS="$(
    cd "$TEST_ROOT"
    AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh status
  )"
  if printf '%s\n' "$HOT_RELOAD_STATUS" | grep -qx "queue_runtime_helpers=current"; then
    break
  fi
done

printf '%s\n' "$HOT_RELOAD_STATUS" | grep -qx "queue_runtime_helpers=current"

printf '\n// stale dashboard runtime fixture\n' >>"$TEST_ROOT/codex-dashboard/server.js"

DASHBOARD_STALE_STATUS="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh status
)"

printf '%s\n' "$DASHBOARD_STALE_STATUS" | grep -q "^  restart_needed=true$"

python3 - "$RUNTIME_PORT" "$SESSION_NAME" "$TEST_ROOT" <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

port = sys.argv[1]
session_name = sys.argv[2]
test_root = sys.argv[3]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/status", timeout=2) as response:
    payload = json.load(response)

runtime = payload["runtime"]["reload_drift"]
assert runtime["detected"] is True
assert runtime["restart_needed"] is True
assert runtime["status"] == "restart_needed"
assert payload["capabilities"]["prompt_intake"] is False
assert "Reload drift detected" in runtime["summary"]
reload_action = payload["runtime"]["reload_action"]
assert reload_action["label"] == "Reload Runtime"
assert reload_action["session_name"] == session_name
assert os.path.realpath(reload_action["cwd"]) == os.path.realpath(test_root)
assert "bash scripts/agentctl.sh reload" in reload_action["command"]
assert f"AGENTCTL_SESSION_NAME='{session_name}'" in reload_action["command"]

with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/task-registry", timeout=2) as response:
    registry = json.load(response)

assert registry["runtime"]["reload_drift"]["restart_needed"] is True
assert registry["runtime"]["reload_action"]["command"] == reload_action["command"]
assert registry["summary"]["nextAction"]["state"] == "blocked"
assert "Restart the dashboard/runtime before approving more work" in registry["summary"]["nextAction"]["message"]

with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=2) as response:
    html = response.read().decode("utf-8")

assert "Copy Reload Command" in html
assert "Runtime Recovery" in html

request = urllib.request.Request(
    f"http://127.0.0.1:{port}/api/task-registry/action",
    data=json.dumps({"id": "task-runtime-reload-approval", "action": "approve"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(request, timeout=2)
    raise SystemExit("expected restart-needed approval to fail")
except urllib.error.HTTPError as error:
    assert error.code == 409
    failure = json.load(error)

assert "Runtime reload is pending" in failure["error"]
PY
