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

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-28T04:05:31Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by recent_self_improve_failure_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"unknown_persistent","total_step_attempts":2}
{"timestamp":"2026-03-28T04:07:21Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by recent_self_improve_failure_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"unknown_persistent","total_step_attempts":2}
{"timestamp":"2026-03-28T04:20:20Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by saturated_family_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"review_rejection","total_step_attempts":2}
{"timestamp":"2026-03-28T04:22:32Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by saturated_family_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"review_rejection","total_step_attempts":2}
{"timestamp":"2026-03-28T04:50:04Z","project":"codex-agent-system","task":"[self-improve:critical] Inventory current decision path for recover stale pipeline -- Direct retries for recover stale pipeline are currently paused by saturated_family_cooldown while the live weakness signal is still active.","result":"FAILURE","failure_kind":"empty_output","total_step_attempts":2}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.0,
  "first_pass_success_rate": 0.0,
  "timeout_failure_rate": 0.36,
  "zero_step_timeout_rate": 0.91,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 98,
  "retry_total_count": 98,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": true,
  "pending_approval_blocked_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "loop_effort_detected": true,
  "loop_effort_task_count": 3,
  "loop_effort_extra_step_attempts": 3,
  "diagnostic_coverage": 1.0,
  "failures_with_diagnostic": 5,
  "total_failure_records": 5,
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

blocked_family_count="$(
  jq '
    [
      .tasks[]
      | select((.title // .execution_task // "") | ascii_downcase | contains("inventory current decision path for recover stale pipeline"))
    ] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${blocked_family_count:-0}" -ne 0 ]; then
  echo "expected zombie inventory family to stay blocked, got blocked family count: $blocked_family_count" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .selection.selected_title,
      (.selection.ranked_titles | join("|"))
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
case "$artifact_summary" in
  $'2\t1\tImprove first-pass success rate\tImprove first-pass success rate|Refresh stale external signals'|\
  $'1\t1\tRefresh stale external signals\tRefresh stale external signals'|\
  $'1\t1\tImprove first-pass success rate\tImprove first-pass success rate')
    ;;
  *)
  echo "unexpected zombie inventory artifact summary: $artifact_summary" >&2
  exit 1
    ;;
esac

echo "self improve zombie inventory family block test passed"
