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
  "tasks": []
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"
for index in $(seq 1 20); do
  printf '{"timestamp":"2026-03-24T10:%02d:00Z","project":"codex-agent-system","task":"Local timeout %02d","result":"FAILURE","failure_kind":"timeout","failed_step":"","task_id":"local-%03d","attempts":1,"total_step_attempts":0,"score":0,"run_id":"run-local-%02d"}\n' \
    "$index" "$index" "$index" "$index" >>"$REPO_ROOT/codex-memory/tasks.log"
done
cat >>"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-24T11:00:00Z","project":"codex-agent-system","task":"Local success","result":"SUCCESS","failure_kind":"","failed_step":"","task_id":"local-021","attempts":1,"total_step_attempts":1,"score":7,"run_id":"run-local-21"}
{"timestamp":"2026-03-24T12:00:00Z","project":"superheld","task":"Remote failure with diagnostic","result":"FAILURE","failure_kind":"timeout","failed_step":"Inspect timeout handling","task_id":"remote-001","attempts":1,"total_step_attempts":0,"score":0,"run_id":"run-remote-1"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.52,
  "recent_success_rate": 0.6,
  "timeout_failure_rate": 0.12,
  "first_pass_success_rate": 0.82,
  "retry_classification_coverage": 0.87,
  "retry_classified_count": 54,
  "retry_total_count": 62,
  "diagnostic_coverage": 0.75,
  "recent_diagnostic_coverage": 0.8,
  "failures_with_diagnostic": 75,
  "total_failure_records": 100,
  "retry_churn_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "strategy_saturation_detected": false,
  "saturated_failed_tasks": 0,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_total": 0,
  "task_registry_payload_bytes": 2048,
  "task_registry_pressure_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 108
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | map(.title)
    | join("\n")
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_summary" != "Improve timeout diagnostic coverage" ]; then
  echo "expected project-local timeout diagnostics to outrank global aggregate metrics: $task_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .metrics_snapshot.success_rate,
      .metrics_snapshot.timeout_rate,
      .metrics_snapshot.zero_step_timeout_rate,
      .metrics_snapshot.diagnostic_coverage,
      .metrics_snapshot.recent_diagnostic_coverage,
      .metrics_snapshot.failures_with_diagnostic,
      .metrics_snapshot.total_failure_records,
      .metrics_snapshot.total_tasks
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'0.05\t0.95\t1\t0\t0\t0\t20\t21' ] && [ "$artifact_summary" != $'0.05\t0.95\t1.0\t0.0\t0.0\t0\t20\t21' ]; then
  echo "unexpected project-local timeout diagnostic metrics snapshot: $artifact_summary" >&2
  exit 1
fi

echo "self improve project-local timeout diagnostics test passed"
