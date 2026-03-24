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
  local port=5040
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

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-timeout-reference",
      "title": "Tighten late timeout reconciliation for claimed queue tasks",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "strategy_template": "enterprise_timeout_stability",
      "created_at": "2026-03-24T02:00:00Z",
      "updated_at": "2026-03-24T02:06:00Z",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Tighten late timeout reconciliation for claimed queue tasks",
        "project": "codex-agent-system",
        "category": "stability",
        "context_hint": "Lane-4 timed out on the `superheld` Gradle-wrapper task after step 2/3, so focus on the bounded late-outcome reconciliation path for claimed tasks.",
        "constraints": [
          "Touch only timeout reconciliation or its deterministic observability path.",
          "Do not change queue scheduling, retry limits, or strategy task generation."
        ],
        "success_signals": [
          "Late terminal evidence prevents a fresh timeout failure classification for the claimed task.",
          "Existing timeout reconciliation tests stay green."
        ],
        "affected_files": [
          "scripts/lib.sh",
          "tests/queue-worker-timeout-success-reconciliation.sh",
          "tests/queue-worker-timeout-log-success-reconciliation.sh",
          "tests/queue-worker-timeout-classification.sh"
        ]
      },
      "timeout_failure_learning": {
        "detected": true,
        "timeout_failure_records": 4,
        "timeout_failure_rate": 0.13,
        "observed_example_project": "superheld",
        "observed_example_lane": "lane-4",
        "observed_example_task": "Resolve exact Gradle wrapper version for the current Android baseline"
      }
    },
    {
      "id": "task-timeout-pending",
      "title": "Cut queue timeout churn before retries burn worker capacity",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "pending_approval",
      "strategy_template": "enterprise_timeout_stability",
      "created_at": "2026-03-24T03:00:00Z",
      "updated_at": "2026-03-24T03:00:00Z",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Cut queue timeout churn before retries burn worker capacity",
        "project": "codex-agent-system",
        "category": "stability",
        "context_hint": "Observed queue timeout pressure",
        "constraints": [],
        "success_signals": [],
        "affected_files": []
      },
      "timeout_failure_learning": {
        "detected": true,
        "timeout_failure_records": 5,
        "timeout_failure_rate": 0.16
      },
      "history": []
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "timeout_failure_records": 5,
  "timeout_failure_rate": 0.16
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
import urllib.request

port = sys.argv[1]
root = sys.argv[2]
base_url = f"http://127.0.0.1:{port}"
expected_context = "Lane-4 timed out on the `superheld` Gradle-wrapper task after step 2/3, so focus on the bounded late-outcome reconciliation path for claimed tasks."
expected_constraints = [
    "Touch only timeout reconciliation or its deterministic observability path.",
    "Do not change queue scheduling, retry limits, or strategy task generation.",
]
expected_signals = [
    "Late terminal evidence prevents a fresh timeout failure classification for the claimed task.",
    "Existing timeout reconciliation tests stay green.",
]
expected_files = [
    "scripts/lib.sh",
    "tests/queue-worker-timeout-success-reconciliation.sh",
    "tests/queue-worker-timeout-log-success-reconciliation.sh",
    "tests/queue-worker-timeout-classification.sh",
]

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            registry = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard timeout queue-shape endpoint did not become ready")

task = next(item for item in registry["tasks"] if item["id"] == "task-timeout-pending")
assert task["task_intent"]["context_hint"] == expected_context
assert task["task_intent"]["constraints"] == expected_constraints
assert task["task_intent"]["success_signals"] == expected_signals
assert task["task_intent"]["affected_files"] == expected_files
assert task["timeout_failure_learning"]["observed_example_project"] == "superheld"
assert task["timeout_failure_learning"]["observed_example_lane"] == "lane-4"
assert task["timeout_failure_learning"]["observed_example_task"] == "Resolve exact Gradle wrapper version for the current Android baseline"
assert task["last_history_entry"]["action"] == "auto_repair"
assert "prior timeout guidance" in task["last_history_entry"]["note"]

approve_request = urllib.request.Request(
    f"{base_url}/api/task-registry/action",
    data=json.dumps({"id": "task-timeout-pending", "action": "approve"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(approve_request, timeout=2) as response:
    approved = json.load(response)

assert approved["ok"] is True
assert approved["task"]["status"] == "approved"
assert approved["task"]["queue_handoff"]["task"] == "Cut queue timeout churn before retries burn worker capacity"
assert approved["task"]["queue_handoff"]["task_intent"]["context_hint"] == expected_context
assert approved["task"]["queue_handoff"]["task_intent"]["constraints"] == expected_constraints
assert approved["task"]["queue_handoff"]["task_intent"]["success_signals"] == expected_signals
assert approved["task"]["queue_handoff"]["task_intent"]["affected_files"] == expected_files
assert approved["task"]["execution_brief"]["queue_task"] == "Cut queue timeout churn before retries burn worker capacity"
assert approved["task"]["execution_brief"]["task_intent"]["context_hint"] == expected_context
assert approved["task"]["execution_brief"]["task_intent"]["constraints"] == expected_constraints
assert approved["task"]["execution_brief"]["task_intent"]["success_signals"] == expected_signals
assert approved["task"]["execution_brief"]["task_intent"]["affected_files"] == expected_files

queue_file = os.path.join(root, "queues", "codex-agent-system.txt")
with open(queue_file, "r", encoding="utf-8") as handle:
    queue_lines = [line.strip() for line in handle if line.strip()]

assert queue_lines == ["Cut queue timeout churn before retries burn worker capacity"]

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

persisted_task = next(item for item in persisted["tasks"] if item["id"] == "task-timeout-pending")
assert persisted_task["task_intent"]["context_hint"] == expected_context
assert persisted_task["task_intent"]["constraints"] == expected_constraints
assert persisted_task["task_intent"]["success_signals"] == expected_signals
assert persisted_task["task_intent"]["affected_files"] == expected_files
assert persisted_task["timeout_failure_learning"]["observed_example_project"] == "superheld"
assert persisted_task["timeout_failure_learning"]["observed_example_lane"] == "lane-4"
assert persisted_task["timeout_failure_learning"]["observed_example_task"] == "Resolve exact Gradle wrapper version for the current Android baseline"
assert persisted_task["history"][-2]["action"] == "auto_repair"
assert persisted_task["history"][-1]["action"] == "approve"
PY

echo "pending approval timeout queue shape test passed"
