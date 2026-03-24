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
  local port=5070
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
      "reason": "All enterprise-readiness seed templates are saturated and the board has no actionable tasks, so the strategy loop needs one explicit recovery task instead of returning a silent no-op. The latest saturated failure is 'Align persisted first-pass success metrics' (bounded_failed_step_child).",
      "task_intent": {
        "source": "strategy_saturation",
        "objective": "Choose a different bounded experiment after strategy saturation stalls the board",
        "project": "codex-agent-system",
        "category": "learning",
        "context_hint": "Strategy saturation recovery backlog"
      },
      "task_shape": {
        "approval_ready": true,
        "requires_split": false,
        "reasons": [],
        "manual_review_required": false,
        "risk_profile": "standard",
        "risk_flags": [],
        "verification_command": "",
        "updated_at": "2026-03-24T08:00:00Z"
      },
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z",
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
      "id": "task-first-pass-followup",
      "title": "Align persisted first-pass success metrics",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "failed",
      "strategy_template": "bounded_failed_step_child",
      "execution_provider": "codex",
      "failure_context": {
        "failed_step": "Run `bash tests/system-smoke.sh` as the single deterministic verification command and treat exit code `0` as success; if it fails, limit the follow-up fix strictly to the first-pass metrics path surfaced by that command."
      },
      "created_at": "2026-03-24T07:40:00Z",
      "updated_at": "2026-03-24T07:50:00Z"
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
expected_title = "Fix first-pass metrics path"
expected_context = "Derived from saturated experiment: Align persisted first-pass success metrics"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            registry = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard legacy saturation repair endpoint did not become ready")

tasks = {task["id"]: task for task in registry["tasks"]}
task = tasks["task-saturation-recovery"]
assert task["title"] == expected_title
assert task["execution_task"] == expected_title
assert task["saturation_recovery"] == {
    "kind": "replace_saturated_experiment",
    "replaces_task_id": "task-first-pass-followup",
    "replaces_title": "Align persisted first-pass success metrics",
    "replaces_strategy_template": "bounded_failed_step_child",
    "replaces_category": "learning",
}
assert task["task_intent"]["source"] == "strategy_saturation"
assert task["task_intent"]["objective"] == expected_title
assert task["task_intent"]["context_hint"] == expected_context
assert task["execution_provider"] == "claude"
assert task["provider_selection"]["selected"] == "claude"
assert task["provider_selection"]["source"] == "task_registry"
assert "Saturation recovery rerouted this replacement task from codex to claude" in task["provider_selection"]["reason"]
assert task["last_history_entry"]["action"] == "auto_repair"
assert task["task_shape"]["approval_ready"] is True
assert task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"

preserved_shape_updated_at = task["task_shape"]["updated_at"]
preserved_history_length = len(task["history"])

tasks_path = os.path.join(root, "codex-memory", "tasks.json")
with open(tasks_path, "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

for entry in persisted["tasks"]:
    if entry.get("id") != "task-first-pass-followup":
        continue
    failure_context = entry.get("failure_context") if isinstance(entry.get("failure_context"), dict) else {}
    failure_context["failed_step"] = (
        "Limit the follow-up fix strictly to the first-pass metrics path surfaced by the failing metrics command."
    )
    entry["failure_context"] = failure_context

with open(tasks_path, "w", encoding="utf-8") as handle:
    json.dump(persisted, handle, indent=2)
    handle.write("\n")

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
    repaired_again = json.load(response)

repaired_task = {item["id"]: item for item in repaired_again["tasks"]}["task-saturation-recovery"]
assert repaired_task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert repaired_task["task_shape"]["updated_at"] == preserved_shape_updated_at
assert len(repaired_task["history"]) == preserved_history_length

with open(tasks_path, "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

persisted_task = {entry["id"]: entry for entry in persisted["tasks"]}["task-saturation-recovery"]
assert persisted_task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert persisted_task["task_shape"]["updated_at"] == preserved_shape_updated_at
assert len(persisted_task["history"]) == preserved_history_length

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
assert approved["task"]["queue_handoff"]["provider"] == "claude"
assert approved["task"]["execution_brief"]["task_intent"]["context_hint"] == expected_context
assert approved["task"]["execution_brief"]["provider"] == "claude"

queue_file = os.path.join(root, "queues", "codex-agent-system.txt")
with open(queue_file, "r", encoding="utf-8") as handle:
    queue_lines = [line.strip() for line in handle if line.strip()]

assert queue_lines == [expected_title]

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

persisted_task = {entry["id"]: entry for entry in persisted["tasks"]}["task-saturation-recovery"]
assert persisted_task["saturation_recovery"]["replaces_task_id"] == "task-first-pass-followup"
assert persisted_task["execution_provider"] == "claude"
assert persisted_task["provider_selection"]["selected"] == "claude"
assert persisted_task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert persisted_task["history"][-2]["action"] == "auto_repair"
assert persisted_task["history"][-1]["action"] == "approve"
assert persisted_task["history"][-1]["queue_task"] == expected_title
PY

echo "pending approval legacy saturation repair test passed"
