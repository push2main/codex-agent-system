#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
TMP_DIR_AUTO="$(mktemp -d)"
TEST_ROOT_AUTO="$TMP_DIR_AUTO/repo"

cleanup() {
  rm -rf "$TMP_DIR" "$TMP_DIR_AUTO"
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

setup_repo "$TEST_ROOT"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-first.json" >/dev/null
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-second.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-first.json" "$TMP_DIR/strategy-second.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
first_path = sys.argv[2]
second_path = sys.argv[3]

with open(first_path, "r", encoding="utf-8") as handle:
    first = json.load(handle)
with open(second_path, "r", encoding="utf-8") as handle:
    second = json.load(handle)
with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

assert first["status"] == "success"
assert len(first["data"]["board_tasks"]) == 2
assert second["status"] == "success"
assert second["data"]["board_tasks"] == [
    {
        "id": "task-003-surface-security-audit-and-governance-re",
        "action": "created",
        "source_task_id": "enterprise-readiness",
    }
]

tasks = registry["tasks"]
assert len(tasks) == 3
assert {task["title"] for task in tasks} == {
    "Tighten the mobile dashboard into an enterprise control surface",
    "Make active worker ownership and progress explicit in the dashboard",
    "Surface security, audit, and governance readiness in the dashboard",
}
assert all(task["status"] == "pending_approval" for task in tasks)
assert all(task["source_task_id"] == "enterprise-readiness::codex-agent-system" for task in tasks)
assert {task["strategy_template"] for task in tasks} == {
    "enterprise_mobile_console",
    "enterprise_live_work_observability",
    "enterprise_audit_governance",
}
assert all(task["task_intent"]["source"] == "strategy_seed" for task in tasks)
assert all(task["task_intent"]["objective"] == task["title"] for task in tasks)
assert all(task["task_intent"]["context_hint"] == "Enterprise readiness backlog" for task in tasks)
PY

setup_repo "$TEST_ROOT_AUTO"

cat >"$TEST_ROOT_AUTO/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$TEST_ROOT_AUTO/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "auto",
  "updated_at": "2026-03-22T20:45:00Z"
}
EOF

(
  cd "$TEST_ROOT_AUTO"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR_AUTO/strategy-auto.json" >/dev/null
)

python3 - "$TEST_ROOT_AUTO" "$TMP_DIR_AUTO/strategy-auto.json" <<'PY'
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
assert len(output["data"]["board_tasks"]) == 2

assert len(registry["tasks"]) == 2
assert all(task["status"] == "pending_approval" for task in registry["tasks"])
assert {task["strategy_template"] for task in registry["tasks"]} == {
    "enterprise_mobile_console",
    "enterprise_live_work_observability",
}
assert all(task["execution_provider"] == "codex" for task in registry["tasks"])
assert all(task["task_intent"]["source"] == "strategy_seed" for task in registry["tasks"])
assert all(task["task_intent"]["objective"] == task["title"] for task in registry["tasks"])
assert all(task["task_intent"]["context_hint"] == "Enterprise readiness backlog" for task in registry["tasks"])
assert not os.path.exists(os.path.join(root, "queues", "codex-agent-system.txt"))
PY

TEST_ROOT_RUNNING="$TMP_DIR/running-repo"
setup_repo "$TEST_ROOT_RUNNING"

cat >"$TEST_ROOT_RUNNING/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-running-1",
      "title": "Existing running self-improvement task one",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "status": "running",
      "strategy_template": "runtime_state_reconciliation",
      "task_intent": {
        "source": "strategy_anomaly",
        "objective": "Existing running self-improvement task one",
        "project": "codex-agent-system",
        "category": "stability"
      },
      "created_at": "2026-03-22T18:00:00Z",
      "updated_at": "2026-03-22T18:00:00Z",
      "execution": {
        "state": "running",
        "lane": "lane-1",
        "lease_state": "claimed",
        "lease_expires_at": "2099-03-22T18:10:00Z"
      }
    },
    {
      "id": "task-running-2",
      "title": "Existing running self-improvement task two",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "status": "running",
      "strategy_template": "queue_drain_completion_guard",
      "task_intent": {
        "source": "strategy_anomaly",
        "objective": "Existing running self-improvement task two",
        "project": "codex-agent-system",
        "category": "stability"
      },
      "created_at": "2026-03-22T18:01:00Z",
      "updated_at": "2026-03-22T18:01:00Z",
      "execution": {
        "state": "running",
        "lane": "lane-2",
        "lease_state": "claimed",
        "lease_expires_at": "2099-03-22T18:11:00Z"
      }
    },
    {
      "id": "task-running-3",
      "title": "Existing running self-improvement task three",
      "project": "codex-agent-system",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "status": "running",
      "strategy_template": "retry_churn_guard",
      "task_intent": {
        "source": "strategy_anomaly",
        "objective": "Existing running self-improvement task three",
        "project": "codex-agent-system",
        "category": "stability"
      },
      "created_at": "2026-03-22T18:02:00Z",
      "updated_at": "2026-03-22T18:02:00Z",
      "execution": {
        "state": "running",
        "lane": "lane-3",
        "lease_state": "claimed",
        "lease_expires_at": "2099-03-22T18:12:00Z"
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT_RUNNING"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/running-backfill.json" >/dev/null
)

python3 - "$TEST_ROOT_RUNNING" "$TMP_DIR/running-backfill.json" <<'PY'
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
assert len(output["data"]["board_tasks"]) == 0
tasks = registry["tasks"]
assert len(tasks) == 3
assert all(task["status"] == "running" for task in tasks)
PY

echo "strategy enterprise seeding test passed"
