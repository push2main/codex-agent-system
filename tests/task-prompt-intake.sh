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
    raise SystemExit("dashboard prompt-intake endpoint did not become ready")

prompt_text = "\n".join(
    [
        "Refine the mobile dashboard task cards for iPhone widths.",
        "Show the active provider and lane in a compact live work strip.",
        "Add an audit summary panel for security and governance signals.",
    ]
)

request = urllib.request.Request(
    f"{base_url}/api/task-registry/intake",
    data=json.dumps({"project": "registry-smoke", "prompt": prompt_text}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    assert response.status == 201
    created = json.load(response)

assert created["ok"] is True
assert created["created_count"] == 3
assert created["message"] == "Derived 3 tasks for registry-smoke."
assert created["skipped"] == []

tasks = created["tasks"]
assert [task["id"] for task in tasks] == [
    "task-001-refine-the-mobile-dashboard-task-cards-f",
    "task-002-show-the-active-provider-and-lane-in-a-c",
    "task-003-add-an-audit-summary-panel-for-security-",
]
assert [task["title"] for task in tasks] == [
    "Refine the mobile dashboard task cards for iPhone widths",
    "Show the active provider and lane in a compact live work strip",
    "Add an audit summary panel for security and governance signals",
]
assert all(task["status"] == "pending_approval" for task in tasks)
assert [task["category"] for task in tasks] == ["ui", "code_quality", "stability"]
assert [task["execution_provider"] for task in tasks] == ["codex", "codex", "codex"]
assert all(task["task_intent"]["source"] == "dashboard_prompt_intake" for task in tasks)
assert all(task["prompt_intake"]["source"] == "dashboard_prompt_intake" for task in tasks)
assert [task["prompt_intake"]["index"] for task in tasks] == [1, 2, 3]
assert all(task["prompt_intake"]["total"] == 3 for task in tasks)
assert all(task["history"][0]["note"].startswith("Task was derived from dashboard prompt intake") for task in tasks)

duplicate_request = urllib.request.Request(
    f"{base_url}/api/task-registry/intake",
    data=json.dumps({"project": "registry-smoke", "prompt": prompt_text}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(duplicate_request, timeout=2)
    raise SystemExit("expected duplicate prompt-derived tasks to fail")
except urllib.error.HTTPError as error:
    assert error.code == 409
    duplicate_payload = json.load(error)

assert duplicate_payload["error"] == "Prompt only produced tasks that are already tracked for this project."

malformed_prompt = "\n".join(
    [
        "You are a senior AI systems engineer.",
        "1. Analyze itself and connected projects.",
        "2. Identify weaknesses and opportunities.",
        "3. Generate improvement tasks.",
    ]
)

malformed_request = urllib.request.Request(
    f"{base_url}/api/task-registry/intake",
    data=json.dumps({"project": "registry-smoke", "prompt": malformed_prompt}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(malformed_request, timeout=2)
    raise SystemExit("expected malformed prompt-derived tasks to fail")
except urllib.error.HTTPError as error:
    assert error.code == 400
    malformed_payload = json.load(error)

assert malformed_payload["error"] == "Prompt only produced malformed or non-actionable task candidates."
assert "created_count" not in malformed_payload or malformed_payload["created_count"] == 0
assert "tasks" not in malformed_payload or malformed_payload["tasks"] == []

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
    registry = json.load(response)

assert len(registry["tasks"]) == 3
assert registry["summary"]["byStatus"]["pending_approval"] == 3

with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
    metrics = json.load(response)

assert metrics["pendingApproval"] == 3
assert metrics["taskRegistryTotal"] == 3

with open(os.path.join(root, "codex-learning", "metrics.json"), "r", encoding="utf-8") as handle:
    persisted_metrics = json.load(handle)

assert persisted_metrics["analysis_runs"] == 3
assert persisted_metrics["pending_approval_tasks"] == 3
assert persisted_metrics["task_registry_total"] == 3
PY

echo "task prompt intake test passed"
