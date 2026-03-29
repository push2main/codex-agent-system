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
  local port=4995
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
  "$TEST_ROOT/projects/payload-smoke" \
  "$TEST_ROOT/queues"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-dashboard-payload",
            "title": "Keep dashboard snapshots compact under heavy task history",
            "project": "payload-smoke",
            "category": "performance",
            "status": "completed",
            "score": 4.1,
            "created_at": "2026-03-24T16:00:00Z",
            "updated_at": "2026-03-24T16:03:00Z",
            "completed_at": "2026-03-24T16:03:00Z",
            "history": [
                {
                    "action": "create",
                    "at": "2026-03-24T16:00:00Z",
                    "to_status": "pending_approval",
                    "note": "created"
                },
                {
                    "action": "execute_success",
                    "at": "2026-03-24T16:03:00Z",
                    "from_status": "approved",
                    "to_status": "completed",
                    "note": "x" * 400000
                }
            ],
            "execution": {
                "state": "completed",
                "result": "SUCCESS",
                "attempt": 1,
                "max_retries": 2,
                "updated_at": "2026-03-24T16:03:00Z"
            },
            "execution_context": {
                "completed_steps": 2,
                "step_count": 2,
                "plan_steps": [
                    "Inspect the current dashboard payload shape " + ("x" * 90000),
                    "Trim unused heavy fields from the snapshot path " + ("x" * 90000)
                ],
                "owner": "lane-1",
                "worker": "queue-worker-1",
                "total_step_attempts": 5
            },
            "failure_context": {
                "summary": "x" * 160000,
                "latest_error": "x" * 140000,
                "total_step_attempts": 5
            },
            "task_intent": {
                "source": "strategy",
                "objective": "Keep the dashboard payload lean during polling.",
                "constraints": [
                    "Do not change queue semantics",
                    "Only trim fields the dashboard does not render"
                ],
                "success_signals": [
                    "dashboard snapshot excludes non-rendered task metadata"
                ]
            },
            "execution_brief": {
                "objective": "Keep the combined dashboard payload compact",
                "context_hint": "x" * 120000,
                "affected_files": [
                    "codex-dashboard/server.js"
                ],
                "task_intent": {
                    "objective": "nested intent duplication"
                }
            },
            "approval_execution_brief": {
                "approved_at": "2026-03-24T16:01:00Z",
                "queue_task": "Keep dashboard snapshots compact under heavy task history",
                "context_hint": "x" * 60000
            },
            "queue_handoff": {
                "at": "2026-03-24T16:01:00Z",
                "project": "payload-smoke",
                "task": "Keep dashboard snapshots compact under heavy task history",
                "status": "queued",
                "provider": "codex",
                "task_intent": {
                    "objective": "Keep the dashboard payload lean during polling.",
                    "constraints": [
                        "Only trim fields the dashboard does not render"
                    ],
                    "success_signals": [
                        "compact snapshot keeps handoff summary only"
                    ]
                }
            },
            "task_shape": {
                "approval_ready": True,
                "requires_split": False,
                "reasons": [],
                "manual_review_required": False,
                "risk_profile": "low",
                "risk_flags": [],
                "verification_command": "bash tests/dashboard-compact-task-payload.sh",
                "updated_at": "2026-03-24T16:01:00Z"
            }
        }
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-24T16:00:00Z"
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 1,
  "success_rate": 100,
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 1,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 1,
  "last_task_score": 4.1,
  "manual_recovery_records": 0
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
state=idle
project=
task=
last_result=SUCCESS
note=dashboard compact payload smoke
updated_at=2026-03-24T16:03:00Z
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_TASKS_FILE="$TEST_ROOT/codex-memory/tasks.json"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$DASHBOARD_TASKS_FILE" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
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
            dashboard_payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
    registry_payload = json.load(response)

dashboard_task = dashboard_payload["taskRegistry"]["tasks"][0]
registry_task = registry_payload["tasks"][0]

assert "history" not in dashboard_task
assert "execution_brief" not in dashboard_task
assert "approval_execution_brief" not in dashboard_task
assert "task_intent" not in dashboard_task
assert "failure_context" not in dashboard_task
assert "execution_context" in dashboard_task
assert dashboard_task["queue_handoff"] == {
    "at": "2026-03-24T16:01:00Z",
    "task": "Keep dashboard snapshots compact under heavy task history",
    "status": "queued",
}
assert "task_shape" not in dashboard_task
assert "plan_steps" not in dashboard_task["execution_context"]
assert dashboard_task["execution_context"]["total_step_attempts"] == 5
assert dashboard_task["history_length"] == 2
assert len(dashboard_task["history_preview"]) == 2
assert dashboard_task["last_history_entry"]["action"] == "execute_success"
assert len(registry_task["history"]) == 2
assert "execution_brief" in registry_task
assert "approval_execution_brief" in registry_task
assert "task_intent" in registry_task
assert "failure_context" in registry_task
assert "task_intent" in registry_task["queue_handoff"]
assert "verification_command" in registry_task["task_shape"]
assert "plan_steps" in registry_task["execution_context"]

dashboard_bytes = len(json.dumps(dashboard_payload))
registry_bytes = len(json.dumps(registry_payload))
assert dashboard_bytes + 800000 < registry_bytes, (dashboard_bytes, registry_bytes)
PY

echo "dashboard compact task payload test passed"
