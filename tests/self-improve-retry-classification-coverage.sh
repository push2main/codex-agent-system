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
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "first_pass_success_rate": 0.65,
  "timeout_failure_rate": 0.02,
  "approved_tasks": 18,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "self_improve_paused": false,
  "self_improve_pause_escalated": false,
  "self_improve_pause_age_seconds": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "retry_classification_coverage": 0.22,
  "retry_classified_count": 13,
  "retry_total_count": 58,
  "external_signal_status": "fresh",
  "total_tasks": 140
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | first
    | [.title // "", .reason // "", .task_family // "", .strategy_playbook // "", (.task_shape.playbook // ""), (.metric_name // ""), (.metric_direction // ""), ((.metric_before // 0) | tostring)] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
expected_task_summary=$'Improve retry failure classification coverage\tOnly 22% of retry failures are classified (13/58); broaden deterministic failure capture before tuning broader retry behavior by enriching reviewer/evaluator context in orchestrator.sh and extending classify_failure patterns.\tretry-classification\tplaybooks/retry-classification.md\tplaybooks/retry-classification.md\tretry_classification_coverage\tincrease\t0.22'
if [ "$task_summary" != "$expected_task_summary" ]; then
  echo "unexpected retry-classification self-improve task: $task_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .selected_improvement,
      .counts.generated,
      .counts.submitted,
      .metrics_snapshot.retry_classification_coverage,
      .metrics_snapshot.retry_classified_count,
      .metrics_snapshot.retry_total_count
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'Improve retry failure classification coverage\t2\t1\t0.22\t13\t58' ]; then
  echo "unexpected retry-classification run artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve retry classification coverage test passed"
