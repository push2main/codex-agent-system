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
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.17,
  "zero_step_timeout_rate": 0.94,
  "retry_classification_coverage": 0.87,
  "retry_classified_count": 54,
  "retry_total_count": 62,
  "diagnostic_coverage": 0.21,
  "recent_diagnostic_coverage": 0.30,
  "failures_with_diagnostic": 91,
  "total_failure_records": 443,
  "approved_tasks": 2,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 476
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected critical low success to submit exactly one self-improve task" >&2
  exit 1
fi

task_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | first
    | .title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_title" != "Improve timeout diagnostic coverage" ]; then
  echo "expected low diagnostic coverage under zero-step timeout emergency to outrank generic timeout reduction" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.overload.active,
      .metrics_snapshot.zero_step_timeout_rate,
      .metrics_snapshot.diagnostic_coverage
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'3\t1\tfalse\t0.94\t0.21' ]; then
  echo "unexpected timeout diagnostic coverage artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve timeout diagnostic coverage priority test passed"
