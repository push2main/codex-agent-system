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
  "$TEST_ROOT/projects/superheld" \
  "$TEST_ROOT/workspaces/superheld/packages/schema"

failed_at_90s_ago="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(seconds=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$TEST_ROOT/workspaces/superheld",
  "repo_url": "https://example.invalid/superheld",
  "policy_file": "$TEST_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
}
EOF

mkdir -p "$TEST_ROOT/workspaces/superheld/.codex-agent"

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "risk_profile": "high",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$TEST_ROOT/workspaces/superheld/packages/schema/incident.schema.json" <<'EOF'
{
  "title": "Incident schema fixture",
  "examples": []
}
EOF

cat >"$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-learning-inventory",
      "title": "Inventory current decision path for cap pre-step planning budget",
      "execution_task": "[self-improve:critical] Inventory current decision path for cap pre-step planning budget",
      "project": "superheld",
      "status": "failed",
      "score": 4.1,
      "created_at": "__FAILED_AT_90S_AGO__",
      "updated_at": "__FAILED_AT_90S_AGO__",
      "failed_at": "__FAILED_AT_90S_AGO__",
      "strategy_template": "bounded_learning_inventory",
      "target_files": ["packages/schema/incident.schema.json"],
      "last_failure_kind": "missing_source_file",
      "task_intent": {
        "source": "self-improve",
        "objective": "Inventory current decision path for cap pre-step planning budget",
        "project": "superheld",
        "category": "learning",
        "affected_files": ["packages/schema/incident.schema.json"]
      },
      "failure_context": {
        "failure_kind": "missing_source_file"
      },
      "history": [
        {
          "at": "__FAILED_AT_90S_AGO__",
          "action": "execute_failure",
          "from_status": "running",
          "to_status": "failed",
          "project": "superheld",
          "queue_task": "[self-improve:critical] Inventory current decision path for cap pre-step planning budget",
          "note": "Queue execution failed after exhausting retries."
        }
      ]
    }
  ]
}
EOF

python3 - "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json" "$failed_at_90s_ago" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
failed_at = sys.argv[2]
path.write_text(path.read_text(encoding="utf-8").replace("__FAILED_AT_90S_AGO__", failed_at), encoding="utf-8")
PY

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pipeline_stale": false,
  "pipeline_stale_since": null,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 1
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-29T23:30:30Z","project":"superheld","task":"[self-improve:critical] Inventory current decision path for cap pre-step planning budget","result":"FAILURE","failure_kind":"missing_source_file","task_id":"task-learning-inventory","attempts":2,"score":0,"run_id":"run-superheld-1"}
EOF

(
  cd "$TEST_ROOT"
  python3 scripts/strategy-auto-approve.py \
    workspaces/superheld/.codex-agent/tasks.json \
    codex-learning/metrics.json \
    codex-memory/tasks.log >/dev/null
)

inventory_status="$(
  jq -r '.tasks[] | select(.id == "task-learning-inventory") | .status' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
queued_tasks="$(cat "$TEST_ROOT/queues/superheld.txt")"
history_action="$(
  jq -r '.tasks[] | select(.id == "task-learning-inventory") | .history[-1].action' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"

if [ "$inventory_status" != "approved" ]; then
  echo "expected grounded missing_source failure to auto-requeue to approved, got: $inventory_status" >&2
  exit 1
fi

if [ "$queued_tasks" != "[self-improve:critical] Inventory current decision path for cap pre-step planning budget" ]; then
  echo "expected bounded learning inventory task to be queued on auto-requeue, got: $queued_tasks" >&2
  exit 1
fi

if [ "$history_action" != "auto_requeue_grounded_missing_source" ]; then
  echo "expected auto_requeue_grounded_missing_source history action, got: $history_action" >&2
  exit 1
fi

echo "strategy auto approve grounded missing source requeue test passed"
