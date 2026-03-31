#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/projects/superheld" \
  "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-shared-approved",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
      "execution_task": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
      "project": "superheld",
      "category": "ui",
      "effort": 2,
      "status": "approved",
      "created_at": "2026-03-29T20:11:38Z",
      "updated_at": "2026-03-29T20:12:12Z",
      "execution_provider": "claude",
      "queue_handoff": {
        "at": "2026-03-29T20:12:12Z",
        "project": "superheld",
        "task": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
        "status": "queued"
      },
      "history": [
        {
          "at": "2026-03-29T20:12:12Z",
          "action": "approve",
          "from_status": "pending_approval",
          "to_status": "approved",
          "project": "superheld",
          "queue_task": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
          "note": "Task was enqueued after approval."
        }
      ]
    }
  ]
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-external-existing",
      "title": "Existing external task",
      "project": "superheld",
      "status": "completed",
      "created_at": "2026-03-29T19:00:00Z",
      "updated_at": "2026-03-29T19:10:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_PROJECT_ROOT",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
}
EOF

cat >"$TMP_DIR/plan.json" <<'EOF'
{
  "data": {
    "steps": [
      "Inspect the shared-registry task resolution.",
      "Persist deterministic lifecycle context back to the shared registry."
    ]
  }
}
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  ensure_runtime_dirs
  task_norm="$(normalize_task "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%")"

  task_exists_anywhere "superheld" "$task_norm"

  resolved_timeout="$(resolve_task_timeout_seconds "superheld" "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%" "300")"
  [ "$resolved_timeout" = "420" ]

  step_bounds="$(resolve_task_step_bounds "superheld" "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%" "2" "6")"
  step_min="$(printf '%s\n' "$step_bounds" | sed -n '1p')"
  step_max="$(printf '%s\n' "$step_bounds" | sed -n '2p')"
  [ "$step_min" = "2" ]
  [ "$step_max" = "3" ]

  claim_json="$(claim_task_lease "superheld" "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%" "lane-1")"
  claimed_task_id="$(printf '%s' "$claim_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])')"
  [ "$claimed_task_id" = "task-superheld-shared-approved" ]

  sync_task_registry_execution_state \
    "superheld" \
    "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%" \
    "running" \
    "execute_start" \
    "Queue execution started." \
    "1" \
    "2" \
    "claude" \
    "lane-1" \
    "" \
    "0" \
    "$claimed_task_id"

  persist_task_run_context \
    "superheld" \
    "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%" \
    "SUCCESS" \
    "run-superheld-shared-001" \
    "1" \
    "2" \
    "5" \
    "61" \
    "2" \
    "2" \
    "0" \
    "" \
    "$TMP_DIR/plan.json" \
    "claude" \
    "" \
    "$claimed_task_id" \
    ""

  sync_task_registry_execution_state \
    "superheld" \
    "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%" \
    "completed" \
    "execute_success" \
    "Queue execution completed successfully." \
    "1" \
    "2" \
    "claude" \
    "lane-1" \
    "" \
    "0" \
    "$claimed_task_id"
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

shared_payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
external_payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

shared_task = next(task for task in shared_payload["tasks"] if task["id"] == "task-superheld-shared-approved")
external_task = next(task for task in external_payload["tasks"] if task["id"] == "task-external-existing")

assert shared_task["status"] == "completed", shared_task
assert shared_task["execution"]["state"] == "completed", shared_task
assert shared_task["execution"]["task_id"] == "task-superheld-shared-approved", shared_task
assert shared_task["execution_context"]["run_id"] == "run-superheld-shared-001", shared_task
assert shared_task["history"][-1]["action"] == "execute_success", shared_task["history"]

assert external_task["status"] == "completed", external_task
assert external_task["id"] == "task-external-existing", external_task
assert "execution_context" not in external_task, external_task
PY

echo "project shared registry lifecycle fallback test passed"
