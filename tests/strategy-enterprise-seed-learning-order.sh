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
      "id": "task-failed-enterprise-seed",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.83,
      "status": "failed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:10:00Z",
      "failed_at": "2026-03-23T08:10:00Z",
      "strategy_template": "enterprise_live_work_observability",
      "strategy_depth": 1,
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Make active worker ownership and progress explicit in the dashboard",
        "project": "codex-agent-system",
        "category": "stability"
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-seed-order.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-seed-order.json" <<'PY'
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
assert output["data"]["board_tasks"] == [
    {
        "id": "task-001-tighten-the-mobile-dashboard-into-an-ent",
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
    {
        "id": "task-002-feed-execution-learning-back-into-future",
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
]

created = {task["id"]: task for task in registry["tasks"] if task["id"].startswith("task-00")}
assert created["task-001-tighten-the-mobile-dashboard-into-an-ent"]["title"] == "Tighten the mobile dashboard into an enterprise control surface"
assert created["task-001-tighten-the-mobile-dashboard-into-an-ent"]["strategy_template"] == "enterprise_mobile_console"
assert created["task-001-tighten-the-mobile-dashboard-into-an-ent"]["status"] == "pending_approval"
assert created["task-002-feed-execution-learning-back-into-future"]["title"] == "Feed execution learning back into future provider and task decisions"
assert created["task-002-feed-execution-learning-back-into-future"]["strategy_template"] == "enterprise_learning_feedback"
assert created["task-002-feed-execution-learning-back-into-future"]["status"] == "pending_approval"
assert all(task["strategy_template"] != "enterprise_live_work_observability" for task in created.values())
PY

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-failed-live-work-1",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.83,
      "status": "failed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:10:00Z",
      "failed_at": "2026-03-23T08:10:00Z",
      "strategy_template": "enterprise_live_work_observability",
      "strategy_depth": 1,
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system"
    },
    {
      "id": "task-failed-live-work-2",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.83,
      "status": "failed",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:10:00Z",
      "failed_at": "2026-03-23T09:10:00Z",
      "strategy_template": "enterprise_live_work_observability",
      "strategy_depth": 1,
      "root_source_task_id": "enterprise-readiness::codex-agent-system",
      "original_failed_root_id": "enterprise-readiness::codex-agent-system"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-seed-saturation.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-seed-saturation.json" <<'PY'
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
created = [task for task in registry["tasks"] if task["id"].startswith("task-00")]
assert len(created) == 2
assert {task["strategy_template"] for task in created} == {
    "enterprise_mobile_console",
    "enterprise_learning_feedback",
}
assert all(task["strategy_template"] != "enterprise_live_work_observability" for task in created)
PY

TEST_ROOT_CATEGORY="$TMP_DIR/category-repo"
mkdir -p "$TEST_ROOT_CATEGORY"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT_CATEGORY/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT_CATEGORY/agents"
mkdir -p "$TEST_ROOT_CATEGORY/codex-memory" "$TEST_ROOT_CATEGORY/codex-learning" "$TEST_ROOT_CATEGORY/codex-logs" "$TEST_ROOT_CATEGORY/projects" "$TEST_ROOT_CATEGORY/queues"
cat >"$TEST_ROOT_CATEGORY/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
: >"$TEST_ROOT_CATEGORY/codex-memory/tasks.log"

cat >"$TEST_ROOT_CATEGORY/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-ui-failed",
      "title": "Refine the mobile dashboard cards",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 7,
      "effort": 3,
      "confidence": 0.8,
      "status": "failed",
      "strategy_depth": 2,
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:10:00Z",
      "failed_at": "2026-03-23T08:10:00Z"
    },
    {
      "id": "task-stability-completed",
      "title": "Keep queue approvals deterministic",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "status": "completed",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:05:00Z",
      "completed_at": "2026-03-23T09:05:00Z"
    },
    {
      "id": "task-stability-failed",
      "title": "Tighten queue worker recovery",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "status": "failed",
      "strategy_depth": 1,
      "created_at": "2026-03-23T09:10:00Z",
      "updated_at": "2026-03-23T09:15:00Z",
      "failed_at": "2026-03-23T09:15:00Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT_CATEGORY"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-seed-category-learning.json" >/dev/null
)

python3 - "$TEST_ROOT_CATEGORY" "$TMP_DIR/strategy-seed-category-learning.json" <<'PY'
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
assert output["data"]["board_tasks"] == [
    {
        "id": "task-001-make-active-worker-ownership-and-progres",
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
    {
        "id": "task-002-surface-security-audit-and-governance-re",
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
]

created = {task["id"]: task for task in registry["tasks"] if task["id"].startswith("task-00")}
assert {task["strategy_template"] for task in created.values()} == {
    "enterprise_live_work_observability",
    "enterprise_audit_governance",
}
assert all(task["strategy_template"] != "enterprise_mobile_console" for task in created.values())
PY

echo "strategy enterprise seed learning order test passed"

TEST_ROOT_LOOP="$TMP_DIR/loop-effort-repo"
mkdir -p "$TEST_ROOT_LOOP"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT_LOOP/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT_LOOP/agents"
mkdir -p "$TEST_ROOT_LOOP/codex-memory" "$TEST_ROOT_LOOP/codex-learning" "$TEST_ROOT_LOOP/codex-logs" "$TEST_ROOT_LOOP/projects" "$TEST_ROOT_LOOP/queues"
cat >"$TEST_ROOT_LOOP/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.8 },
    "ui": { "weight": 1.35, "success_rate": 0.8 },
    "performance": { "weight": 1.1, "success_rate": 0.8 },
    "code_quality": { "weight": 1.05, "success_rate": 0.8 }
  }
}
EOF
cat >"$TEST_ROOT_LOOP/codex-learning/metrics.json" <<'EOF'
{
  "loop_effort_detected": true,
  "loop_effort_task_count": 2,
  "loop_effort_extra_step_attempts": 4
}
EOF
: >"$TEST_ROOT_LOOP/codex-memory/tasks.log"

cat >"$TEST_ROOT_LOOP/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-ui-heavy",
      "title": "Refine dashboard card density",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 7,
      "effort": 3,
      "confidence": 0.8,
      "status": "completed",
      "strategy_depth": 2,
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:10:00Z",
      "completed_at": "2026-03-23T09:10:00Z",
      "execution": {
        "attempt": 2,
        "total_step_attempts": 6
      }
    },
    {
      "id": "task-code-quality-light",
      "title": "Persist provider feedback after failed execution",
      "project": "codex-agent-system",
      "category": "code_quality",
      "impact": 7,
      "effort": 3,
      "confidence": 0.8,
      "status": "completed",
      "strategy_depth": 2,
      "created_at": "2026-03-23T09:20:00Z",
      "updated_at": "2026-03-23T09:25:00Z",
      "completed_at": "2026-03-23T09:25:00Z",
      "execution": {
        "attempt": 2,
        "total_step_attempts": 2
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT_LOOP"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-seed-loop-effort.json" >/dev/null
)

python3 - "$TEST_ROOT_LOOP" "$TMP_DIR/strategy-seed-loop-effort.json" <<'PY'
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
assert output["data"]["board_tasks"] == [
    {
        "id": "task-001-feed-execution-learning-back-into-future",
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
    {
        "id": "task-002-tighten-the-mobile-dashboard-into-an-ent",
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
]

created = {task["id"]: task for task in registry["tasks"] if task["id"].startswith("task-00")}
assert created["task-001-feed-execution-learning-back-into-future"]["strategy_template"] == "enterprise_learning_feedback"
assert created["task-002-tighten-the-mobile-dashboard-into-an-ent"]["strategy_template"] == "enterprise_mobile_console"
assert all(task["strategy_template"] != "enterprise_live_work_observability" for task in created.values())
PY

echo "strategy enterprise loop effort ordering test passed"
