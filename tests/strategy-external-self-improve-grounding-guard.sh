#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
EXTERNAL_WORKSPACE="$TMP_DIR/superheld-repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/projects/superheld" \
  "$EXTERNAL_WORKSPACE/.codex-agent"

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$EXTERNAL_WORKSPACE/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_WORKSPACE/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_WORKSPACE/.codex-agent/policy.json",
  "task_registry_file": "$TEST_ROOT/codex-memory/tasks.json"
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-timeout",
      "title": "Reduce timeout rate",
      "execution_task": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
      "project": "superheld",
      "status": "pending_approval",
      "score": 4.2,
      "created_at": "2026-03-25T00:05:00Z",
      "updated_at": "2026-03-25T00:05:00Z",
      "task_intent": {
        "source": "self-improve",
        "objective": "Reduce timeout rate",
        "project": "superheld",
        "category": "stability",
        "affected_files": ["agents/planner.sh", "scripts/queue-worker.sh"]
      },
      "target_files": ["agents/planner.sh", "scripts/queue-worker.sh"],
      "source_task_id": "self-improve",
      "root_source_task_id": "self-improve",
      "original_failed_root_id": "self-improve",
      "strategy_template": "self_improvement",
      "execution": {
        "state": "pending_approval",
        "attempt": 0,
        "max_retries": 2,
        "provider": "codex",
        "updated_at": "2026-03-25T00:05:00Z"
      },
      "history": []
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.2,
  "first_pass_success_rate": 0.0,
  "timeout_failure_rate": 0.4,
  "pending_approval_tasks": 1,
  "approved_tasks": 0,
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T01:00:00Z"
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

(
  cd "$TEST_ROOT"
  python3 scripts/strategy-auto-approve.py codex-memory/tasks.json codex-learning/metrics.json codex-memory/tasks.log >/dev/null
  python3 scripts/strategy-reconcile.py codex-memory/tasks.json codex-learning/metrics.json codex-memory/tasks.log >/dev/null
)

task_status="$(
  jq -r '.tasks[] | select(.id == "task-superheld-timeout") | .status' "$TEST_ROOT/codex-memory/tasks.json"
)"
queue_contents=""
if [ -f "$TEST_ROOT/queues/superheld.txt" ]; then
  queue_contents="$(cat "$TEST_ROOT/queues/superheld.txt")"
fi

if [ "$task_status" != "pending_approval" ]; then
  echo "expected external self-improve task to remain pending_approval, got: $task_status" >&2
  exit 1
fi

if [ -n "$queue_contents" ]; then
  echo "expected no queued task for ungrounded external self-improve candidate, got: $queue_contents" >&2
  exit 1
fi

echo "strategy external self-improve grounding guard test passed"
