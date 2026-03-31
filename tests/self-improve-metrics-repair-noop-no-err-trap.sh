#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$REPO_ROOT/scripts" \
  "$REPO_ROOT/codex-memory" \
  "$REPO_ROOT/codex-learning" \
  "$REPO_ROOT/codex-logs" \
  "$REPO_ROOT/queues" \
  "$REPO_ROOT/projects"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-completed",
      "title": "Completed task",
      "project": "codex-agent-system",
      "status": "completed",
      "created_at": "2026-03-25T07:00:00Z",
      "updated_at": "2026-03-25T07:05:00Z",
      "completed_at": "2026-03-25T07:05:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-25T07:05:00Z"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T07:05:00Z","project":"codex-agent-system","task":"Completed task","task_id":"task-001-completed","result":"SUCCESS","attempts":1,"score":8,"run_id":"run-completed"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.50,
  "recent_success_rate": 0.50,
  "timeout_failure_rate": 0.10,
  "first_pass_success_rate": 0.50,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_pressure_bytes": 1024,
  "strategy_saturation": false,
  "retry_churn_detected": false,
  "self_improve_paused": false,
  "self_improve_pause_escalated": false,
  "external_signal_status": "fresh",
  "total_tasks": 1
}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-25T07:06:00Z",
  "signals": [],
  "errors": []
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

if rg -q 'Command failed at line' "$REPO_ROOT/codex-logs/system.log"; then
  echo "expected noop metrics alias repair to avoid ERR trap noise" >&2
  exit 1
fi

refresh_summary="$(
  jq -r '
    [
      .metrics_input.status,
      .metrics_input.refresh_performed
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$refresh_summary" != $'refreshed\ttrue' ]; then
  echo "expected non-repairable missing metrics keys to refresh cleanly: $refresh_summary" >&2
  exit 1
fi

echo "self improve metrics repair noop err-trap test passed"
