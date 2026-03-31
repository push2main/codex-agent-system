#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root"
  cp -R "$ROOT_DIR/scripts" "$repo_root/scripts"
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

recent_failure_at="$(
  python3 - <<'PY'
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) - timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
)"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-001-reduce-timeout-rate",
      "title": "Reduce timeout rate",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$recent_failure_at",
      "target_files": ["agents/planner.sh", "agents/orchestrator.sh", "scripts/queue-worker.sh"],
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-cap-pre-step-planning-budget",
      "title": "Cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$recent_failure_at",
      "target_files": ["agents/planner.sh"],
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-003-inventory-current-decision-path",
      "title": "Inventory current decision path for cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "$recent_failure_at",
      "strategy_template": "bounded_learning_inventory",
      "target_files": ["agents/planner.sh"],
      "task_intent": {
        "source": "self-improve"
      },
      "execution_context": {
        "result": "FAILURE",
        "step_count": 3,
        "completed_steps": 3,
        "failed_step_index": 0,
        "failed_step": ""
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<EOF
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"Success task 1","task_id":"task-success-1","result":"SUCCESS","attempt":1}
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"Success task 2","task_id":"task-success-2","result":"SUCCESS","attempt":1}
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"Success task 3","task_id":"task-success-3","result":"SUCCESS","attempt":1}
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"Success task 4","task_id":"task-success-4","result":"SUCCESS","attempt":1}
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"Reduce timeout rate","task_id":"task-001-reduce-timeout-rate","result":"FAILURE","attempts":1,"score":2,"failure_kind":"timeout","total_step_attempts":0,"failed_step":"Reduce timeout rate timed out before any step executed."}
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"Cap pre-step planning budget","task_id":"task-002-cap-pre-step-planning-budget","result":"FAILURE","attempts":1,"score":2,"failure_kind":"timeout","total_step_attempts":0,"failed_step":"Cap pre-step planning budget timed out before any step executed."}
{"timestamp":"$recent_failure_at","project":"codex-agent-system","task":"Inventory current decision path for cap pre-step planning budget","task_id":"task-003-inventory-current-decision-path","result":"FAILURE","attempts":2,"score":0,"failure_kind":"","total_step_attempts":4,"failed_step":""}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.10,
  "recent_success_rate": 0.02,
  "first_pass_success_rate": 1.0,
  "timeout_failure_rate": 0.32,
  "zero_step_timeout_rate": 0.93,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 29,
  "retry_total_count": 29,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 191572,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "pipeline_stale": false,
  "total_tasks": 100
}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<EOF
{
  "updated_at": "$recent_failure_at",
  "signals": [
    {
      "id": "signal-001",
      "source_id": "test-source",
      "source_label": "Test source",
      "title": "Fresh signal",
      "url": "https://example.com/fresh-signal",
      "published_at": "$recent_failure_at",
      "fetched_at": "$recent_failure_at",
      "fresh": true
    }
  ],
  "errors": []
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  SELF_IMPROVE_FAILURE_COOLDOWN_SECONDS=86400 \
  SELF_IMPROVE_TITLE_FAMILY_RETRY_COOLDOWN_SECONDS=7200 \
  SELF_IMPROVE_TITLE_FAMILY_SATURATION_COOLDOWN_SECONDS=86400 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

python3 - "$REPO_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
pending = [
    task for task in payload["tasks"]
    if task.get("status") == "pending_approval"
]

assert len(pending) == 1, pending
task = pending[0]
assert task["title"] == "Inventory current decision path for cap pre-step planning budget", task
assert task["strategy_template"] == "bounded_learning_inventory", task
assert task.get("target_files") == ["agents/planner.sh"], task
PY

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.analysis_reason,
      .selection.selected_title
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1\ttitle_family_cooldown\tInventory current decision path for cap pre-step planning budget' ]; then
  echo "unexpected finalize-failure inventory regeneration summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve title-family finalize-failure inventory regeneration test passed"
