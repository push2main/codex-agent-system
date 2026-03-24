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
  local port=5030
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
      "id": "task-saturation-recovery",
      "title": "Choose a different bounded experiment after strategy saturation stalls the board",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "pending_approval",
      "strategy_template": "strategy_saturation_rescue",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z",
      "task_intent": {
        "source": "strategy_saturation",
        "objective": "Choose a different bounded experiment after strategy saturation stalls the board",
        "project": "codex-agent-system",
        "category": "learning",
        "context_hint": "Strategy saturation recovery backlog"
      },
      "saturation_recovery": {
        "kind": "replace_saturated_experiment",
        "replaces_task_id": "task-learning-2",
        "replaces_title": "Feed execution learning back into future provider and task decisions",
        "replaces_strategy_template": "enterprise_learning_feedback",
        "replaces_category": "code_quality"
      },
      "history": [
        {
          "at": "2026-03-24T08:00:00Z",
          "action": "create",
          "from_status": "",
          "to_status": "pending_approval",
          "project": "codex-agent-system",
          "queue_task": "Choose a different bounded experiment after strategy saturation stalls the board",
          "note": "Task was added from strategy saturation recovery after all enterprise templates hit the saturation guard."
        }
      ]
    },
    {
      "id": "task-learning-2",
      "title": "Feed execution learning back into future provider and task decisions",
      "project": "codex-agent-system",
      "category": "code_quality",
      "status": "failed",
      "strategy_template": "enterprise_learning_feedback",
      "execution_provider": "codex",
      "provider_selection": {
        "selected": "codex",
        "source": "strategy_default",
        "reason": "Strategy defaults enterprise follow-up tasks to codex unless a task pins a different provider."
      },
      "updated_at": "2026-03-24T07:50:00Z",
      "created_at": "2026-03-24T07:40:00Z"
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
expected_title = "Replace Feed execution learning back into future provider and task decisions with a different bounded experiment"
expected_context = "Replace saturated experiment: Feed execution learning back into future provider and task decisions"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            registry = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard saturation queue-shape endpoint did not become ready")

task = registry["tasks"][0]
assert task["id"] == "task-saturation-recovery"
assert task["title"] == expected_title
assert task["execution_task"] == expected_title
assert task["task_intent"]["source"] == "strategy_saturation"
assert task["task_intent"]["objective"] == expected_title
assert task["task_intent"]["context_hint"] == expected_context
assert task["execution_provider"] == "claude"
assert task["provider_selection"]["selected"] == "claude"
assert task["provider_selection"]["source"] == "task_registry"
assert "Saturation recovery rerouted this replacement task from codex to claude" in task["provider_selection"]["reason"]
assert task["task_shape"]["approval_ready"] is True
assert task["last_history_entry"]["action"] == "auto_repair"
assert task["last_history_entry"]["queue_task"] == expected_title

approve_request = urllib.request.Request(
    f"{base_url}/api/task-registry/action",
    data=json.dumps({"id": "task-saturation-recovery", "action": "approve"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(approve_request, timeout=2) as response:
    approved = json.load(response)

assert approved["ok"] is True
assert approved["task"]["status"] == "approved"
assert approved["task"]["queue_handoff"]["task"] == expected_title
assert approved["task"]["queue_handoff"]["status"] == "queued"
assert approved["task"]["queue_handoff"]["provider"] == "claude"
assert approved["task"]["execution_brief"]["queue_task"] == expected_title
assert approved["task"]["execution_brief"]["task_intent"]["context_hint"] == expected_context
assert approved["task"]["execution_brief"]["provider"] == "claude"
assert approved["task"]["approval_execution_brief"]["queue_task"] == expected_title
assert approved["task"]["approval_execution_brief"]["provider"] == "claude"

queue_file = os.path.join(root, "queues", "codex-agent-system.txt")
with open(queue_file, "r", encoding="utf-8") as handle:
    queue_lines = [line.strip() for line in handle if line.strip()]

assert queue_lines == [expected_title]

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

persisted_task = persisted["tasks"][0]
assert persisted_task["title"] == expected_title
assert persisted_task["execution_provider"] == "claude"
assert persisted_task["provider_selection"]["selected"] == "claude"
assert persisted_task["history"][-2]["action"] == "auto_repair"
assert persisted_task["history"][-1]["action"] == "approve"
assert persisted_task["history"][-1]["queue_task"] == expected_title
PY

echo "pending approval saturation queue shape test passed"
