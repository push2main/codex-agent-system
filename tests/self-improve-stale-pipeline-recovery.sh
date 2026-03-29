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
  "success_rate": 0.61,
  "recent_success_rate": 0.58,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.01,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 0.91,
  "retry_classified_count": 10,
  "retry_total_count": 11,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T10:15:00Z",
  "total_tasks": 48
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | first
    | [
        .title,
        .status,
        (.task_intent.objective // ""),
        (.execution_task // "")
      ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [[ "$task_summary" != $'Recover stale pipeline\tpending_approval\tRecover stale pipeline\t[self-improve:critical] Recover stale pipeline'* ]]; then
  echo "unexpected stale-pipeline task summary: $task_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.submission_reason,
      .metrics_snapshot.pipeline_stale,
      .metrics_snapshot.pipeline_stale_since
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1\tdefault_limit\ttrue\t2026-03-25T10:15:00Z' ]; then
  echo "unexpected stale-pipeline artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve stale pipeline recovery test passed"
