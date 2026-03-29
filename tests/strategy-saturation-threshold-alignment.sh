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
    "code_quality": { "weight": 1.05, "success_rate": 0.79 },
    "learning": { "weight": 1.2, "success_rate": 0.75 }
  }
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-timeout-seed-oldest",
      "title": "Cut queue timeout churn before retries burn worker capacity",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 9,
      "effort": 2,
      "confidence": 0.84,
      "score": 7.56,
      "status": "failed",
      "strategy_template": "enterprise_timeout_stability",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "created_at": "2026-03-24T20:00:00Z",
      "updated_at": "2026-03-24T20:05:00Z",
      "failed_at": "2026-03-24T20:05:00Z"
    },
    {
      "id": "task-002-timeout-seed-latest",
      "title": "Cut queue timeout churn before retries burn worker capacity",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 9,
      "effort": 2,
      "confidence": 0.84,
      "score": 7.56,
      "status": "failed",
      "strategy_template": "enterprise_timeout_stability",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "created_at": "2026-03-24T20:10:00Z",
      "updated_at": "2026-03-24T20:15:00Z",
      "failed_at": "2026-03-24T20:15:00Z"
    },
    {
      "id": "task-003-mobile-console-completed",
      "title": "Tighten the mobile dashboard into an enterprise control surface",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "score": 3.69,
      "status": "completed",
      "strategy_template": "enterprise_mobile_console",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "created_at": "2026-03-24T19:00:00Z",
      "updated_at": "2026-03-24T19:30:00Z",
      "completed_at": "2026-03-24T19:30:00Z"
    },
    {
      "id": "task-004-live-work-completed",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.83,
      "score": 4.98,
      "status": "completed",
      "strategy_template": "enterprise_live_work_observability",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "created_at": "2026-03-24T19:35:00Z",
      "updated_at": "2026-03-24T19:50:00Z",
      "completed_at": "2026-03-24T19:50:00Z"
    },
    {
      "id": "task-005-audit-completed",
      "title": "Surface security, audit, and governance readiness in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 9,
      "effort": 3,
      "confidence": 0.84,
      "score": 5.04,
      "status": "completed",
      "strategy_template": "enterprise_audit_governance",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "created_at": "2026-03-24T19:55:00Z",
      "updated_at": "2026-03-24T20:05:00Z",
      "completed_at": "2026-03-24T20:05:00Z"
    },
    {
      "id": "task-006-learning-completed",
      "title": "Feed execution learning back into future provider and task decisions",
      "project": "codex-agent-system",
      "category": "code_quality",
      "impact": 9,
      "effort": 3,
      "confidence": 0.81,
      "score": 2.43,
      "status": "completed",
      "strategy_template": "enterprise_learning_feedback",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "created_at": "2026-03-24T18:50:00Z",
      "updated_at": "2026-03-24T19:05:00Z",
      "completed_at": "2026-03-24T19:05:00Z"
    },
    {
      "id": "task-007-registry-completed",
      "title": "Cut task-registry read amplification before growth stalls the loop",
      "project": "codex-agent-system",
      "category": "performance",
      "impact": 8,
      "effort": 2,
      "confidence": 0.83,
      "score": 3.32,
      "status": "completed",
      "strategy_template": "enterprise_registry_pressure_relief",
      "source_task_id": "enterprise-readiness::codex-agent-system",
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "created_at": "2026-03-24T18:10:00Z",
      "updated_at": "2026-03-24T18:30:00Z",
      "completed_at": "2026-03-24T18:30:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.22,
  "timeout_failure_rate": 0.14,
  "timeout_failure_records": 3
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-saturation-threshold.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-saturation-threshold.json" <<'PY'
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

tasks = registry["tasks"]
assert sum(1 for task in tasks if task.get("strategy_template") == "enterprise_timeout_stability") == 2
assert not any(
    task.get("strategy_template") == "enterprise_timeout_stability"
    and task.get("status") == "pending_approval"
    for task in tasks
)
PY

echo "strategy saturation threshold alignment test passed"
