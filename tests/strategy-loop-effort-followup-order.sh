#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

setup_case() {
  local case_root="$1"
  local loop_effort_detected="$2"
  local loop_effort_extra_step_attempts="$3"

  mkdir -p "$case_root"
  cp -R "$ROOT_DIR/scripts" "$case_root/scripts"
  cp -R "$ROOT_DIR/agents" "$case_root/agents"
  mkdir -p "$case_root/codex-memory" "$case_root/codex-learning" "$case_root/codex-logs" "$case_root/projects" "$case_root/queues"

  cat >"$case_root/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF

  : >"$case_root/codex-memory/tasks.log"

  cat >"$case_root/codex-learning/metrics.json" <<EOF
{
  "loop_effort_detected": $loop_effort_detected,
  "loop_effort_task_count": 1,
  "loop_effort_extra_step_attempts": $loop_effort_extra_step_attempts
}
EOF

  cat >"$case_root/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-pending-existing",
      "title": "Existing pending fixture",
      "impact": 6,
      "effort": 2,
      "confidence": 0.8,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Keep one pending slot occupied so strategy only gets one new follow-up slot.",
      "hypothesis": "Only the top-ranked failed follow-up should be created.",
      "experiment": "Do not change this fixture task.",
      "success_criteria": [
        "Fixture remains pending."
      ],
      "rollback": "Remove the fixture task.",
      "score": 1.0,
      "status": "pending_approval",
      "created_at": "2026-03-23T10:00:00Z",
      "updated_at": "2026-03-23T10:00:00Z"
    },
    {
      "id": "task-approved-existing",
      "title": "Existing approved fixture",
      "impact": 6,
      "effort": 2,
      "confidence": 0.8,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Keep enterprise seed creation disabled after one new follow-up is added.",
      "hypothesis": "Actionable backlog reaches three after the chosen follow-up is created.",
      "experiment": "Do not change this fixture task.",
      "success_criteria": [
        "Fixture remains approved."
      ],
      "rollback": "Remove the fixture task.",
      "score": 1.0,
      "status": "approved",
      "created_at": "2026-03-23T10:01:00Z",
      "updated_at": "2026-03-23T10:01:00Z"
    },
    {
      "id": "task-broad-older",
      "title": "Broaden queue retry diagnostics across every lane and worker",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "This older failed family should win only when persistent loop effort prefers the smaller bounded child.",
      "score": 1.0,
      "status": "failed",
      "strategy_depth": 0,
      "created_at": "2026-03-23T10:10:00Z",
      "updated_at": "2026-03-23T10:11:00Z",
      "failed_at": "2026-03-23T10:11:00Z",
      "execution_context": {
        "step_count": 5
      },
      "failure_context": {
        "failed_step": "Implement a narrower deterministic retry guard."
      }
    },
    {
      "id": "task-approval-latest",
      "title": "Approval brief drift still breaks deterministic queue handoff",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "This newer failed family should win when loop effort is absent because recency stays the tiebreaker.",
      "score": 1.0,
      "status": "failed",
      "strategy_depth": 0,
      "created_at": "2026-03-23T10:12:00Z",
      "updated_at": "2026-03-23T10:13:00Z",
      "failed_at": "2026-03-23T10:13:00Z"
    }
  ]
}
EOF
}

NO_LOOP_ROOT="$TMP_DIR/no-loop"
LOOP_ROOT="$TMP_DIR/with-loop"
setup_case "$NO_LOOP_ROOT" false 0
setup_case "$LOOP_ROOT" true 4

(
  cd "$NO_LOOP_ROOT"
  bash agents/strategy.sh codex-agent-system "$NO_LOOP_ROOT/output.json" >/dev/null
)

(
  cd "$LOOP_ROOT"
  bash agents/strategy.sh codex-agent-system "$LOOP_ROOT/output.json" >/dev/null
)

python3 - "$NO_LOOP_ROOT" "$LOOP_ROOT" <<'PY'
import json
import os
import sys

no_loop_root, loop_root = sys.argv[1:]


def load_case(root: str):
    with open(os.path.join(root, "output.json"), "r", encoding="utf-8") as handle:
        output = json.load(handle)
    with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
        registry = json.load(handle)
    return output, registry


def created_followup(registry: dict, source_task_id: str):
    for task in registry["tasks"]:
        if task.get("source_task_id") == source_task_id and task.get("status") == "pending_approval":
            return task
    raise AssertionError(f"missing pending followup for {source_task_id}")


no_loop_output, no_loop_registry = load_case(no_loop_root)
loop_output, loop_registry = load_case(loop_root)

assert no_loop_output["status"] == "success"
assert no_loop_output["data"]["board_tasks"] == [
    {
        "id": "task-001-persist-approval-time-execution-brief-sn",
        "action": "created",
        "source_task_id": "task-approval-latest",
    }
]
no_loop_task = created_followup(no_loop_registry, "task-approval-latest")
assert no_loop_task["strategy_template"] == "approval_brief_snapshot"

assert loop_output["status"] == "success"
assert loop_output["data"]["board_tasks"] == [
    {
        "id": "task-001-implement-a-narrower-deterministic-retry",
        "action": "created",
        "source_task_id": "task-broad-older",
    }
]
loop_task = created_followup(loop_registry, "task-broad-older")
assert loop_task["strategy_template"] == "bounded_failed_step_child"
assert loop_task["title"] == "Implement a narrower deterministic retry guard"
PY

echo "strategy loop effort followup order test passed"
