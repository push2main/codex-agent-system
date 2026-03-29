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
      "id": "task-001-zombie-pending",
      "title": "Inventory current decision path for recover stale pipeline",
      "execution_task": "[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by saturated_family_cooldown while the live weakness signal is still active. Reuse the bounded inventory pattern to capture the exact files, functions, and decision points before another implementation retry. (files: scripts/multi-queue.sh)",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "created_at": "2026-03-28T07:04:43Z",
      "updated_at": "2026-03-28T07:09:55Z",
      "task_intent": {
        "source": "self-improve",
        "objective": "Inventory current decision path for recover stale pipeline",
        "project": "codex-agent-system",
        "category": "learning"
      },
      "history": []
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-28T04:05:31Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by recent_self_improve_failure_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"unknown_persistent","total_step_attempts":2}
{"timestamp":"2026-03-28T04:07:21Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by recent_self_improve_failure_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"unknown_persistent","total_step_attempts":2}
{"timestamp":"2026-03-28T04:20:20Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by saturated_family_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"review_rejection","total_step_attempts":2}
{"timestamp":"2026-03-28T04:22:32Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by saturated_family_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"review_rejection","total_step_attempts":2}
{"timestamp":"2026-03-28T04:50:04Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by saturated_family_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"empty_output","total_step_attempts":2}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.9,
  "recent_success_rate": 0.9,
  "first_pass_success_rate": 0.9,
  "timeout_failure_rate": 0.01,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 10,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 1,
  "pending_approval_blocked_detected": false,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 1,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "pipeline_stale": false,
  "total_tasks": 20
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select(.id == "task-001-zombie-pending"))
    | first
    | [.status, .shelved_reason, (.history[-1].action // ""), (.history[-1].note // "")]
    | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
case "$task_summary" in
  $'shelved\tauto-shelved: task family already failed 5 times and is permanently blocked\tauto_shelve\tTask was automatically retired because this self-improve family already crossed the zombie threshold: task family already failed 5 times and is permanently blocked.')
    ;;
  *)
    echo "expected zombie pending self-improve task to be auto-shelved, got: $task_summary" >&2
    exit 1
    ;;
esac

artifact_summary="$(
  jq -r '
    [
      .gating.retired_resolved_pending_tasks,
      .gating.retired_obsolete_pending_tasks,
      .gating.active_self_improve_count
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t0\t0' ]; then
  echo "unexpected zombie-pending retirement artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve zombie pending shelve test passed"
