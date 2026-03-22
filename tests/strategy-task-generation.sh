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
    "stability": {
      "weight": 1.8,
      "success_rate": 0.76
    },
    "ui": {
      "weight": 1.35,
      "success_rate": 0.81
    },
    "performance": {
      "weight": 1.1,
      "success_rate": 0.7
    },
    "code_quality": {
      "weight": 1.05,
      "success_rate": 0.79
    }
  }
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-019-deterministic-approved-task-briefs",
      "title": "Shape approved tasks into deterministic execution briefs",
      "impact": 8,
      "effort": 4,
      "confidence": 0.84,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Direct queue submissions now stop at pending approval, but approved work still reaches the queue as raw user text, so reviewers and agents still depend on unstructured prompts.",
      "score": 3.02,
      "status": "failed",
      "created_at": "2026-03-22T16:00:00Z",
      "updated_at": "2026-03-22T16:10:00Z",
      "failed_at": "2026-03-22T16:10:00Z"
    },
    {
      "id": "task-020-approval-brief-snapshot",
      "title": "Persist approval-time execution brief snapshots",
      "impact": 8,
      "effort": 3,
      "confidence": 0.83,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Existing approval handoff still recomputes queue text instead of freezing a deterministic brief.",
      "hypothesis": "If approval stores a fixed execution brief snapshot, retries will receive identical structured input.",
      "experiment": "Persist an execution_brief object at approval time and use it for queue handoff.",
      "success_criteria": [
        "store deterministic execution_brief",
        "approved handoff reads the snapshot"
      ],
      "rollback": "Remove the approval-time execution_brief snapshot.",
      "score": 3.98,
      "status": "pending_approval",
      "created_at": "2026-03-22T16:12:00Z",
      "updated_at": "2026-03-22T16:12:00Z"
    },
    {
      "id": "task-017-ui-task-prompt-shaping",
      "title": "Shape dashboard-submitted tasks into role, context, and constraints",
      "impact": 7,
      "effort": 4,
      "confidence": 0.8,
      "category": "ui",
      "project": "codex-agent-system",
      "reason": "Raw UI task text still reaches the queue without consistent role, context, or safety framing, which makes execution less precise and harder to approve confidently from mobile.",
      "score": 1.89,
      "status": "failed",
      "created_at": "2026-03-22T15:40:00Z",
      "updated_at": "2026-03-22T15:50:00Z",
      "failed_at": "2026-03-22T15:50:00Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-first.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-first.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)

assert output["status"] == "success"
assert len(output["data"]["board_tasks"]) == 2
assert output["data"]["board_tasks"][0]["action"] == "updated"
assert output["data"]["board_tasks"][1]["action"] == "created"

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

tasks = registry["tasks"]
assert len(tasks) == 4

pending = [task for task in tasks if task["status"] == "pending_approval"]
assert len(pending) == 2

approval_snapshot = next(task for task in tasks if task["id"] == "task-020-approval-brief-snapshot")
assert approval_snapshot["source_task_id"] == "task-019-deterministic-approved-task-briefs"
assert approval_snapshot["strategy_template"] == "approval_brief_snapshot"

intent_task = next(task for task in tasks if task["title"] == "Persist dashboard task intent metadata before queue handoff")
assert intent_task["source_task_id"] == "task-017-ui-task-prompt-shaping"
assert intent_task["strategy_template"] == "dashboard_task_intent_metadata"
assert intent_task["category"] == "ui"
assert intent_task["status"] == "pending_approval"
assert intent_task["score"] == 2.52
assert len(intent_task["success_criteria"]) == 4

with open(os.path.join(root, "codex-learning", "metrics.json"), "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert metrics["analysis_runs"] == 4
assert metrics["pending_approval_tasks"] == 2
assert metrics["approved_tasks"] == 0
assert metrics["task_registry_total"] == 4
assert metrics["last_task_score"] == 2.52
PY

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-second.json" >/dev/null
)

python3 - "$TEST_ROOT" "$TMP_DIR/strategy-second.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)

assert output["status"] == "success"
assert len(output["data"]["board_tasks"]) == 1
assert output["data"]["board_tasks"][0]["source_task_id"] == "enterprise-readiness"

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

assert len(registry["tasks"]) == 5
assert sum(1 for task in registry["tasks"] if task["status"] == "pending_approval") == 3
assert any(task["title"] == "Tighten the mobile dashboard into an enterprise control surface" for task in registry["tasks"])
PY

echo "strategy task generation test passed"

TMP_DIR_2="$(mktemp -d)"
TEST_ROOT_2="$TMP_DIR_2/repo"
trap 'rm -rf "$TMP_DIR" "$TMP_DIR_2"' EXIT

mkdir -p "$TEST_ROOT_2"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT_2/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT_2/agents"
mkdir -p "$TEST_ROOT_2/codex-memory" "$TEST_ROOT_2/codex-learning" "$TEST_ROOT_2/codex-logs" "$TEST_ROOT_2/projects" "$TEST_ROOT_2/queues"
cp "$TEST_ROOT/codex-memory/priority.json" "$TEST_ROOT_2/codex-memory/priority.json"
: >"$TEST_ROOT_2/codex-memory/tasks.log"

cat >"$TEST_ROOT_2/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-014-stale-session-warning",
      "title": "Warn when the tmux queue session is running stale runtime scripts",
      "impact": 8,
      "effort": 4,
      "confidence": 0.81,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Operators still have to infer stale runtime state manually.",
      "score": 1.0,
      "status": "failed",
      "created_at": "2026-03-22T16:08:37Z",
      "updated_at": "2026-03-22T16:24:50Z",
      "failed_at": "2026-03-22T16:24:50Z"
    },
    {
      "id": "task-016-auto-session-reload",
      "title": "Restart the queue session automatically after runtime helper changes",
      "impact": 8,
      "effort": 5,
      "confidence": 0.78,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Automatic recovery stayed too broad.",
      "score": 1.0,
      "status": "failed",
      "created_at": "2026-03-22T16:12:42Z",
      "updated_at": "2026-03-22T16:26:51Z",
      "failed_at": "2026-03-22T16:26:51Z"
    },
    {
      "id": "task-022-persist-restart-needed-runtime-state-whe",
      "title": "Persist restart-needed runtime state when helper scripts change",
      "impact": 7,
      "effort": 3,
      "confidence": 0.79,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Persist a restart-needed signal instead of automatic tmux restarts.",
      "hypothesis": "If the runtime records a deterministic restart-needed state when helper fingerprints diverge, operators can recover stale sessions reliably without attempting unsafe auto-restarts.",
      "experiment": "Detect queue helper fingerprint mismatch and persist a restart-needed state that the dashboard and status command can surface without restarting tmux automatically.",
      "success_criteria": [
        "A helper fingerprint mismatch writes a stable restart-needed flag into runtime state."
      ],
      "rollback": "Remove the restart-needed runtime flag and restore the current stale-helper warning-only behavior.",
      "source_task_id": "task-014-stale-session-warning",
      "root_source_task_id": "task-014-stale-session-warning",
      "related_source_task_ids": [
        "task-014-stale-session-warning"
      ],
      "strategy_template": "runtime_restart_needed_state",
      "strategy_depth": 1,
      "score": 2.25,
      "status": "pending_approval",
      "created_at": "2026-03-22T17:44:14Z",
      "updated_at": "2026-03-22T17:44:14Z"
    },
    {
      "id": "task-023-persist-structured-failure-context-for-s",
      "title": "Persist structured failure context for strategy follow-ups",
      "impact": 6,
      "effort": 3,
      "confidence": 0.76,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Task task-022-persist-restart-needed-runtime-state-whe failed without enough machine-readable failure context to derive the next smaller experiment deterministically.",
      "hypothesis": "If failed tasks persist a compact structured failure_context payload, later strategy runs can generate narrower successor tasks without relying on free-form log parsing.",
      "experiment": "Persist a failure_context object with failed step index, failing component, and retry outcome whenever queue execution ends in failed state.",
      "success_criteria": [
        "Failed tasks persist a failure_context object with deterministic keys."
      ],
      "rollback": "Remove the failure_context payload and restore the current failed-task persistence behavior.",
      "source_task_id": "task-014-stale-session-warning",
      "root_source_task_id": "task-014-stale-session-warning",
      "related_source_task_ids": [
        "task-014-stale-session-warning"
      ],
      "strategy_template": "structured_failure_context",
      "strategy_depth": 1,
      "score": 1.52,
      "status": "failed",
      "created_at": "2026-03-22T17:49:00Z",
      "updated_at": "2026-03-22T17:52:02Z",
      "failed_at": "2026-03-22T17:52:02Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT_2"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR_2/strategy-dedupe.json" >/dev/null
)

python3 - "$TEST_ROOT_2" "$TMP_DIR_2/strategy-dedupe.json" <<'PY'
import json
import os
import sys

root = sys.argv[1]
output_path = sys.argv[2]

with open(output_path, "r", encoding="utf-8") as handle:
    output = json.load(handle)

assert output["status"] == "success"
assert len(output["data"]["board_tasks"]) == 2
assert all(task["source_task_id"] == "enterprise-readiness" for task in output["data"]["board_tasks"])

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    registry = json.load(handle)

tasks = registry["tasks"]
assert len(tasks) == 6
pending = next(task for task in tasks if task["id"] == "task-022-persist-restart-needed-runtime-state-whe")
assert pending["updated_at"] == "2026-03-22T17:44:14Z"
assert pending["related_source_task_ids"] == ["task-014-stale-session-warning"]
assert sum(1 for task in tasks if task["title"] == "Persist structured failure context for strategy follow-ups") == 1
assert any(task["title"] == "Tighten the mobile dashboard into an enterprise control surface" for task in tasks)
assert any(task["title"] == "Make active worker ownership and progress explicit in the dashboard" for task in tasks)
PY
