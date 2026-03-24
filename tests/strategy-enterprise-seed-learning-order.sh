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

TEST_ROOT_SATURATION="$TMP_DIR/saturation-repo"
mkdir -p "$TEST_ROOT_SATURATION"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT_SATURATION/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT_SATURATION/agents"
mkdir -p "$TEST_ROOT_SATURATION/codex-memory" "$TEST_ROOT_SATURATION/codex-learning" "$TEST_ROOT_SATURATION/codex-logs" "$TEST_ROOT_SATURATION/projects" "$TEST_ROOT_SATURATION/queues"
cat >"$TEST_ROOT_SATURATION/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
: >"$TEST_ROOT_SATURATION/codex-memory/tasks.log"

cat >"$TEST_ROOT_SATURATION/codex-memory/tasks.json" <<'EOF'
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
  cd "$TEST_ROOT_SATURATION"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-seed-saturation.json" >/dev/null
)

python3 - "$TEST_ROOT_SATURATION" "$TMP_DIR/strategy-seed-saturation.json" <<'PY'
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

TEST_ROOT_LOOP_PRIORITY="$TMP_DIR/loop-effort-priority-repo"
mkdir -p "$TEST_ROOT_LOOP_PRIORITY"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT_LOOP_PRIORITY/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT_LOOP_PRIORITY/agents"
mkdir -p "$TEST_ROOT_LOOP_PRIORITY/codex-memory" "$TEST_ROOT_LOOP_PRIORITY/codex-learning" "$TEST_ROOT_LOOP_PRIORITY/codex-logs" "$TEST_ROOT_LOOP_PRIORITY/projects" "$TEST_ROOT_LOOP_PRIORITY/queues"
cat >"$TEST_ROOT_LOOP_PRIORITY/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
cat >"$TEST_ROOT_LOOP_PRIORITY/codex-learning/metrics.json" <<'EOF'
{
  "loop_effort_detected": true,
  "loop_effort_task_count": 4,
  "loop_effort_extra_step_attempts": 5
}
EOF
: >"$TEST_ROOT_LOOP_PRIORITY/codex-memory/tasks.log"

cat >"$TEST_ROOT_LOOP_PRIORITY/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-pending-1",
      "title": "Existing pending fixture one",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "pending_approval",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:00:00Z"
    },
    {
      "id": "task-pending-2",
      "title": "Existing pending fixture two",
      "project": "codex-agent-system",
      "category": "stability",
      "status": "pending_approval",
      "created_at": "2026-03-23T08:05:00Z",
      "updated_at": "2026-03-23T08:05:00Z"
    },
    {
      "id": "task-stability-completed-1",
      "title": "Keep queue approvals deterministic",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "status": "completed",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:05:00Z",
      "completed_at": "2026-03-23T09:05:00Z",
      "execution_context": {
        "attempts": 1,
        "total_step_attempts": 5
      }
    },
    {
      "id": "task-stability-completed-2",
      "title": "Keep task queue reconciliation deterministic",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "status": "completed",
      "created_at": "2026-03-23T09:10:00Z",
      "updated_at": "2026-03-23T09:15:00Z",
      "completed_at": "2026-03-23T09:15:00Z",
      "execution_context": {
        "attempts": 1,
        "total_step_attempts": 4
      }
    },
    {
      "id": "task-ui-completed",
      "title": "Refine mobile dashboard density",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 7,
      "effort": 3,
      "confidence": 0.8,
      "status": "completed",
      "created_at": "2026-03-23T09:20:00Z",
      "updated_at": "2026-03-23T09:25:00Z",
      "completed_at": "2026-03-23T09:25:00Z",
      "execution_context": {
        "attempts": 1,
        "total_step_attempts": 1
      }
    },
    {
      "id": "task-ui-failed",
      "title": "Adjust mobile spacing",
      "project": "codex-agent-system",
      "category": "ui",
      "impact": 7,
      "effort": 3,
      "confidence": 0.8,
      "status": "failed",
      "created_at": "2026-03-23T09:30:00Z",
      "updated_at": "2026-03-23T09:35:00Z",
      "failed_at": "2026-03-23T09:35:00Z",
      "failure_context": {
        "attempts": 1,
        "total_step_attempts": 1
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT_LOOP_PRIORITY"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-seed-loop-effort-priority.json" >/dev/null
)

python3 - "$TEST_ROOT_LOOP_PRIORITY" "$TMP_DIR/strategy-seed-loop-effort-priority.json" <<'PY'
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
        "id": "task-pending-1",
        "action": "existing",
        "status": "pending_approval",
        "title": "Existing pending fixture one",
        "category": "stability",
        "source_task_id": "task-pending-1",
        "updated_at": "2026-03-23T08:00:00Z",
    },
    {
        "id": "task-pending-2",
        "action": "existing",
        "status": "pending_approval",
        "title": "Existing pending fixture two",
        "category": "stability",
        "source_task_id": "task-pending-2",
        "updated_at": "2026-03-23T08:05:00Z",
    }
]

created = {task["id"]: task for task in registry["tasks"] if task["id"].startswith("task-00")}
assert created == {}
PY

echo "strategy enterprise loop effort priority test passed"

TEST_ROOT_REGISTRY_PRESSURE="$TMP_DIR/registry-pressure-repo"
mkdir -p "$TEST_ROOT_REGISTRY_PRESSURE"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT_REGISTRY_PRESSURE/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT_REGISTRY_PRESSURE/agents"
mkdir -p "$TEST_ROOT_REGISTRY_PRESSURE/codex-memory" "$TEST_ROOT_REGISTRY_PRESSURE/codex-learning" "$TEST_ROOT_REGISTRY_PRESSURE/codex-logs" "$TEST_ROOT_REGISTRY_PRESSURE/projects" "$TEST_ROOT_REGISTRY_PRESSURE/queues"
cat >"$TEST_ROOT_REGISTRY_PRESSURE/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
cat >"$TEST_ROOT_REGISTRY_PRESSURE/codex-learning/metrics.json" <<'EOF'
{
  "task_registry_payload_bytes": 640000,
  "task_registry_pressure_detected": true
}
EOF
: >"$TEST_ROOT_REGISTRY_PRESSURE/codex-memory/tasks.log"

cat >"$TEST_ROOT_REGISTRY_PRESSURE/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

(
  cd "$TEST_ROOT_REGISTRY_PRESSURE"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-seed-registry-pressure.json" >/dev/null
)

python3 - "$TEST_ROOT_REGISTRY_PRESSURE" "$TMP_DIR/strategy-seed-registry-pressure.json" <<'PY'
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
assert [task["strategy_template"] for task in created] == [
    "enterprise_registry_pressure_relief",
    "enterprise_mobile_console",
]

pressure_task = created[0]
mobile_task = created[1]
assert pressure_task["title"] == "Cut dashboard task-registry read amplification before growth stalls the loop"
assert pressure_task["task_intent"]["context_hint"] == "Task-registry pressure on dashboard read path"
assert pressure_task["task_registry_pressure_learning"] == {
    "detected": True,
    "payload_bytes": 640000,
    "primary_surface": "dashboard_read_path",
}
assert output["data"]["board_tasks"] == [
    {
        "id": pressure_task["id"],
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
    {
        "id": mobile_task["id"],
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
]
PY

echo "strategy enterprise registry pressure ordering test passed"

TEST_ROOT_TIMEOUT_PRESSURE="$TMP_DIR/timeout-pressure-repo"
mkdir -p "$TEST_ROOT_TIMEOUT_PRESSURE"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT_TIMEOUT_PRESSURE/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT_TIMEOUT_PRESSURE/agents"
mkdir -p "$TEST_ROOT_TIMEOUT_PRESSURE/codex-memory" "$TEST_ROOT_TIMEOUT_PRESSURE/codex-learning" "$TEST_ROOT_TIMEOUT_PRESSURE/codex-logs" "$TEST_ROOT_TIMEOUT_PRESSURE/projects" "$TEST_ROOT_TIMEOUT_PRESSURE/queues"
cat >"$TEST_ROOT_TIMEOUT_PRESSURE/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
cat >"$TEST_ROOT_TIMEOUT_PRESSURE/codex-learning/metrics.json" <<'EOF'
{
  "timeout_failure_records": 5,
  "timeout_failure_rate": 0.16
}
EOF
: >"$TEST_ROOT_TIMEOUT_PRESSURE/codex-memory/tasks.log"

cat >"$TEST_ROOT_TIMEOUT_PRESSURE/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

(
  cd "$TEST_ROOT_TIMEOUT_PRESSURE"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-seed-timeout-pressure.json" >/dev/null
)

python3 - "$TEST_ROOT_TIMEOUT_PRESSURE" "$TMP_DIR/strategy-seed-timeout-pressure.json" <<'PY'
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
assert [task["strategy_template"] for task in created] == [
    "enterprise_timeout_stability",
    "enterprise_mobile_console",
]

timeout_task = created[0]
mobile_task = created[1]
assert timeout_task["title"] == "Cut queue timeout churn before retries burn worker capacity"
assert timeout_task["task_intent"]["context_hint"] == "Observed queue timeout pressure"
assert timeout_task["task_intent"]["constraints"] == [
    "Touch only one timeout-prone queue or orchestration path surfaced by the current timeout evidence.",
    "Do not change retry limits, queue worker counts, or broad strategy seeding behavior.",
]
assert timeout_task["task_intent"]["success_signals"] == [
    "The chosen timeout-prone path is narrowed or reconciled without introducing another generic timeout classification.",
    "A focused timeout-specific regression test proves the behavior deterministically.",
]
assert timeout_task["task_intent"]["affected_files"] == []
assert timeout_task["timeout_failure_learning"] == {
    "detected": True,
    "timeout_failure_records": 5,
    "timeout_failure_rate": 0.16,
}
assert output["data"]["board_tasks"] == [
    {
        "id": timeout_task["id"],
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
    {
        "id": mobile_task["id"],
        "action": "created",
        "source_task_id": "enterprise-readiness",
    },
]
PY

echo "strategy enterprise timeout pressure ordering test passed"

TEST_ROOT_TIMEOUT_REPAIR="$TMP_DIR/timeout-repair-repo"
mkdir -p "$TEST_ROOT_TIMEOUT_REPAIR"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT_TIMEOUT_REPAIR/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT_TIMEOUT_REPAIR/agents"
mkdir -p "$TEST_ROOT_TIMEOUT_REPAIR/codex-memory" "$TEST_ROOT_TIMEOUT_REPAIR/codex-learning" "$TEST_ROOT_TIMEOUT_REPAIR/codex-logs" "$TEST_ROOT_TIMEOUT_REPAIR/projects" "$TEST_ROOT_TIMEOUT_REPAIR/queues"
cat >"$TEST_ROOT_TIMEOUT_REPAIR/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF
cat >"$TEST_ROOT_TIMEOUT_REPAIR/codex-learning/metrics.json" <<'EOF'
{
  "timeout_failure_records": 5,
  "timeout_failure_rate": 0.16
}
EOF
: >"$TEST_ROOT_TIMEOUT_REPAIR/codex-memory/tasks.log"

cat >"$TEST_ROOT_TIMEOUT_REPAIR/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-timeout-reference",
      "title": "Tighten late timeout reconciliation for claimed queue tasks",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 9,
      "effort": 2,
      "confidence": 0.84,
      "score": 7.56,
      "status": "failed",
      "strategy_template": "enterprise_timeout_stability",
      "created_at": "2026-03-24T02:00:00Z",
      "updated_at": "2026-03-24T02:06:00Z",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Tighten late timeout reconciliation for claimed queue tasks",
        "project": "codex-agent-system",
        "category": "stability",
        "context_hint": "Lane-4 timed out on the `superheld` Gradle-wrapper task after step 2/3, so focus on the bounded late-outcome reconciliation path for claimed tasks.",
        "constraints": [
          "Touch only timeout reconciliation or its deterministic observability path.",
          "Do not change queue scheduling, retry limits, or strategy task generation."
        ],
        "success_signals": [
          "Late terminal evidence prevents a fresh timeout failure classification for the claimed task.",
          "Existing timeout reconciliation tests stay green."
        ],
        "affected_files": [
          "scripts/lib.sh",
          "tests/queue-worker-timeout-success-reconciliation.sh",
          "tests/queue-worker-timeout-log-success-reconciliation.sh",
          "tests/queue-worker-timeout-classification.sh"
        ]
      },
      "timeout_failure_learning": {
        "detected": true,
        "timeout_failure_records": 4,
        "timeout_failure_rate": 0.13,
        "observed_example_project": "superheld",
        "observed_example_lane": "lane-4",
        "observed_example_task": "Resolve exact Gradle wrapper version for the current Android baseline"
      }
    },
    {
      "id": "task-timeout-pending",
      "title": "Cut queue timeout churn before retries burn worker capacity",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 9,
      "effort": 2,
      "confidence": 0.84,
      "score": 6.8,
      "status": "pending_approval",
      "strategy_template": "enterprise_timeout_stability",
      "created_at": "2026-03-24T03:00:00Z",
      "updated_at": "2026-03-24T03:00:00Z",
      "task_intent": {
        "source": "strategy_seed",
        "objective": "Cut queue timeout churn before retries burn worker capacity",
        "project": "codex-agent-system",
        "category": "stability",
        "context_hint": "Observed queue timeout pressure",
        "constraints": [],
        "success_signals": [],
        "affected_files": []
      },
      "timeout_failure_learning": {
        "detected": true,
        "timeout_failure_records": 5,
        "timeout_failure_rate": 0.16
      },
      "history": []
    }
  ]
}
EOF

(
  cd "$TEST_ROOT_TIMEOUT_REPAIR"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-timeout-repair.json" >/dev/null
)

python3 - "$TEST_ROOT_TIMEOUT_REPAIR" "$TMP_DIR/strategy-timeout-repair.json" <<'PY'
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
pending = next(task for task in registry["tasks"] if task["id"] == "task-timeout-pending")
assert pending["task_intent"]["context_hint"] == "Lane-4 timed out on the `superheld` Gradle-wrapper task after step 2/3, so focus on the bounded late-outcome reconciliation path for claimed tasks."
assert pending["task_intent"]["constraints"] == [
    "Touch only timeout reconciliation or its deterministic observability path.",
    "Do not change queue scheduling, retry limits, or strategy task generation.",
]
assert pending["task_intent"]["success_signals"] == [
    "Late terminal evidence prevents a fresh timeout failure classification for the claimed task.",
    "Existing timeout reconciliation tests stay green.",
]
assert pending["task_intent"]["affected_files"] == [
    "scripts/lib.sh",
    "tests/queue-worker-timeout-success-reconciliation.sh",
    "tests/queue-worker-timeout-log-success-reconciliation.sh",
    "tests/queue-worker-timeout-classification.sh",
]
assert pending["timeout_failure_learning"]["observed_example_project"] == "superheld"
assert pending["timeout_failure_learning"]["observed_example_lane"] == "lane-4"
assert pending["timeout_failure_learning"]["observed_example_task"] == "Resolve exact Gradle wrapper version for the current Android baseline"
assert pending["history"][-1]["action"] == "auto_repair"
assert "prior timeout guidance" in pending["history"][-1]["note"]
assert any(item["id"] == "task-timeout-pending" and item["action"] == "existing" for item in output["data"]["board_tasks"])
PY

echo "strategy pending timeout repair test passed"
