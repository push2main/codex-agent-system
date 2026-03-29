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
  "success_rate": 0.15,
  "first_pass_success_rate": 0.58,
  "timeout_failure_rate": 0.35,
  "approved_tasks": 28,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 1155796,
  "task_registry_pressure_detected": true,
  "retry_churn_detected": true,
  "strategy_saturation_detected": false,
  "retry_classification_coverage": 0.24,
  "retry_classified_count": 15,
  "retry_total_count": 62,
  "loop_effort_task_count": 71,
  "loop_effort_extra_step_attempts": 172,
  "external_signal_status": "fresh",
  "total_tasks": 508,
  "recent_success_rate": 0.32
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
    | [.title // "", .reason // ""] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
expected_task_summary=$'Improve retry failure classification coverage\tOnly 24% of retry failures are classified (15/62); broaden deterministic failure capture before tuning broader retry behavior by enriching reviewer/evaluator context in orchestrator.sh and extending classify_failure patterns.'
if [ "$task_summary" != "$expected_task_summary" ]; then
  echo "unexpected critical retry-classification self-improve task: $task_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .gating.overload.active,
      .gating.overload.preserved_title,
      .gating.overload.preserved_reason,
      (.gating.overload.candidates | map(select(.title == "Improve retry failure classification coverage")) | first | .score),
      (.gating.overload.candidates | map(select(.title == "Reduce timeout rate")) | first | .score)
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'true\tImprove retry failure classification coverage\thighest_unblocked_score\t72\t70' ]; then
  echo "unexpected critical retry-classification overload summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve critical retry classification priority test passed"
