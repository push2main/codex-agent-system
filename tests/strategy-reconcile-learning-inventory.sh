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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning"

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

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-manual-review",
      "title": "Manual review placeholder",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 9.9,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "task_intent": {
        "source": "dashboard_backlog",
        "objective": "Manual review placeholder",
        "project": "codex-agent-system",
        "category": "ui"
      }
    },
    {
      "id": "task-strategy-followup-learning-inventory",
      "title": "Inventory current decision path for Feed execution learning back into future provider and task decisions",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 4.1,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "strategy_template": "bounded_learning_inventory",
      "task_intent": {
        "source": "strategy_followup",
        "objective": "Inventory current decision path for Feed execution learning back into future provider and task decisions",
        "project": "codex-agent-system",
        "category": "learning"
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

: >"$TEST_ROOT/codex-memory/tasks.log"

reconcile_result="$(
  cd "$TEST_ROOT" &&
    python3 scripts/strategy-reconcile.py codex-memory/tasks.json codex-learning/metrics.json codex-memory/tasks.log
)"

manual_status="$(
  jq -r '.tasks[] | select(.id == "task-manual-review") | .status' "$TEST_ROOT/codex-memory/tasks.json"
)"
inventory_status="$(
  jq -r '.tasks[] | select(.id == "task-strategy-followup-learning-inventory") | .status' "$TEST_ROOT/codex-memory/tasks.json"
)"
history_action="$(
  jq -r '.tasks[] | select(.id == "task-strategy-followup-learning-inventory") | .history[-1].action' "$TEST_ROOT/codex-memory/tasks.json"
)"
queue_status="$(
  jq -r '.tasks[] | select(.id == "task-strategy-followup-learning-inventory") | .queue_handoff.status' "$TEST_ROOT/codex-memory/tasks.json"
)"
brief_status="$(
  jq -r '.tasks[] | select(.id == "task-strategy-followup-learning-inventory") | .execution_brief.status' "$TEST_ROOT/codex-memory/tasks.json"
)"

if [ "$manual_status" != "pending_approval" ]; then
  echo "expected manual task to remain pending_approval, got: $manual_status" >&2
  exit 1
fi

if [ "$inventory_status" != "approved" ]; then
  echo "expected cooldown reconcile to auto-approve bounded learning inventory, got: $inventory_status" >&2
  exit 1
fi

if [ "$history_action" != "auto_approve_stale_pipeline" ]; then
  echo "expected auto-approval history action during cooldown reconcile, got: $history_action" >&2
  exit 1
fi

if [ "$queue_status" != "queued" ]; then
  echo "expected cooldown reconcile queue_handoff.status=queued, got: $queue_status" >&2
  exit 1
fi

if [ "$brief_status" != "queued" ]; then
  echo "expected cooldown reconcile execution_brief.status=queued, got: $brief_status" >&2
  exit 1
fi

if [[ "$reconcile_result" != AUTO_APPROVED:* ]]; then
  echo "expected AUTO_APPROVED output, got: $reconcile_result" >&2
  exit 1
fi

queue_contents="$(
  tr -d '\r' <"$TEST_ROOT/queues/codex-agent-system.txt"
)"
expected_queue_entry="Inventory current decision path for Feed execution learning back into future provider and task decisions"
if [ "$queue_contents" != "$expected_queue_entry" ]; then
  echo "expected queue to contain cooldown-approved bounded learning inventory task, got: $queue_contents" >&2
  exit 1
fi

echo "strategy reconcile learning inventory test passed"
