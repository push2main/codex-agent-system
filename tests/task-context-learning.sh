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
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

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

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-context-completed",
      "title": "Persist dashboard task intent metadata before queue handoff",
      "impact": 7,
      "effort": 3,
      "confidence": 0.8,
      "category": "ui",
      "project": "codex-agent-system",
      "reason": "Completed context-rich task.",
      "task_intent": {
        "source": "dashboard_backlog",
        "objective": "Persist dashboard task intent metadata before queue handoff",
        "project": "codex-agent-system",
        "category": "ui",
        "context_hint": "Store deterministic intent for dashboard-submitted work.",
        "constraints": [
          "Keep the change small and reversible.",
          "Preserve system stability.",
          "Verify the change before completion."
        ],
        "success_signals": []
      },
      "execution_context": {
        "run_id": "run-completed",
        "result": "SUCCESS",
        "attempts": 1,
        "score": 8,
        "duration_seconds": 12,
        "step_count": 3,
        "completed_steps": 3,
        "failed_step_index": 0,
        "failed_step": "",
        "plan_steps": [
          "Inspect createTaskRegistryItem.",
          "Persist task_intent.",
          "Verify task creation."
        ],
        "updated_at": "2026-03-22T17:00:00Z"
      },
      "score": 2.52,
      "status": "completed",
      "created_at": "2026-03-22T16:50:00Z",
      "updated_at": "2026-03-22T17:00:00Z"
    },
    {
      "id": "task-002-context-failed",
      "title": "Restart the queue session automatically after runtime helper changes",
      "impact": 8,
      "effort": 5,
      "confidence": 0.78,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Automatic restart proved too broad.",
      "failure_context": {
        "run_id": "run-failed",
        "result": "FAILURE",
        "attempts": 2,
        "failed_step_index": 1,
        "failed_step": "Inspect the active tmux runtime lifecycle and choose the smallest restart hook.",
        "updated_at": "2026-03-22T17:01:00Z"
      },
      "score": 2.25,
      "status": "failed",
      "created_at": "2026-03-22T16:55:00Z",
      "updated_at": "2026-03-22T17:01:00Z"
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

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
        with urllib.request.urlopen(f"{base_url}/api/status", timeout=1):
            break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

request = urllib.request.Request(
    f"{base_url}/api/task-registry",
    data=json.dumps(
        {
            "project": "codex-agent-system",
            "task": "Persist execution context for each task run",
            "contextHint": "Store structured outcome context after every task execution.",
            "successCriteria": "execution context is written\nfailure context is written for failures",
            "constraints": "keep task lifecycle stable\nno queue behavior changes",
            "affectedFiles": "scripts/lib.sh\nagents/orchestrator.sh"
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    payload = json.load(response)

task = payload["task"]
assert task["task_intent"]["objective"] == "Persist execution context for each task run"
assert task["execution_provider"] == "codex"
assert task["task_intent"]["context_hint"] == "Store structured outcome context after every task execution."
assert task["task_intent"]["source"] == "dashboard_backlog"
assert task["task_intent"]["success_signals"] == [
    "execution context is written",
    "failure context is written for failures",
]
assert task["task_intent"]["constraints"] == [
    "keep task lifecycle stable",
    "no queue behavior changes",
]
assert task["task_intent"]["affected_files"] == ["scripts/lib.sh", "agents/orchestrator.sh"]
PY

SIMILAR_CONTEXT="$(
  cd "$TEST_ROOT"
  bash -lc 'source scripts/lib.sh; build_similar_task_context "persist dashboard task intent metadata" "codex-agent-system"'
)"

python3 - <<'PY' "$SIMILAR_CONTEXT"
import json
import sys

payload = json.loads(sys.argv[1])
assert len(payload) >= 1
match = next(item for item in payload if item["id"] == "task-001-context-completed")
assert match["task_intent"]["objective"] == "Persist dashboard task intent metadata before queue handoff"
assert match["execution_context"]["result"] == "SUCCESS"
PY

cat >"$TMP_DIR/plan.json" <<'EOF'
{
  "status": "success",
  "message": "fixture plan",
  "data": {
    "steps": [
      "Inspect run persistence hook.",
      "Persist execution_context and failure_context.",
      "Verify tasks.json updates."
    ]
  }
}
EOF

(
  cd "$TEST_ROOT"
  bash -lc 'source scripts/lib.sh; persist_task_run_context "codex-agent-system" "Restart the queue session automatically after runtime helper changes" "FAILURE" "run-xyz" "2" "3" "45" "3" "1" "1" "Inspect the active tmux runtime lifecycle and choose the smallest restart hook." "'"$TMP_DIR"'/plan.json" "claude" "2026-03-22T17:01:30Z"'
)

python3 - "$TEST_ROOT" <<'PY'
import json
import os
import sys

root = sys.argv[1]
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    payload = json.load(handle)

task = next(item for item in payload["tasks"] if item["id"] == "task-002-context-failed")
execution = task["execution_context"]
failure = task["failure_context"]

assert execution["run_id"] == "run-xyz"
assert execution["provider"] == "claude"
assert execution["result"] == "FAILURE"
assert execution["duration_seconds"] == 45
assert execution["step_count"] == 3
assert execution["completed_steps"] == 1
assert execution["plan_steps"][1] == "Persist execution_context and failure_context."
assert failure["failed_step_index"] == 1
assert failure["provider"] == "claude"
assert failure["timestamp"] == "2026-03-22T17:01:30Z"
assert "smallest restart hook" in failure["failed_step"]
PY

echo "task context learning test passed"
