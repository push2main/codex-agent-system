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
  local port=4860
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
import urllib.error
import urllib.request

port = sys.argv[1]
root = sys.argv[2]
base_url = f"http://127.0.0.1:{port}"
registry_path = os.path.join(root, "codex-memory", "tasks.json")

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/status", timeout=1):
            break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

def post(path, payload):
    request = urllib.request.Request(
        f"{base_url}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=2) as response:
        return json.load(response)

bootstrap = post(
    "/api/task-registry",
    {
        "project": "dep-smoke",
        "title": "Bootstrap Android foundation",
        "category": "stability",
    },
)

bootstrap_id = bootstrap["task"]["id"]
assert bootstrap_id == "task-001-bootstrap-android-foundation"

dependent = post(
    "/api/task-registry",
    {
        "project": "dep-smoke",
        "title": "Add Gradle wrapper files",
        "category": "stability",
        "dependsOn": [bootstrap_id],
    },
)

dependent_task = dependent["task"]
dependent_id = dependent_task["id"]
assert dependent_id == "task-002-add-gradle-wrapper-files"
assert dependent_task["depends_on"] == [bootstrap_id]

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
    registry = json.load(response)

registry_task = next(task for task in registry["tasks"] if task["id"] == dependent_id)
assert registry_task["dependency_state"]["blocked"] is True
assert registry_task["dependency_state"]["unmet"][0]["id"] == bootstrap_id
assert "Blocked by" in registry_task["dependency_state"]["reason"]

approve_request = urllib.request.Request(
    f"{base_url}/api/task-registry/action",
    data=json.dumps({"id": dependent_id, "action": "approve"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(approve_request, timeout=2)
    raise SystemExit("expected dependency-blocked approval to fail")
except urllib.error.HTTPError as error:
    assert error.code == 409
    blocked_payload = json.load(error)

assert blocked_payload["error"] == f"Blocked by {bootstrap_id} (pending_approval)."

with open(registry_path, "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

for task in persisted["tasks"]:
    if task["id"] == bootstrap_id:
        task["status"] = "completed"
        task["completed_at"] = "2026-03-24T10:15:00Z"
        task["updated_at"] = "2026-03-24T10:15:00Z"
        break
else:
    raise SystemExit("bootstrap task missing from registry")

with open(registry_path, "w", encoding="utf-8") as handle:
    json.dump(persisted, handle, indent=2)
    handle.write("\n")

approved = post("/api/task-registry/action", {"id": dependent_id, "action": "approve"})
assert approved["task"]["status"] == "approved"
assert approved["task"]["queue_handoff"]["status"] == "queued"

queue_file = os.path.join(root, "queues", "dep-smoke.txt")
with open(queue_file, "r", encoding="utf-8") as handle:
    queue_lines = [line.strip() for line in handle if line.strip()]

assert queue_lines == ["Add Gradle wrapper files"]
PY

echo "task dependency approval guard test passed"
