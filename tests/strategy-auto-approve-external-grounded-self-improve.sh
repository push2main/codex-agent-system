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
  "$TEST_ROOT/workspaces/superheld/packages/schema" \
  "$TEST_ROOT/workspaces/superheld/.codex-agent"

created_at_90s_ago="$(
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

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "risk_profile": "high",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": []
}
EOF

cat >"$TEST_ROOT/workspaces/superheld/packages/schema/telemetry-event.schema.json" <<'EOF'
{
  "title": "Telemetry schema fixture"
}
EOF

cat >"$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-manual-review",
      "title": "Manual review placeholder",
      "project": "superheld",
      "status": "pending_approval",
      "score": 9.9,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "task_intent": {
        "source": "dashboard_backlog",
        "objective": "Manual review placeholder",
        "project": "superheld",
        "category": "ui"
      }
    },
    {
      "id": "task-external-grounded-self-improve",
      "title": "Add credential recovery trigger coverage to telemetry event schema",
      "execution_task": "[self-improve:high] Add credential recovery trigger coverage to telemetry event schema",
      "project": "superheld",
      "status": "pending_approval",
      "score": 4.6,
      "created_at": "__CREATED_AT_90S_AGO__",
      "updated_at": "__CREATED_AT_90S_AGO__",
      "strategy_template": "self_improvement",
      "target_files": ["packages/schema/telemetry-event.schema.json"],
      "task_intent": {
        "source": "self-improve",
        "objective": "Add credential recovery trigger coverage to telemetry event schema",
        "project": "superheld",
        "category": "learning",
        "affected_files": ["packages/schema/telemetry-event.schema.json"]
      }
    }
  ]
}
EOF

python3 - "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json" "$created_at_90s_ago" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
created_at = sys.argv[2]
path.write_text(path.read_text(encoding="utf-8").replace("__CREATED_AT_90S_AGO__", created_at), encoding="utf-8")
PY

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pipeline_stale": false,
  "pipeline_stale_since": null,
  "pending_approval_tasks": 2,
  "approved_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 2
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

auto_result="$(
  cd "$TEST_ROOT" &&
    python3 scripts/strategy-auto-approve.py \
      workspaces/superheld/.codex-agent/tasks.json \
      codex-learning/metrics.json \
      codex-memory/tasks.log
)"

manual_status="$(
  jq -r '.tasks[] | select(.id == "task-manual-review") | .status' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
task_status="$(
  jq -r '.tasks[] | select(.id == "task-external-grounded-self-improve") | .status' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"
queue_contents="$(
  tr -d '\r' <"$TEST_ROOT/queues/superheld.txt"
)"
history_action="$(
  jq -r '.tasks[] | select(.id == "task-external-grounded-self-improve") | .history[-1].action' "$TEST_ROOT/workspaces/superheld/.codex-agent/tasks.json"
)"

if [ "$manual_status" != "pending_approval" ]; then
  echo "expected manual task to remain pending_approval, got: $manual_status" >&2
  exit 1
fi

if [ "$task_status" != "approved" ]; then
  echo "expected external grounded self-improve task to auto-approve after 90s with zero queue, got: $task_status" >&2
  exit 1
fi

if [ "$queue_contents" != "[self-improve:high] Add credential recovery trigger coverage to telemetry event schema" ]; then
  echo "expected only the grounded external self-improve task to be queued, got: $queue_contents" >&2
  exit 1
fi

if [ "$history_action" != "auto_approve_stale_pipeline" ]; then
  echo "expected auto_approve_stale_pipeline history action, got: $history_action" >&2
  exit 1
fi

if [[ "$auto_result" != AUTO_APPROVED:* ]]; then
  echo "expected AUTO_APPROVED output, got: $auto_result" >&2
  exit 1
fi

echo "strategy auto approve external grounded self improve test passed"
