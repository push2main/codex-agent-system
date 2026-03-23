#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
DASHBOARD_PID=""
TEST_ROOT="$TMP_DIR/dashboard-fixture"
TEST_PROJECTS_DIR="$TEST_ROOT/projects"
TEST_QUEUES_DIR="$TEST_ROOT/queues"
TEST_MEMORY_DIR="$TEST_ROOT/codex-memory"
TEST_LOGS_DIR="$TEST_ROOT/codex-logs"
TEST_LEARNING_DIR="$TEST_ROOT/codex-learning"
TEST_TASKS_FILE="$TEST_MEMORY_DIR/tasks.json"
TEST_STATUS_FILE="$TEST_ROOT/status.txt"
TEST_SYSTEM_LOG_FILE="$TEST_LOGS_DIR/system.log"
TEST_METRICS_FILE="$TEST_LEARNING_DIR/metrics.json"
TEST_PRIORITY_FILE="$TEST_MEMORY_DIR/priority.json"
TEST_TASK_LOG_FILE="$TEST_MEMORY_DIR/tasks.log"
TEST_SETTINGS_FILE="$TEST_MEMORY_DIR/dashboard-settings.json"
TEST_PORT=3212

cleanup() {
  if [ -n "$DASHBOARD_PID" ]; then
    kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
    wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_PROJECTS_DIR" "$TEST_QUEUES_DIR" "$TEST_MEMORY_DIR" "$TEST_LOGS_DIR" "$TEST_LEARNING_DIR"
printf '{\n  "tasks": []\n}\n' >"$TEST_TASKS_FILE"
printf '' >"$TEST_TASK_LOG_FILE"
printf '' >"$TEST_SYSTEM_LOG_FILE"
cat >"$TEST_PRIORITY_FILE" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
cat >"$TEST_METRICS_FILE" <<'EOF'
{
  "total_tasks": 0,
  "success_rate": 0,
  "analysis_runs": 0,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "last_task_score": 0,
  "manual_recovery_records": 0
}
EOF
cat >"$TEST_SETTINGS_FILE" <<'EOF'
{
  "approval_mode": "auto",
  "updated_at": "2026-03-23T08:00:00Z"
}
EOF
cat >"$TEST_STATUS_FILE" <<'EOF'
state=idle
project=
task=
last_result=NONE
note=waiting_for_tasks=1
updated_at=2026-03-23T08:00:00Z
EOF

DASHBOARD_PORT="$TEST_PORT" \
DASHBOARD_PROJECTS_DIR="$TEST_PROJECTS_DIR" \
DASHBOARD_QUEUES_DIR="$TEST_QUEUES_DIR" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_SYSTEM_LOG_FILE" \
DASHBOARD_METRICS_FILE="$TEST_METRICS_FILE" \
DASHBOARD_PRIORITY_FILE="$TEST_PRIORITY_FILE" \
DASHBOARD_TASK_LOG_FILE="$TEST_TASK_LOG_FILE" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_TASKS_FILE" \
DASHBOARD_SETTINGS_FILE="$TEST_SETTINGS_FILE" \
DASHBOARD_STATUS_FILE="$TEST_STATUS_FILE" \
node "$ROOT_DIR/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$TEST_PORT" "$TEST_TASKS_FILE" "$TEST_QUEUES_DIR" <<'PY'
import json
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

port = sys.argv[1]
tasks_path = Path(sys.argv[2])
queues_dir = Path(sys.argv[3])
base_url = f"http://127.0.0.1:{port}"

for _ in range(20):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            json.load(response)
        break
    except Exception:
        time.sleep(0.25)
else:
    raise SystemExit("dashboard did not become ready")

payloads = [
    {
        "project": "codex-agent-system",
        "title": "Concurrent UI task alpha",
        "category": "ui",
        "impact": 7,
        "effort": 2,
        "confidence": 0.82,
        "executionProvider": "claude",
        "autoApprove": True,
    },
    {
        "project": "codex-agent-system",
        "title": "Concurrent UI task beta",
        "category": "ui",
        "impact": 7,
        "effort": 2,
        "confidence": 0.82,
        "executionProvider": "claude",
        "autoApprove": True,
    },
]

def post_task(task_payload):
    body = json.dumps(task_payload).encode("utf-8")
    request = urllib.request.Request(
        f"{base_url}/api/task-registry",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.load(response)

with ThreadPoolExecutor(max_workers=2) as executor:
    results = list(executor.map(post_task, payloads))

assert all(result.get("ok") for result in results), results
assert all(result["task"]["status"] == "approved" for result in results), results
assert len({result["task"]["id"] for result in results}) == 2, results

payload = json.loads(tasks_path.read_text())
tasks = payload.get("tasks", [])
tracked = [task for task in tasks if task.get("title") in {"Concurrent UI task alpha", "Concurrent UI task beta"}]
assert len(tracked) == 2, tracked
assert all(task.get("status") == "approved" for task in tracked), tracked
assert len({task.get("id") for task in tracked}) == 2, tracked

queue_entries = []
for queue_file in queues_dir.glob("*.txt"):
    queue_entries.extend([line.strip() for line in queue_file.read_text().splitlines() if line.strip()])

assert "Concurrent UI task alpha" in queue_entries, queue_entries
assert "Concurrent UI task beta" in queue_entries, queue_entries
PY

echo "dashboard task registry serial test passed"
