#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT_REPAIR="$TMP_DIR/repair-repo"
TEST_ROOT_THRESHOLD="$TMP_DIR/threshold-repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

setup_repo() {
  local target="$1"
  mkdir -p "$target"
  cp -R "$ROOT_DIR/scripts" "$target/scripts"
  cp -R "$ROOT_DIR/agents" "$target/agents"
  mkdir -p "$target/codex-memory" "$target/codex-learning" "$target/codex-logs" "$target/projects" "$target/queues"
  cat >"$target/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
  : >"$target/codex-memory/tasks.log"
}

write_saturated_registry() {
  local path="$1"
  local extra_json="$2"
  python3 - "$path" "$extra_json" <<'PY'
import json
import sys

path = sys.argv[1]
extra_json = sys.argv[2]
tasks = []
families = [
    ("enterprise_mobile_console", "Tighten the mobile dashboard into an enterprise control surface", "ui"),
    ("enterprise_live_work_observability", "Make active worker ownership and progress explicit in the dashboard", "stability"),
    ("enterprise_audit_governance", "Surface security, audit, and governance readiness in the dashboard", "stability"),
    ("enterprise_learning_feedback", "Feed execution learning back into future provider and task decisions", "code_quality"),
    ("enterprise_timeout_stability", "Cut queue timeout churn before retries burn worker capacity", "stability"),
    ("enterprise_registry_pressure_relief", "Cut dashboard task-registry read amplification before growth stalls the loop", "performance"),
]

for family_index, (template, title, category) in enumerate(families, start=1):
    for attempt in range(2):
        hour = 8 + family_index
        minute = 10 * attempt
        timestamp = f"2026-03-23T{hour:02d}:{minute:02d}:00Z"
        tasks.append(
            {
                "id": f"task-{template}-{attempt + 1}",
                "title": title,
                "project": "codex-agent-system",
                "category": category,
                "status": "failed",
                "strategy_template": template,
                "strategy_depth": 2,
                "created_at": timestamp,
                "updated_at": timestamp,
                "failed_at": timestamp,
            }
        )

tasks.extend(json.loads(extra_json))

with open(path, "w", encoding="utf-8") as handle:
    json.dump({"tasks": tasks}, handle, indent=2)
    handle.write("\n")
PY
}

setup_repo "$TEST_ROOT_REPAIR"
write_saturated_registry "$TEST_ROOT_REPAIR/codex-memory/tasks.json" '[
  {
    "id": "task-failed-saturation-rescue",
    "title": "Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment",
    "project": "codex-agent-system",
    "category": "learning",
    "status": "failed",
    "strategy_template": "strategy_saturation_rescue",
    "source_task_id": "strategy::saturation-recovery",
    "root_source_task_id": "strategy::saturation-recovery",
    "original_failed_root_id": "strategy::saturation-recovery",
    "saturation_recovery": {
      "kind": "replace_saturated_experiment",
      "replaces_task_id": "task-enterprise_registry_pressure_relief-2",
      "replaces_title": "Cut dashboard task-registry read amplification before growth stalls the loop",
      "replaces_strategy_template": "enterprise_registry_pressure_relief",
      "replaces_category": "performance"
    },
    "created_at": "2026-03-23T20:00:00Z",
    "updated_at": "2026-03-23T20:10:00Z",
    "failed_at": "2026-03-23T20:10:00Z"
  },
  {
    "id": "task-pending-nested-saturation-rescue",
    "title": "Replace Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment with a different bounded experiment",
    "project": "codex-agent-system",
    "category": "learning",
    "status": "pending_approval",
    "strategy_template": "strategy_saturation_rescue",
    "source_task_id": "strategy::saturation-recovery",
    "root_source_task_id": "strategy::saturation-recovery",
    "original_failed_root_id": "strategy::saturation-recovery",
    "task_intent": {
      "source": "strategy_saturation",
      "objective": "Replace Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment with a different bounded experiment",
      "project": "codex-agent-system",
      "category": "learning",
      "context_hint": "Replace saturated experiment: Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment"
    },
    "saturation_recovery": {
      "kind": "replace_saturated_experiment",
      "replaces_task_id": "task-failed-saturation-rescue",
      "replaces_title": "Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment",
      "replaces_strategy_template": "strategy_saturation_rescue",
      "replaces_category": "learning"
    },
    "created_at": "2026-03-23T20:20:00Z",
    "updated_at": "2026-03-23T20:20:00Z",
    "history": [
      {
        "at": "2026-03-23T20:20:00Z",
        "action": "create",
        "from_status": "",
        "to_status": "pending_approval",
        "project": "codex-agent-system",
        "queue_task": "Replace Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment with a different bounded experiment",
        "note": "Nested saturation recovery fixture."
      }
    ]
  }
]'

(
  cd "$TEST_ROOT_REPAIR"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-saturation-repair.json" >/dev/null
)

python3 - "$TEST_ROOT_REPAIR" "$TMP_DIR/strategy-saturation-repair.json" <<'PY'
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
assert output["data"]["board_updates"] == []

pending = next(
    task for task in registry["tasks"]
    if task.get("id") == "task-pending-nested-saturation-rescue"
)

expected_title = "Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment"
assert pending["title"] == expected_title
assert pending["task_intent"]["objective"] == expected_title
assert pending["task_intent"]["context_hint"] == "Replace saturated experiment: Cut dashboard task-registry read amplification before growth stalls the loop"
assert pending["saturation_recovery"] == {
    "kind": "replace_saturated_experiment",
    "replaces_task_id": "task-enterprise_registry_pressure_relief-2",
    "replaces_title": "Cut dashboard task-registry read amplification before growth stalls the loop",
    "replaces_strategy_template": "enterprise_registry_pressure_relief",
    "replaces_category": "performance",
}
assert pending["history"][-1]["action"] == "auto_repair"
assert len(
    [task for task in registry["tasks"] if task.get("strategy_template") == "strategy_saturation_rescue"]
) == 2
PY

setup_repo "$TEST_ROOT_THRESHOLD"
write_saturated_registry "$TEST_ROOT_THRESHOLD/codex-memory/tasks.json" '[
  {
    "id": "task-failed-saturation-rescue-1",
    "title": "Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment",
    "project": "codex-agent-system",
    "category": "learning",
    "status": "failed",
    "strategy_template": "strategy_saturation_rescue",
    "source_task_id": "strategy::saturation-recovery",
    "root_source_task_id": "strategy::saturation-recovery",
    "original_failed_root_id": "strategy::saturation-recovery",
    "saturation_recovery": {
      "kind": "replace_saturated_experiment",
      "replaces_task_id": "task-enterprise_registry_pressure_relief-2",
      "replaces_title": "Cut dashboard task-registry read amplification before growth stalls the loop",
      "replaces_strategy_template": "enterprise_registry_pressure_relief",
      "replaces_category": "performance"
    },
    "created_at": "2026-03-23T20:00:00Z",
    "updated_at": "2026-03-23T20:10:00Z",
    "failed_at": "2026-03-23T20:10:00Z"
  },
  {
    "id": "task-failed-saturation-rescue-2",
    "title": "Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment",
    "project": "codex-agent-system",
    "category": "learning",
    "status": "failed",
    "strategy_template": "strategy_saturation_rescue",
    "source_task_id": "strategy::saturation-recovery",
    "root_source_task_id": "strategy::saturation-recovery",
    "original_failed_root_id": "strategy::saturation-recovery",
    "saturation_recovery": {
      "kind": "replace_saturated_experiment",
      "replaces_task_id": "task-enterprise_registry_pressure_relief-2",
      "replaces_title": "Cut dashboard task-registry read amplification before growth stalls the loop",
      "replaces_strategy_template": "enterprise_registry_pressure_relief",
      "replaces_category": "performance"
    },
    "created_at": "2026-03-23T20:20:00Z",
    "updated_at": "2026-03-23T20:30:00Z",
    "failed_at": "2026-03-23T20:30:00Z"
  }
]'

(
  cd "$TEST_ROOT_THRESHOLD"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-saturation-threshold.json" >/dev/null
)

python3 - "$TEST_ROOT_THRESHOLD" "$TMP_DIR/strategy-saturation-threshold.json" <<'PY'
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

rescue_tasks = [task for task in registry["tasks"] if task.get("strategy_template") == "strategy_saturation_rescue"]
assert len(rescue_tasks) == 2
assert not any(
    update.get("source_task_id") == "strategy::saturation-recovery"
    and str(update.get("id") or "").strip().startswith("task-00")
    and "replace" in str(update.get("id") or "").lower()
    for update in output["data"]["board_updates"]
)
assert not any("Replace Replace" in str(task.get("title") or "") for task in rescue_tasks)
assert not any(task.get("status") == "pending_approval" for task in rescue_tasks)
PY

echo "strategy saturation rescue nesting guard test passed"
