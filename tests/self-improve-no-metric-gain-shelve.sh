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

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-retry-coverage",
      "title": "Improve retry failure classification coverage",
      "execution_task": "[self-improve:high] Improve retry failure classification coverage",
      "project": "codex-agent-system",
      "status": "completed",
      "metric_name": "retry_classification_coverage",
      "metric_direction": "increase",
      "metric_before": 0.9,
      "metric_before_display": "90% (9/10)",
      "score": 8,
      "completed_at": "2026-03-25T08:00:00Z",
      "updated_at": "2026-03-25T08:00:00Z",
      "task_intent": {
        "source": "self-improve",
        "objective": "Improve retry failure classification coverage",
        "project": "codex-agent-system",
        "category": "learning"
      },
      "history": [
        {
          "at": "2026-03-25T08:00:00Z",
          "action": "execute_success",
          "from_status": "running",
          "to_status": "completed",
          "project": "codex-agent-system",
          "queue_task": "[self-improve:high] Improve retry failure classification coverage",
          "note": "Task completed successfully."
        }
      ]
    }
  ]
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.92,
  "recent_success_rate": 0.9,
  "timeout_failure_rate": 0.01,
  "first_pass_success_rate": 0.84,
  "retry_classification_coverage": 0.9,
  "retry_classified_count": 9,
  "retry_total_count": 10,
  "diagnostic_coverage": 0.8,
  "recent_diagnostic_coverage": 0.8,
  "failures_with_diagnostic": 8,
  "total_failure_records": 10,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "task_registry_total": 1,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "self_improve_paused": false,
  "self_improve_pause_escalated": false,
  "self_improve_pause_age_seconds": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "external_signal_status": "fresh",
  "fresh_external_signal_count": 2,
  "total_tasks": 20
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select(.id == "task-001-retry-coverage"))
    | first
    | [
        .status,
        .keep_decision,
        .shelved_reason,
        ((.metric_after // 0) | tostring),
        (.metric_after_display // ""),
        .history[-1].action,
        .history[-1].to_status
      ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_summary" != $'shelved\tdiscarded\tauto-shelved: no metric gain on retry_classification_coverage (90% (9/10) -> 90% (9/10))\t0.9\t90% (9/10)\tauto_shelve\tshelved' ]; then
  echo "unexpected no-metric-gain self-improve task summary: $task_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .gating.retired_no_gain_completed_tasks,
      .gating.kept_metric_improved_completed_tasks,
      .selection.state
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'0\t1\t0\tnone' ]; then
  echo "unexpected self-improve artifact no-gain summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve no-metric-gain shelve test passed"
