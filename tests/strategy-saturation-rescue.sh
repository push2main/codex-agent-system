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
      "id": "task-ui-1",
      "title": "Tighten the mobile dashboard into an enterprise control surface",
      "project": "codex-agent-system",
      "category": "ui",
      "status": "failed",
      "strategy_template": "enterprise_mobile_console",
      "strategy_depth": 2,
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:05:00Z",
      "failed_at": "2026-03-23T08:05:00Z"
    },
    {
      "id": "task-ui-2",
      "title": "Tighten the mobile dashboard into an enterprise control surface",
      "project": "codex-agent-system",
      "category": "ui",
      "status": "failed",
      "strategy_template": "enterprise_mobile_console",
      "strategy_depth": 2,
      "created_at": "2026-03-23T08:10:00Z",
      "updated_at": "2026-03-23T08:15:00Z",
      "failed_at": "2026-03-23T08:15:00Z"
    },
    {
      "id": "task-live-1",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "strategy_template": "enterprise_live_work_observability",
      "strategy_depth": 1,
      "created_at": "2026-03-23T08:20:00Z",
      "updated_at": "2026-03-23T08:25:00Z",
      "failed_at": "2026-03-23T08:25:00Z"
    },
    {
      "id": "task-live-2",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "strategy_template": "enterprise_live_work_observability",
      "strategy_depth": 1,
      "created_at": "2026-03-23T08:30:00Z",
      "updated_at": "2026-03-23T08:35:00Z",
      "failed_at": "2026-03-23T08:35:00Z"
    },
    {
      "id": "task-audit-1",
      "title": "Surface security, audit, and governance readiness in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "strategy_template": "enterprise_audit_governance",
      "strategy_depth": 1,
      "created_at": "2026-03-23T08:40:00Z",
      "updated_at": "2026-03-23T08:45:00Z",
      "failed_at": "2026-03-23T08:45:00Z"
    },
    {
      "id": "task-audit-2",
      "title": "Surface security, audit, and governance readiness in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "strategy_template": "enterprise_audit_governance",
      "strategy_depth": 1,
      "created_at": "2026-03-23T08:50:00Z",
      "updated_at": "2026-03-23T08:55:00Z",
      "failed_at": "2026-03-23T08:55:00Z"
    },
    {
      "id": "task-learning-1",
      "title": "Feed execution learning back into future provider and task decisions",
      "project": "codex-agent-system",
      "category": "code_quality",
      "status": "failed",
      "strategy_template": "enterprise_learning_feedback",
      "strategy_depth": 1,
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:05:00Z",
      "failed_at": "2026-03-23T09:05:00Z"
    },
    {
      "id": "task-learning-2",
      "title": "Feed execution learning back into future provider and task decisions",
      "project": "codex-agent-system",
      "category": "code_quality",
      "status": "failed",
      "strategy_template": "enterprise_learning_feedback",
      "strategy_depth": 1,
      "created_at": "2026-03-23T09:10:00Z",
      "updated_at": "2026-03-23T09:15:00Z",
      "failed_at": "2026-03-23T09:15:00Z"
    },
    {
      "id": "task-timeout-1",
      "title": "Cut queue timeout churn before retries burn worker capacity",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "strategy_template": "enterprise_timeout_stability",
      "strategy_depth": 1,
      "created_at": "2026-03-23T09:20:00Z",
      "updated_at": "2026-03-23T09:25:00Z",
      "failed_at": "2026-03-23T09:25:00Z"
    },
    {
      "id": "task-timeout-2",
      "title": "Cut queue timeout churn before retries burn worker capacity",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "failed",
      "strategy_template": "enterprise_timeout_stability",
      "strategy_depth": 1,
      "created_at": "2026-03-23T09:30:00Z",
      "updated_at": "2026-03-23T09:35:00Z",
      "failed_at": "2026-03-23T09:35:00Z"
    },
    {
      "id": "task-pressure-1",
      "title": "Cut task-registry read amplification before growth stalls the loop",
      "project": "codex-agent-system",
      "category": "performance",
      "status": "failed",
      "strategy_template": "enterprise_registry_pressure_relief",
      "strategy_depth": 1,
      "created_at": "2026-03-23T09:40:00Z",
      "updated_at": "2026-03-23T09:45:00Z",
      "failed_at": "2026-03-23T09:45:00Z"
    },
    {
      "id": "task-pressure-2",
      "title": "Cut task-registry read amplification before growth stalls the loop",
      "project": "codex-agent-system",
      "category": "performance",
      "status": "failed",
      "strategy_template": "enterprise_registry_pressure_relief",
      "strategy_depth": 1,
      "created_at": "2026-03-23T09:50:00Z",
      "updated_at": "2026-03-23T09:55:00Z",
      "failed_at": "2026-03-23T09:55:00Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-saturation-rescue.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-saturation-rescue.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

assert output["status"] == "success"
assert output["message"] == "Applied 1 strategy board update(s) for codex-agent-system."
assert output["data"]["board_updates"] == [
    {
        "id": "task-001-replace-cut-task-registry-read-amplifica",
        "action": "created",
        "source_task_id": "strategy::saturation-recovery",
    }
]
assert output["data"]["board_tasks"] == [
    {
        "id": "task-001-replace-cut-task-registry-read-amplifica",
        "action": "created",
        "source_task_id": "strategy::saturation-recovery",
    }
]

created = {
    task["id"]: task
    for task in registry["tasks"]
    if task.get("strategy_template") == "strategy_saturation_rescue"
}
assert set(created) == {"task-001-replace-cut-task-registry-read-amplifica"}
task = created["task-001-replace-cut-task-registry-read-amplifica"]
assert task["status"] == "pending_approval"
assert task["title"] == "Replace Cut task-registry read amplification before growth stalls the loop with a different bounded experiment"
assert task["task_intent"]["source"] == "strategy_saturation"
assert task["task_intent"]["objective"] == task["title"]
assert task["task_intent"]["context_hint"] == "Replace saturated experiment: Cut task-registry read amplification before growth stalls the loop"
assert task["task_intent"]["constraints"] == []
assert task["task_intent"]["success_signals"] == []
assert task["task_intent"]["affected_files"] == []
assert "latest saturated failure" in task["reason"].lower()
assert "enterprise_registry_pressure_relief" in task["reason"]
assert task["execution_provider"] == "codex"
assert task["provider_selection"]["selected"] == "codex"
assert task["provider_selection"]["source"] == "strategy_default"
assert task["saturation_recovery"] == {
    "kind": "replace_saturated_experiment",
    "replaces_task_id": "task-pressure-2",
    "replaces_title": "Cut task-registry read amplification before growth stalls the loop",
    "replaces_strategy_template": "enterprise_registry_pressure_relief",
    "replaces_category": "performance",
}
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-saturation-rescue-second.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-saturation-rescue-second.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

existing = next(
    task for task in registry["tasks"]
    if task.get("strategy_template") == "strategy_saturation_rescue"
)

assert output["status"] == "success"
assert output["message"] == (
    "No new strategy updates for codex-agent-system; waiting on 1 pending approval task(s), including saturation recovery."
)
assert output["data"]["board_updates"] == []
assert output["data"]["board_tasks"] == [
    {
        "id": "task-001-replace-cut-task-registry-read-amplifica",
        "action": "existing",
        "status": "pending_approval",
        "title": "Replace Cut task-registry read amplification before growth stalls the loop with a different bounded experiment",
        "category": "learning",
        "source_task_id": "strategy::saturation-recovery",
        "updated_at": existing["updated_at"],
    }
]
assert len([
    task for task in registry["tasks"]
    if task.get("strategy_template") == "strategy_saturation_rescue"
]) == 1
assert existing["task_intent"]["objective"] == "Replace Cut task-registry read amplification before growth stalls the loop with a different bounded experiment"
assert existing["task_intent"]["context_hint"] == "Replace saturated experiment: Cut task-registry read amplification before growth stalls the loop"
assert existing["task_intent"]["constraints"] == []
assert existing["task_intent"]["success_signals"] == []
assert existing["task_intent"]["affected_files"] == []
assert existing["history"][-1]["action"] == "create"
PY

echo "strategy saturation rescue test passed"
