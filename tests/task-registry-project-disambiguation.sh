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
  "$TEST_ROOT/projects/superheld" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/superheld-memory"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-008-persist-structured-failure-context-for-s",
      "title": "Persist structured failure context for strategy follow-ups",
      "project": "codex-agent-system",
      "category": "stability",
      "reason": "Completed duplicate already exists for the root project.",
      "status": "rejected",
      "updated_at": "2026-03-24T12:00:00Z",
      "rejected_at": "2026-03-24T12:00:00Z",
      "task_shape": {
        "approval_ready": true,
        "manual_review_required": false,
        "verification_command": "",
        "reasons": []
      },
      "history": [
        {
          "at": "2026-03-24T12:00:00Z",
          "action": "prune",
          "from_status": "approved",
          "to_status": "rejected",
          "project": "codex-agent-system",
          "queue_task": "Persist structured failure context for strategy follow-ups",
          "note": "Approved task was pruned because duplicate work already advanced to completed."
        }
      ]
    }
  ]
}
EOF

cat >"$TEST_ROOT/superheld-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-008-persist-structured-failure-context-for-s",
      "title": "Persist structured failure context for strategy follow-ups",
      "project": "superheld",
      "category": "stability",
      "reason": "This is the live pending task that should be approvable.",
      "status": "pending_approval",
      "created_at": "2026-03-24T13:00:42Z",
      "updated_at": "2026-03-24T13:00:42Z",
      "execution_provider": "codex",
      "task_intent": {
        "source": "strategy_followup",
        "objective": "Persist structured failure context for strategy follow-ups",
        "project": "superheld",
        "category": "stability",
        "context_hint": "Choose exact Gradle wrapper version from extracted AGP constraints",
        "constraints": [],
        "success_signals": [],
        "affected_files": []
      },
      "task_shape": {
        "approval_ready": true,
        "manual_review_required": true,
        "verification_command": "",
        "reasons": []
      },
      "history": [
        {
          "at": "2026-03-24T13:00:42Z",
          "action": "create",
          "from_status": "",
          "to_status": "pending_approval",
          "project": "superheld",
          "queue_task": "Persist structured failure context for strategy follow-ups",
          "note": "Task was added from strategy analysis as the next smaller successor to failed task superheld-task-009."
        }
      ]
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
  "risk_profile": "high",
  "auto_approve_allowed": false,
  "manual_review_required_keywords": []
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=idle
project=
task=
last_result=NONE
note=Project disambiguation fixture
updated_at=2026-03-24T12:00:00Z
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"
cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{"approval_mode":"manual","updated_at":"2026-03-24T12:00:00Z"}
EOF

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$TEST_ROOT/codex-memory/tasks.json" "$TEST_ROOT/superheld-memory/tasks.json" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

port = sys.argv[1]
root_tasks_path = sys.argv[2]
project_tasks_path = sys.argv[3]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            registry = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard project disambiguation endpoint did not become ready")

matches = [task for task in registry["tasks"] if task["id"] == "task-008-persist-structured-failure-context-for-s"]
assert len(matches) == 2, matches
assert {task["project"] for task in matches} == {"codex-agent-system", "superheld"}

request = urllib.request.Request(
    f"{base_url}/api/task-registry/action",
    data=json.dumps({"id": "task-008-persist-structured-failure-context-for-s", "action": "approve"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(request, timeout=2)
except urllib.error.HTTPError as error:
    assert error.code == 409
    payload = json.load(error)
    assert payload["error"] == "Task id is ambiguous across projects. Retry with the task project."
else:
    raise AssertionError("ambiguous action unexpectedly succeeded")

request = urllib.request.Request(
    f"{base_url}/api/task-registry/action",
    data=json.dumps(
        {
            "id": "task-008-persist-structured-failure-context-for-s",
            "project": "superheld",
            "action": "approve",
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    payload = json.load(response)

assert payload["ok"] is True
assert payload["task"]["status"] == "approved"
assert payload["task"]["project"] == "superheld"
assert payload["task"]["history"][-1]["action"] == "approve"

with open(root_tasks_path, "r", encoding="utf-8") as handle:
    root_tasks = json.load(handle)["tasks"]
with open(project_tasks_path, "r", encoding="utf-8") as handle:
    project_tasks = json.load(handle)["tasks"]

root_task = next(task for task in root_tasks if task["id"] == "task-008-persist-structured-failure-context-for-s")
project_task = next(task for task in project_tasks if task["id"] == "task-008-persist-structured-failure-context-for-s")

assert root_task["status"] == "rejected"
assert project_task["status"] == "approved"
assert project_task["queue_handoff"]["project"] == "superheld"

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
    refreshed = json.load(response)
refreshed_task = next(
    task
    for task in refreshed["tasks"]
    if task["id"] == "task-008-persist-structured-failure-context-for-s" and task["project"] == "superheld"
)
assert refreshed_task["status"] in {"approved", "running"}, refreshed_task
PY

grep -q 'data-task-project="' "$TEST_ROOT/codex-dashboard/index.html"
grep -q 'body: JSON.stringify({ id: taskId, project, action })' "$TEST_ROOT/codex-dashboard/index.html"

echo "task registry project disambiguation test passed"
