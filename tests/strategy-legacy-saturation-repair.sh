#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

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
      "updated_at": "2026-03-24T07:50:00Z",
      "failed_at": "2026-03-24T07:50:00Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-legacy-saturation-repair.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-legacy-saturation-repair.json" "$TMP_DIR/strategy-legacy-saturation-first-state.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]
first_state_path = sys.argv[3]
expected_title = "Fix first-pass metrics path"
expected_context = "Derived from saturated experiment: Align persisted first-pass success metrics"

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

assert output["status"] == "success"
assert output["message"] == (
    "No new strategy updates for codex-agent-system; waiting on 1 pending approval task(s), including saturation recovery."
    " Verification: bash tests/system-smoke.sh."
)
assert output["data"]["board_updates"] == []
assert output["data"]["board_tasks"] == [
    {
        "id": "task-saturation-recovery",
        "action": "existing",
        "status": "pending_approval",
        "title": expected_title,
        "category": "learning",
        "source_task_id": "strategy::saturation-recovery",
        "updated_at": registry["tasks"][0]["updated_at"],
        "verification_command": "bash tests/system-smoke.sh",
    }
]

task = {entry["id"]: entry for entry in registry["tasks"]}["task-saturation-recovery"]
assert task["title"] == expected_title
assert task["execution_task"] == expected_title
assert task["saturation_recovery"] == {
    "kind": "replace_saturated_experiment",
    "replaces_task_id": "task-first-pass-followup",
    "replaces_title": "Align persisted first-pass success metrics",
    "replaces_strategy_template": "bounded_failed_step_child",
    "replaces_category": "learning",
}
assert task["task_intent"] == {
    "source": "strategy_saturation",
    "objective": expected_title,
    "project": "codex-agent-system",
    "category": "learning",
    "context_hint": expected_context,
    "constraints": [],
    "success_signals": [],
    "affected_files": [],
}
assert task["execution_provider"] == "claude"
assert task["provider_selection"]["selected"] == "claude"
assert task["provider_selection"]["source"] == "task_registry"
assert "rerouted this replacement task from codex to claude" in task["provider_selection"]["reason"]
assert task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert task["history"][-1]["action"] == "auto_repair"
assert task["history"][-1]["queue_task"] == expected_title

with open(first_state_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "updated_at": task["updated_at"],
            "provider_selection_updated_at": task["provider_selection"]["updated_at"],
            "history_length": len(task["history"]),
            "task_shape_updated_at": task["task_shape"]["updated_at"],
        },
        handle,
    )
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-legacy-saturation-repair-second.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-legacy-saturation-repair-second.json" "$TMP_DIR/strategy-legacy-saturation-first-state.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]
first_state_path = sys.argv[3]
expected_title = "Fix first-pass metrics path"

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(first_state_path, "r", encoding="utf-8") as handle:
    first_state = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

task = {entry["id"]: entry for entry in registry["tasks"]}["task-saturation-recovery"]

assert output["status"] == "success"
assert output["message"] == (
    "No new strategy updates for codex-agent-system; waiting on 1 pending approval task(s), including saturation recovery."
    " Verification: bash tests/system-smoke.sh."
)
assert output["data"]["board_updates"] == []
assert output["data"]["board_tasks"] == [
    {
        "id": "task-saturation-recovery",
        "action": "existing",
        "status": "pending_approval",
        "title": expected_title,
        "category": "learning",
        "source_task_id": "strategy::saturation-recovery",
        "updated_at": task["updated_at"],
        "verification_command": "bash tests/system-smoke.sh",
    }
]
assert task["updated_at"] == first_state["updated_at"]
assert task["provider_selection"]["updated_at"] == first_state["provider_selection_updated_at"]
assert task["task_shape"]["updated_at"] == first_state["task_shape_updated_at"]
assert task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert len(task["history"]) == first_state["history_length"]
assert task["history"][-1]["action"] == "auto_repair"
PY

python3 - "$TEST_ROOT" <<'PY'
import json
import os
import sys

root = sys.argv[1]
tasks_path = os.path.join(root, "codex-memory", "tasks.json")

with open(tasks_path, "r", encoding="utf-8") as handle:
    registry = json.load(handle)

task = next(entry for entry in registry["tasks"] if entry.get("id") == "task-saturation-recovery")
task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
task["task_intent"] = {
    **task_intent,
    "constraints": [],
    "success_signals": [],
    "affected_files": [],
}

with open(tasks_path, "w", encoding="utf-8") as handle:
    json.dump(registry, handle, indent=2)
    handle.write("\n")
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-legacy-saturation-repair-third.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-legacy-saturation-repair-third.json" "$TMP_DIR/strategy-legacy-saturation-first-state.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]
first_state_path = sys.argv[3]
expected_title = "Fix first-pass metrics path"

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(first_state_path, "r", encoding="utf-8") as handle:
    first_state = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

task = {entry["id"]: entry for entry in registry["tasks"]}["task-saturation-recovery"]

assert output["status"] == "success"
assert output["message"] == (
    "No new strategy updates for codex-agent-system; waiting on 1 pending approval task(s), including saturation recovery."
    " Verification: bash tests/system-smoke.sh."
)
assert output["data"]["board_updates"] == []
assert output["data"]["board_tasks"] == [
    {
        "id": "task-saturation-recovery",
        "action": "existing",
        "status": "pending_approval",
        "title": expected_title,
        "category": "learning",
        "source_task_id": "strategy::saturation-recovery",
        "updated_at": task["updated_at"],
        "verification_command": "bash tests/system-smoke.sh",
    }
]
assert task["updated_at"] == first_state["updated_at"]
assert task["provider_selection"]["updated_at"] == first_state["provider_selection_updated_at"]
assert task["task_shape"]["updated_at"] == first_state["task_shape_updated_at"]
assert task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert len(task["history"]) == first_state["history_length"]
assert task["task_intent"]["constraints"] == []
assert task["task_intent"]["success_signals"] == []
assert task["task_intent"]["affected_files"] == []
assert task["history"][-1]["action"] == "auto_repair"
PY

echo "strategy legacy saturation repair test passed"
