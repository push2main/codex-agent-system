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
mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$TEST_ROOT",
  "repo_url": "https://github.com/push2main/codex-agent-system/",
  "policy_file": "$TEST_ROOT/projects/codex-agent-system/policy.json",
  "task_registry_file": "$TEST_ROOT/codex-memory/tasks.json"
}
EOF

cat >"$TEST_ROOT/projects/codex-agent-system/policy.json" <<'EOF'
{
  "project": "codex-agent-system",
  "risk_profile": "standard",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-self-improve-stale-pipeline",
      "title": "Recover stale pipeline",
      "execution_task": "[self-improve:critical] Recover stale pipeline",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 5.2,
      "created_at": "2026-03-25T12:54:00Z",
      "updated_at": "2026-03-25T12:54:00Z",
      "task_intent": {
        "source": "self-improve",
        "objective": "Recover stale pipeline",
        "project": "codex-agent-system",
        "category": "stability"
      },
      "source_task_id": "self-improve",
      "root_source_task_id": "self-improve",
      "original_failed_root_id": "self-improve",
      "strategy_template": "self_improvement",
      "execution": {
        "state": "pending_approval",
        "attempt": 0,
        "max_retries": 2,
        "provider": "codex",
        "updated_at": "2026-03-25T12:54:00Z"
      }
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
  "pipeline_stale_since": "2026-03-25T00:00:00Z"
}
EOF

(
  cd "$TEST_ROOT"
  CODEX_EXTERNAL_SIGNAL_NOW=2026-03-25T13:00:00Z \
    bash -lc 'source scripts/lib.sh && ensure_runtime_dirs && reconcile_approved_registry_tasks_to_queue >/dev/null'
)

task_status="$(
  jq -r '.tasks[] | select(.id == "task-self-improve-stale-pipeline") | .status' "$TEST_ROOT/codex-memory/tasks.json"
)"
queued_tasks="$(cat "$TEST_ROOT/queues/codex-agent-system.txt")"
history_action="$(
  jq -r '.tasks[] | select(.id == "task-self-improve-stale-pipeline") | .history[-1].action' "$TEST_ROOT/codex-memory/tasks.json"
)"

if [ "$task_status" != "approved" ]; then
  echo "expected deep-stale self-improve task to auto-approve after 5 minutes, got: $task_status" >&2
  exit 1
fi

if [ "$queued_tasks" != "[self-improve:critical] Recover stale pipeline" ]; then
  echo "expected deep-stale self-improve task to be queued, got: $queued_tasks" >&2
  exit 1
fi

if [ "$history_action" != "auto_approve_stale_pipeline" ]; then
  echo "expected deep-stale auto-approval history entry, got: $history_action" >&2
  exit 1
fi

echo "stale pipeline deep stale auto approve test passed"
