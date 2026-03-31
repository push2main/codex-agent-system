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
      "id": "task-060-dashboard-pressure-followup",
      "title": "Cut dashboard task-registry read amplification before growth stalls the loop",
      "impact": 8,
      "effort": 4,
      "confidence": 0.83,
      "category": "performance",
      "project": "codex-agent-system",
      "reason": "The dashboard read path still reparses too much shared state.",
      "score": 2.1,
      "status": "failed",
      "created_at": "2026-03-24T11:00:00Z",
      "updated_at": "2026-03-24T11:10:00Z",
      "failed_at": "2026-03-24T11:10:00Z",
      "execution_context": {
        "step_count": 4,
        "failed_step": "Inspect `codex-dashboard/server.js` and `scripts/lib.sh` together, confirm the exact first-pass success filter/rule/threshold already used in the dashboard path, then patch only the persisted metrics logic in `scripts/lib.sh` so `first_pass_success_count`, `multi_attempt_resolved_count`, `first_pass_success_rate`, and `low_first_pass_success_detected` use the same successful-completed-task filter, `attempt <= 1` rule, one explicit threshold, and a non-zero-sample guard without changing keys or storage format.",
        "updated_at": "2026-03-24T11:10:00Z"
      },
      "failure_context": {
        "failed_step_index": 2,
        "failed_step": "Inspect `codex-dashboard/server.js` and `scripts/lib.sh` together, confirm the exact first-pass success filter/rule/threshold already used in the dashboard path, then patch only the persisted metrics logic in `scripts/lib.sh` so `first_pass_success_count`, `multi_attempt_resolved_count`, `first_pass_success_rate`, and `low_first_pass_success_detected` use the same successful-completed-task filter, `attempt <= 1` rule, one explicit threshold, and a non-zero-sample guard without changing keys or storage format.",
        "updated_at": "2026-03-24T11:10:00Z"
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-output.json" >/dev/null
)

python3 - "$TEST_ROOT" <<'PY'
import json
import os
import sys

root = sys.argv[1]
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

child = next(task for task in registry["tasks"] if task.get("strategy_template") == "bounded_failed_step_child")
assert child["title"].startswith("patch only the persisted metrics logic in `scripts/lib.sh`")
assert child["experiment"].startswith("Execute only this bounded child step next: patch only the persisted metrics logic in `scripts/lib.sh`")
assert "Inspect `codex-dashboard/server.js` and `scripts/lib.sh` together" not in child["experiment"]
assert child["task_intent"]["affected_files"] == ["codex-dashboard/server.js", "scripts/lib.sh"]
PY

echo "strategy bounded child inspect action extraction test passed"
