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

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys

path = sys.argv[1]
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

tasks.extend(
    [
        {
            "id": "task-validation-complete",
            "title": "Verify Cut dashboard task-registry read amplification before growth stalls the loop with `bash tests/system-smoke.sh`",
            "project": "codex-agent-system",
            "category": "learning",
            "status": "completed",
            "strategy_template": "strategy_saturation_rescue",
            "source_task_id": "strategy::saturation-recovery",
            "root_source_task_id": "strategy::saturation-recovery",
            "original_failed_root_id": "strategy::saturation-recovery",
            "task_intent": {
                "source": "strategy_saturation",
                "objective": "Verify Cut dashboard task-registry read amplification before growth stalls the loop with `bash tests/system-smoke.sh`",
                "project": "codex-agent-system",
                "category": "learning",
                "context_hint": "Replace saturated experiment: Cut dashboard task-registry read amplification before growth stalls the loop",
                "constraints": [],
                "success_signals": [],
                "affected_files": []
            },
            "task_shape": {
                "verification_command": "bash tests/system-smoke.sh"
            },
            "saturation_recovery": {
                "kind": "replace_saturated_experiment",
                "replaces_task_id": "task-enterprise_registry_pressure_relief-2",
                "replaces_title": "Cut dashboard task-registry read amplification before growth stalls the loop",
                "replaces_strategy_template": "enterprise_registry_pressure_relief",
                "replaces_category": "performance"
            },
            "created_at": "2026-03-23T21:20:00Z",
            "updated_at": "2026-03-23T21:30:00Z",
            "completed_at": "2026-03-23T21:30:00Z"
        }
    ]
)

with open(path, "w", encoding="utf-8") as handle:
    json.dump({"tasks": tasks}, handle, indent=2)
    handle.write("\n")
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-output.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-output.json" <<'PY'
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

created = [
    task
    for task in registry["tasks"]
    if task.get("strategy_template") == "strategy_saturation_rescue"
    and task.get("id") != "task-validation-complete"
]
assert len(created) == 1

task = created[0]
assert task["status"] == "pending_approval"
assert task["title"] == "Replace Cut dashboard task-registry read amplification before growth stalls the loop with a different bounded experiment"
assert task["saturation_recovery"] == {
    "kind": "replace_saturated_experiment",
    "replaces_task_id": "task-enterprise_registry_pressure_relief-2",
    "replaces_title": "Cut dashboard task-registry read amplification before growth stalls the loop",
    "replaces_strategy_template": "enterprise_registry_pressure_relief",
    "replaces_category": "performance",
}
assert any(
    update.get("id") == task["id"]
    and update.get("action") == "created"
    and update.get("source_task_id") == "strategy::saturation-recovery"
    for update in output["data"]["board_updates"]
)
PY

echo "strategy saturation rescue validation completion guard test passed"
