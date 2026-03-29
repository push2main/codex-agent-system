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

append_failures() {
  local log_file="$1"
  local title="$2"
  local failure_kind="$3"
  local total_step_attempts="$4"
  local failed_step="$5"
  local task_prefix="$6"
  local index

  for index in 1 2 3 4 5; do
    cat >>"$log_file" <<EOF
{"timestamp":"2026-03-28T08:0${index}:00Z","project":"codex-agent-system","task":"$title","task_id":"${task_prefix}-${index}","result":"FAILURE","failure_kind":"$failure_kind","total_step_attempts":$total_step_attempts,"failed_step":"$failed_step"}
EOF
  done
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"
append_failures "$REPO_ROOT/codex-memory/tasks.log" "Improve first-pass success rate" "review_rejection" 2 "Improve first-pass success rate retry stayed broad." "task-first-pass"
append_failures "$REPO_ROOT/codex-memory/tasks.log" "Reduce timeout rate" "timeout" 0 "Reduce timeout rate timed out before any step executed." "task-timeout"
append_failures "$REPO_ROOT/codex-memory/tasks.log" "Cap pre-step planning budget" "timeout" 0 "Cap pre-step planning budget timed out before any step executed." "task-planning-budget"
append_failures "$REPO_ROOT/codex-memory/tasks.log" "Recover stale pipeline" "review_rejection" 2 "Recover stale pipeline retry stayed broad." "task-stale"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.09,
  "recent_success_rate": 0.0,
  "first_pass_success_rate": 0.0,
  "timeout_failure_rate": 0.31,
  "zero_step_timeout_rate": 0.92,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 15,
  "retry_total_count": 15,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "diagnostic_coverage": 1.0,
  "failures_with_diagnostic": 20,
  "total_failure_records": 20,
  "external_signal_status": "fresh",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-24T19:35:27Z",
  "total_tasks": 200
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [
      .tasks[]
      | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")
    ] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected exhausted zombie-guard families to fall back to one bounded inventory task, got task count: $task_count" >&2
  exit 1
fi

task_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | first
    | [
        .title,
        (.strategy_template // ""),
        ((.target_files // []) | join(",")),
        (.task_intent.objective // "")
      ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_summary" != $'Inventory current decision path for cap pre-step planning budget\tbounded_learning_inventory\tagents/planner.sh\tInventory current decision path for cap pre-step planning budget' ]; then
  echo "unexpected zombie-guard inventory task summary: $task_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.analysis_reason,
      .selection.selected_title,
      .gating.zombie_filtered_count,
      .gating.non_retryable_filtered_count,
      .gating.title_family_filtered_count
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1\tzombie_guard\tInventory current decision path for cap pre-step planning budget\t2\t0\t0' ]; then
  echo "unexpected zombie-guard dominant reason artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve zombie guard dominant reason test passed"
