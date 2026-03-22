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
  local port=4600
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
import urllib.error
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
    raise SystemExit("dashboard task-create endpoint did not become ready")

create_request = urllib.request.Request(
    f"{base_url}/api/task-registry",
    data=json.dumps(
        {
            "project": "registry-smoke",
            "task": "Track dashboard-created backlog item",
            "contextHint": "Need a deterministic regression test for dashboard backlog creation.",
            "successCriteria": "task is persisted\nmetrics are updated",
            "constraints": "keep behavior stable\nno direct queue writes",
            "affectedFiles": "codex-dashboard/server.js,codex-memory/tasks.json",
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(create_request, timeout=2) as response:
    assert response.status == 201
    created = json.load(response)

task = created["task"]
assert created["ok"] is True
assert created["message"] == "Task added to backlog."
assert task["id"] == "task-001-track-dashboard-created-backlog-item"
assert task["project"] == "registry-smoke"
assert task["title"] == "Track dashboard-created backlog item"
assert task["status"] == "pending_approval"
assert task["category"] == "code_quality"
assert task["execution_provider"] == "codex"
assert task["provider_selection"]["selected"] == "codex"
assert task["provider_selection"]["source"] == "default"
assert task["task_intent"]["source"] == "dashboard_backlog"
assert task["task_intent"]["objective"] == "Track dashboard-created backlog item"
assert task["task_intent"]["project"] == "registry-smoke"
assert task["task_intent"]["category"] == "code_quality"
assert task["task_intent"]["context_hint"] == "Need a deterministic regression test for dashboard backlog creation."
assert task["task_intent"]["constraints"] == ["keep behavior stable", "no direct queue writes"]
assert task["task_intent"]["success_signals"] == ["task is persisted", "metrics are updated"]
assert task["task_intent"]["affected_files"] == ["codex-dashboard/server.js", "codex-memory/tasks.json"]
assert task["impact"] == 5
assert task["effort"] == 3
assert task["confidence"] == 0.79
assert task["score"] == 1.38
assert task["history"][0]["action"] == "create"
assert task["history"][0]["to_status"] == "pending_approval"

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
    registry = json.load(response)

assert registry["summary"]["nextAction"]["state"] == "approval"
assert registry["summary"]["topPendingTask"]["id"] == task["id"]
assert len(registry["tasks"]) == 1
assert registry["tasks"][0]["history_preview"][0]["action"] == "create"

duplicate_request = urllib.request.Request(
    f"{base_url}/api/task-registry",
    data=json.dumps(
        {
            "project": "registry-smoke",
            "title": "Track dashboard-created backlog item",
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(duplicate_request, timeout=2)
    raise SystemExit("expected duplicate tracked task to fail")
except urllib.error.HTTPError as error:
    assert error.code == 409
    duplicate_payload = json.load(error)

assert duplicate_payload["error"] == "Task is already tracked and actionable for this project."

with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
    metrics = json.load(response)

assert metrics["pendingApproval"] == 1
assert metrics["approved"] == 0
assert metrics["taskRegistryTotal"] == 1
assert metrics["nextAction"]["state"] == "approval"

with open(os.path.join(root, "codex-learning", "metrics.json"), "r", encoding="utf-8") as handle:
    persisted_metrics = json.load(handle)

assert persisted_metrics["analysis_runs"] == 1
assert persisted_metrics["pending_approval_tasks"] == 1
assert persisted_metrics["approved_tasks"] == 0
assert persisted_metrics["task_registry_total"] == 1
assert persisted_metrics["last_task_score"] == 1.38

legacy_request = urllib.request.Request(
    f"{base_url}/api/task",
    data=json.dumps(
        {
            "project": "registry-smoke",
            "task": "Capture legacy direct queue request in approval backlog",
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(legacy_request, timeout=2) as response:
    assert response.status == 202
    redirected = json.load(response)

redirected_task = redirected["task"]
assert redirected["ok"] is True
assert redirected["message"] == "Direct queue is disabled. Task added to backlog for approval."
assert redirected_task["id"] == "task-002-capture-legacy-direct-queue-request-in-a"
assert redirected_task["status"] == "pending_approval"
assert redirected_task["execution_provider"] == "codex"
assert redirected_task["task_intent"]["source"] == "dashboard_backlog"
assert redirected_task["history"][0]["note"] == "Legacy direct queue request was captured in the approval backlog instead of entering the live queue."

queue_file = os.path.join(root, "queues", "registry-smoke.txt")
assert not os.path.exists(queue_file) or os.path.getsize(queue_file) == 0

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
    registry_after_redirect = json.load(response)

assert len(registry_after_redirect["tasks"]) == 2
assert registry_after_redirect["summary"]["byStatus"]["pending_approval"] == 2

with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
    redirected_metrics = json.load(response)

assert redirected_metrics["pendingApproval"] == 2
assert redirected_metrics["approved"] == 0
assert redirected_metrics["taskRegistryTotal"] == 2

with open(os.path.join(root, "codex-learning", "metrics.json"), "r", encoding="utf-8") as handle:
    redirected_persisted_metrics = json.load(handle)

assert redirected_persisted_metrics["analysis_runs"] == 2
assert redirected_persisted_metrics["pending_approval_tasks"] == 2
assert redirected_persisted_metrics["approved_tasks"] == 0
assert redirected_persisted_metrics["task_registry_total"] == 2
assert redirected_persisted_metrics["last_task_score"] == 1.38

with urllib.request.urlopen(f"{base_url}/", timeout=1) as response:
    html = response.read().decode("utf-8")

assert "Add To Board" in html
assert "Success Criteria" in html
assert "Affected Files / Areas" in html
assert "Queue Now" not in html
assert "All new work enters the approval backlog before queue execution." in html
PY

echo "task registry create test passed"
