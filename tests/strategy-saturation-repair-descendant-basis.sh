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
      "title": "Replace Detect low first-pass success before repeated retries dominate the board with a different bounded experiment",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "pending_approval",
      "strategy_template": "strategy_saturation_rescue",
      "task_intent": {
        "source": "strategy_saturation",
        "objective": "Replace Detect low first-pass success before repeated retries dominate the board with a different bounded experiment",
        "project": "codex-agent-system",
        "category": "learning",
        "context_hint": "Replace saturated experiment: Detect low first-pass success before repeated retries dominate the board"
      },
      "task_shape": {
        "approval_ready": true,
        "requires_split": false,
        "reasons": [],
        "manual_review_required": false,
        "risk_profile": "standard",
        "risk_flags": [],
        "verification_command": "",
        "updated_at": "2026-03-24T19:41:01Z"
      },
      "saturation_recovery": {
        "kind": "replace_saturated_experiment",
        "replaces_task_id": "task-root-first-pass",
        "replaces_title": "Detect low first-pass success before repeated retries dominate the board",
        "replaces_strategy_template": "first_pass_success_guard",
        "replaces_category": "learning"
      },
      "created_at": "2026-03-24T19:41:00Z",
      "updated_at": "2026-03-24T19:41:01Z",
      "history": [
        {
          "at": "2026-03-24T19:41:00Z",
          "action": "create",
          "from_status": "",
          "to_status": "pending_approval",
          "project": "codex-agent-system",
          "queue_task": "Fix first-pass metrics path",
          "note": "Task was added from strategy saturation recovery after all enterprise templates hit the saturation guard."
        }
      ]
    },
    {
      "id": "task-root-first-pass",
      "title": "Detect low first-pass success before repeated retries dominate the board",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "failed",
      "strategy_template": "first_pass_success_guard",
      "source_task_id": "strategy::first-pass-success",
      "root_source_task_id": "strategy::first-pass-success",
      "original_failed_root_id": "strategy::first-pass-success",
      "created_at": "2026-03-24T18:40:00Z",
      "updated_at": "2026-03-24T18:40:46Z",
      "failed_at": "2026-03-24T18:40:46Z"
    },
    {
      "id": "task-child-first-pass",
      "title": "Align persisted first-pass success metrics",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "failed",
      "strategy_template": "bounded_failed_step_child",
      "source_task_id": "strategy::first-pass-success",
      "root_source_task_id": "strategy::first-pass-success",
      "original_failed_root_id": "strategy::first-pass-success",
      "failure_context": {
        "failed_step": "Run `bash tests/system-smoke.sh` as the single deterministic verification command and treat exit code `0` as success; if it fails, limit the follow-up fix strictly to the first-pass metrics path surfaced by that command."
      },
      "created_at": "2026-03-24T18:38:00Z",
      "updated_at": "2026-03-24T18:38:30Z",
      "failed_at": "2026-03-24T18:38:30Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-saturation-repair-descendant-basis.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-saturation-repair-descendant-basis.json" "$TMP_DIR/strategy-saturation-repair-descendant-basis.state.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]
state_path = sys.argv[3]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

task = next(entry for entry in registry["tasks"] if entry.get("id") == "task-saturation-recovery")

assert output["status"] == "success"
assert output["message"] == (
    "No new strategy updates for codex-agent-system; waiting on 1 pending approval task(s), including saturation recovery."
    " Verification: bash tests/system-smoke.sh."
)
assert output["data"]["board_tasks"] == [
    {
        "id": "task-saturation-recovery",
        "action": "existing",
        "status": "pending_approval",
        "title": "Fix first-pass metrics path",
        "category": "learning",
        "source_task_id": "strategy::saturation-recovery",
        "updated_at": task["updated_at"],
        "verification_command": "bash tests/system-smoke.sh",
    }
]
assert task["title"] == "Fix first-pass metrics path"
assert task["execution_task"] == "Fix first-pass metrics path"
assert task["task_intent"] == {
    "source": "strategy_saturation",
    "objective": "Fix first-pass metrics path",
    "project": "codex-agent-system",
    "category": "learning",
    "context_hint": "Replace saturated experiment: Align persisted first-pass success metrics",
    "constraints": [],
    "success_signals": [],
    "affected_files": [],
}
assert task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert task["history"][-1]["action"] == "auto_repair"
assert task["history"][-1]["queue_task"] == "Fix first-pass metrics path"

with open(state_path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "updated_at": task["updated_at"],
            "task_shape_updated_at": task["task_shape"]["updated_at"],
            "history_length": len(task["history"]),
        },
        handle,
    )
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-saturation-repair-descendant-basis-second.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-saturation-repair-descendant-basis-second.json" "$TMP_DIR/strategy-saturation-repair-descendant-basis.state.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]
state_path = sys.argv[3]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(state_path, "r", encoding="utf-8") as handle:
    first_state = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

task = next(entry for entry in registry["tasks"] if entry.get("id") == "task-saturation-recovery")

assert output["status"] == "success"
assert output["message"] == (
    "No new strategy updates for codex-agent-system; waiting on 1 pending approval task(s), including saturation recovery."
    " Verification: bash tests/system-smoke.sh."
)
assert task["title"] == "Fix first-pass metrics path"
assert task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert task["updated_at"] == first_state["updated_at"]
assert task["task_shape"]["updated_at"] == first_state["task_shape_updated_at"]
assert len(task["history"]) == first_state["history_length"]
PY

echo "strategy saturation repair descendant basis test passed"
