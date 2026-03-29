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

created_at_20m_ago="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=20)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

pipeline_stale_since="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(hours=13)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

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

cat >"$TEST_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-self-improve-zombie",
      "title": "Improve first-pass success rate",
      "execution_task": "[self-improve:critical] Improve first-pass success rate",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 5.0,
      "created_at": "$created_at_20m_ago",
      "updated_at": "$created_at_20m_ago",
      "task_intent": {
        "source": "self-improve",
        "objective": "Improve first-pass success rate",
        "project": "codex-agent-system",
        "category": "stability"
      },
      "strategy_template": "self_improvement",
      "execution": {
        "state": "pending_approval",
        "attempt": 0,
        "max_retries": 2,
        "provider": "codex",
        "updated_at": "$created_at_20m_ago"
      }
    },
    {
      "id": "task-self-improve-valid",
      "title": "Refresh stale external signals",
      "execution_task": "[self-improve:medium] Refresh stale external signals",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 3.2,
      "created_at": "$created_at_20m_ago",
      "updated_at": "$created_at_20m_ago",
      "task_intent": {
        "source": "self-improve",
        "objective": "Refresh stale external signals",
        "project": "codex-agent-system",
        "category": "learning"
      },
      "strategy_template": "self_improvement",
      "execution": {
        "state": "pending_approval",
        "attempt": 0,
        "max_retries": 2,
        "provider": "codex",
        "updated_at": "$created_at_20m_ago"
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-28T01:00:00Z","project":"codex-agent-system","task":"[self-improve:critical] Improve first-pass success rate","result":"FAILURE","failure_kind":"empty_output","total_step_attempts":2}
{"timestamp":"2026-03-28T01:05:00Z","project":"codex-agent-system","task":"[self-improve:critical] Improve first-pass success rate","result":"FAILURE","failure_kind":"empty_output","total_step_attempts":2}
{"timestamp":"2026-03-28T01:10:00Z","project":"codex-agent-system","task":"[self-improve:critical] Improve first-pass success rate","result":"FAILURE","failure_kind":"review_rejection","total_step_attempts":2}
{"timestamp":"2026-03-28T01:15:00Z","project":"codex-agent-system","task":"[self-improve:critical] Improve first-pass success rate","result":"FAILURE","failure_kind":"review_rejection","total_step_attempts":2}
{"timestamp":"2026-03-28T01:20:00Z","project":"codex-agent-system","task":"[self-improve:critical] Improve first-pass success rate","result":"FAILURE","failure_kind":"unknown_persistent","total_step_attempts":2}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<EOF
{
  "success_rate": 0.12,
  "recent_success_rate": 0.0,
  "first_pass_success_rate": 0.0,
  "timeout_failure_rate": 0.4,
  "pending_approval_tasks": 2,
  "approved_tasks": 0,
  "pipeline_stale": true,
  "pipeline_stale_since": "$pipeline_stale_since"
}
EOF

(
  cd "$TEST_ROOT"
  bash -lc 'source scripts/lib.sh && ensure_runtime_dirs && reconcile_approved_registry_tasks_to_queue >/dev/null'
)

zombie_status="$(
  jq -r '.tasks[] | select(.id == "task-self-improve-zombie") | .status' "$TEST_ROOT/codex-memory/tasks.json"
)"
valid_status="$(
  jq -r '.tasks[] | select(.id == "task-self-improve-valid") | .status' "$TEST_ROOT/codex-memory/tasks.json"
)"
queued_tasks="$(cat "$TEST_ROOT/queues/codex-agent-system.txt")"

if [ "$zombie_status" != "pending_approval" ]; then
  echo "expected zombie candidate to stay pending_approval, got: $zombie_status" >&2
  exit 1
fi

if [ "$valid_status" != "approved" ]; then
  echo "expected next valid self-improve candidate to auto-approve, got: $valid_status" >&2
  exit 1
fi

if [ "$queued_tasks" != "[self-improve:medium] Refresh stale external signals" ]; then
  echo "expected only the non-zombie task to be queued, got: $queued_tasks" >&2
  exit 1
fi

echo "stale pipeline zombie auto-approve skip test passed"
