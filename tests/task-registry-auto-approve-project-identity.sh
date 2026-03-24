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
  local port=4760
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
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-cross-project-auto-approval-smoke",
      "title": "Cross-project auto approval smoke",
      "project": "codex-agent-system",
      "category": "stability",
      "reason": "Historical task kept to force a duplicate id in another shared-registry project.",
      "status": "rejected",
      "updated_at": "2026-03-24T14:00:00Z",
      "rejected_at": "2026-03-24T14:00:00Z",
      "task_shape": {
        "approval_ready": true,
        "manual_review_required": false,
        "verification_command": "",
        "reasons": []
      },
      "history": [
        {
          "at": "2026-03-24T14:00:00Z",
          "action": "reject",
          "from_status": "pending_approval",
          "to_status": "rejected",
          "project": "codex-agent-system",
          "queue_task": "Cross-project auto approval smoke",
          "note": "Historical fixture."
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
  "memory_file": "$TEST_ROOT/projects/superheld/memory.md",
  "spec_file": "$TEST_ROOT/projects/superheld/spec.md",
  "policy_file": "$TEST_ROOT/projects/superheld/policy.json"
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
note=Auto approve identity fixture
updated_at=2026-03-24T14:00:00Z
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{"approval_mode":"auto","updated_at":"2026-03-24T14:00:00Z"}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
import time
import urllib.request

port = sys.argv[1]
tasks_path = sys.argv[2]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

request = urllib.request.Request(
    f"{base_url}/api/task-registry",
    data=json.dumps(
        {
            "project": "superheld",
            "task": "Cross-project auto approval smoke",
            "title": "Cross-project auto approval smoke",
            "category": "stability",
            "autoApprove": True,
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    payload = json.load(response)

assert payload["ok"] is True
assert payload["task"]["id"] == "task-001-cross-project-auto-approval-smoke"
assert payload["task"]["project"] == "superheld"
assert payload["task"]["status"] in {"approved", "running"}, payload["task"]
assert payload["auto_approve"]["approved"] == [{"id": "task-001-cross-project-auto-approval-smoke", "project": "superheld"}]

with open(tasks_path, "r", encoding="utf-8") as handle:
    tasks = json.load(handle)["tasks"]

root_task = next(task for task in tasks if task["project"] == "codex-agent-system")
project_task = next(task for task in tasks if task["project"] == "superheld")

assert root_task["status"] == "rejected"
assert project_task["status"] in {"approved", "running"}, project_task
assert project_task["queue_handoff"]["project"] == "superheld"
assert project_task["history"][-1]["action"] == "approve"
PY

grep -q 'const approvalProject = escapeHtml(task.project || "codex-agent-system");' "$TEST_ROOT/codex-dashboard/index.html"
grep -q 'data-task-action="approve" data-task-id="${taskId}" data-task-project="${approvalProject}"' "$TEST_ROOT/codex-dashboard/index.html"
grep -q 'data-task-action="reject" data-task-id="${taskId}" data-task-project="${approvalProject}"' "$TEST_ROOT/codex-dashboard/index.html"

echo "task registry auto-approve project identity test passed"
