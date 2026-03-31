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
mkdir -p "$TEST_ROOT/projects/superheld"

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "learning": { "weight": 1.2, "success_rate": 0.79 }
  }
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-020-add-canonical-incident-example",
      "title": "[self-improve:high] Add canonical incident example for credential recovery required",
      "impact": 7,
      "effort": 4,
      "confidence": 0.82,
      "category": "stability",
      "project": "superheld",
      "reason": "The incident schema still lacks one product-facing example.",
      "score": 2.4,
      "status": "failed",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:10:00Z",
      "failure_context": {
        "failed_step_index": 1,
        "failed_step": "Inspect `packages/schema/incident.schema.json` and confirm the root `examples` array shape before adding the canonical `credential_recovery_required` example object after the existing incident examples.",
        "updated_at": "2026-03-24T08:10:00Z"
      }
    },
    {
      "id": "task-021-step-1-incident-schema-followup",
      "title": "Step 1: In packages/schema/incident.schema.json, inspect the root examples array and the existing incident example objects to confirm the field names",
      "impact": 6,
      "effort": 2,
      "confidence": 0.86,
      "category": "learning",
      "project": "superheld",
      "reason": "Task task-020-add-canonical-incident-example failed while still spanning too much scope.",
      "hypothesis": "placeholder",
      "experiment": "Execute only this bounded child step next: Step 1: In `packages/schema/incident.schema.json`, inspect the root `examples` array and the existing incident example objects to confirm the field names. Do not implement later plan steps from the parent task in the same run.",
      "success_criteria": [
        "placeholder"
      ],
      "rollback": "placeholder",
      "source_task_id": "task-020-add-canonical-incident-example",
      "root_source_task_id": "task-020-add-canonical-incident-example",
      "original_failed_root_id": "task-020-add-canonical-incident-example",
      "strategy_template": "bounded_failed_step_child",
      "status": "pending_approval",
      "created_at": "2026-03-24T08:10:30Z",
      "updated_at": "2026-03-24T08:11:00Z",
      "task_intent": {
        "source": "strategy_followup",
        "objective": "Step 1: In packages/schema/incident.schema.json, inspect the root examples array and the existing incident example objects to confirm the field names",
        "project": "superheld",
        "category": "learning",
        "context_hint": "[self-improve:high] Add canonical incident example for credential recovery required",
        "constraints": [],
        "success_signals": [],
        "affected_files": []
      },
      "history": []
    }
  ]
}
EOF

cat >"$TEST_ROOT/projects/superheld/project.json" <<'EOF'
{
  "project": "superheld",
  "workspace": "/tmp/superheld-fixture"
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh superheld "$TMP_DIR/strategy-output.json" >/dev/null
)

python3 - "$TEST_ROOT" <<'PY'
import json
import os
import sys

root = sys.argv[1]
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

task = next(item for item in registry["tasks"] if item.get("id") == "task-021-step-1-incident-schema-followup")
assert task["task_intent"]["affected_files"] == ["packages/schema/incident.schema.json"]
assert task["target_files"] == ["packages/schema/incident.schema.json"]
assert task["history"][-1]["action"] == "auto_repair"
assert "parent failed-step file hints" in task["history"][-1]["note"]
PY

echo "strategy bounded child file hint repair test passed"
