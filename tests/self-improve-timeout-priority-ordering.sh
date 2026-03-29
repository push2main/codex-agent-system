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
  "zero_step_timeout_rate": 0.92,
  "retry_classification_coverage": 0.24,
  "retry_classified_count": 15,
  "retry_total_count": 62,
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
  echo "expected low-success submission limit to keep exactly one submitted self-improve task" >&2
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
if [ "$task_title" != "Reduce timeout rate" ]; then
  echo "expected critical zero-step timeout pressure to outrank retry-classification work outside backlog overload" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.overload.active,
      .metrics_snapshot.zero_step_timeout_rate
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'2\t1\tfalse\t0.92' ]; then
  echo "unexpected self-improve ordering artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve timeout priority ordering test passed"
