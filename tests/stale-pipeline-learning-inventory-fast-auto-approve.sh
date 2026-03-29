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

created_at_90s_ago="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))
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

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-self-improve-generic-recovery",
      "title": "Recover stale pipeline",
      "execution_task": "[self-improve:critical] Recover stale pipeline",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 5.0,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
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
        "updated_at": "__CREATED_AT_90S_AGO__"
      }
    },
    {
      "id": "task-self-improve-learning-inventory",
      "title": "Inventory current decision path for recover stale pipeline",
      "execution_task": "[self-improve:critical] Inventory current decision path for recover stale pipeline",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 4.1,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "strategy_template": "bounded_learning_inventory",
      "task_intent": {
        "source": "self-improve",
        "objective": "Inventory current decision path for recover stale pipeline",
        "project": "codex-agent-system",
        "category": "learning"
      },
      "execution": {
        "state": "pending_approval",
        "attempt": 0,
        "max_retries": 2,
        "provider": "claude",
        "updated_at": "__CREATED_AT_90S_AGO__"
      }
    }
  ]
}
EOF

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$created_at_90s_ago" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
created_at = sys.argv[2]
path.write_text(path.read_text(encoding="utf-8").replace("__CREATED_AT_90S_AGO__", created_at), encoding="utf-8")
PY

cat >"$TEST_ROOT/codex-learning/metrics.json" <<EOF
{
  "success_rate": 0.12,
  "recent_success_rate": 0.2,
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

generic_status="$(
  jq -r '.tasks[] | select(.id == "task-self-improve-generic-recovery") | .status' "$TEST_ROOT/codex-memory/tasks.json"
)"
inventory_status="$(
  jq -r '.tasks[] | select(.id == "task-self-improve-learning-inventory") | .status' "$TEST_ROOT/codex-memory/tasks.json"
)"
queued_tasks="$(cat "$TEST_ROOT/queues/codex-agent-system.txt")"

if [ "$generic_status" != "pending_approval" ]; then
  echo "expected generic deep-stale recovery task to remain pending during the fast inventory window, got: $generic_status" >&2
  exit 1
fi

if [ "$inventory_status" != "approved" ]; then
  echo "expected bounded learning inventory task to auto-approve after 90s in deep-stale mode, got: $inventory_status" >&2
  exit 1
fi

if [ "$queued_tasks" != "[self-improve:critical] Inventory current decision path for recover stale pipeline" ]; then
  echo "expected only the bounded learning inventory task to be queued, got: $queued_tasks" >&2
  exit 1
fi

echo "stale pipeline learning inventory fast auto approve test passed"
