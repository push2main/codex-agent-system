#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TASKS_FILE="$TMP_DIR/tasks.json"
TASK_LOG_FILE="$TMP_DIR/tasks.log"
METRICS_FILE="$TMP_DIR/metrics.json"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

cat >"$TASKS_FILE" <<'EOF'
{
  "tasks": [
    {
      "id": "task-manual-recovery",
      "title": "Add approval controls and audit trail to task board",
      "impact": 8,
      "effort": 4,
      "confidence": 0.82,
      "category": "ui",
      "project": "codex-agent-system",
      "reason": "Fixture for manual recovery task-log synchronization.",
      "score": 2.05,
      "status": "completed",
      "created_at": "2026-03-22T13:42:00Z",
      "updated_at": "2026-03-22T14:16:16Z",
      "completed_at": "2026-03-22T14:15:09Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-22T14:15:09Z",
        "will_retry": false
      },
      "history": [
        {
          "at": "2026-03-22T14:15:09Z",
          "action": "manual_complete",
          "from_status": "approved",
          "to_status": "completed",
          "project": "codex-agent-system",
          "queue_task": "Add approval controls and audit trail to task board",
          "note": "Recovered by verifying the existing dashboard approval implementation."
        }
      ]
    },
    {
      "id": "task-pending-follow-up",
      "title": "Refresh learning metrics after dashboard actions",
      "impact": 5,
      "effort": 2,
      "confidence": 0.83,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Fixture for pending approval metric counts.",
      "score": 3.22,
      "status": "pending_approval",
      "created_at": "2026-03-22T14:25:00Z",
      "updated_at": "2026-03-22T14:25:00Z"
    }
  ]
}
EOF

cat >"$TASK_LOG_FILE" <<'EOF'
{"timestamp":"2026-03-22T14:03:11Z","project":"codex-agent-system","task":"Add approval controls and audit trail to task board","result":"FAILURE","attempts":2,"score":0,"branch":"main","pr_url":"","run_id":"20260322-150010-13590","duration_seconds":181}
EOF

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null

jq -s -e '
  length == 2 and
  .[1].source == "manual_recovery" and
  .[1].task_id == "task-manual-recovery" and
  .[1].result == "SUCCESS" and
  .[1].score == 8 and
  .[1].run_id == "manual-recovery::task-manual-recovery::2026-03-22T14:15:09Z"
' "$TASK_LOG_FILE" >/dev/null

jq -e '
  .total_tasks == 2 and
  .success_rate == 0.5 and
  .analysis_runs == 2 and
  .pending_approval_tasks == 1 and
  .approved_tasks == 0 and
  .task_registry_total == 2 and
  .last_task_score == 3.22 and
  .manual_recovery_records == 1
' "$METRICS_FILE" >/dev/null

before_count="$(wc -l <"$TASK_LOG_FILE")"
python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null
after_count="$(wc -l <"$TASK_LOG_FILE")"

[ "$before_count" -eq "$after_count" ]

echo "recovery log sync test passed"
