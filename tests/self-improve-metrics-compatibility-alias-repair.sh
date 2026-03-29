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

: >"$REPO_ROOT/codex-memory/tasks.log"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.11,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 100
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

artifact_summary="$(
  jq -r '
    [
      .counts.detected,
      .counts.generated,
      .counts.submitted,
      .metrics_snapshot.success_rate,
      .metrics_input.status,
      .metrics_input.refresh_performed,
      .metrics_input.reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "$artifact_summary" != $'2\t2\t1\t0.12\trefreshed\ttrue\tmissing_required_keys' ]; then
  echo "unexpected self-improve alias-repair artifact summary: $artifact_summary" >&2
  exit 1
fi

metrics_summary="$(
  jq -r '
    [
      .approved_backlog,
      .task_registry_pressure_bytes,
      .strategy_saturation
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/metrics.json"
)"

if [ "$metrics_summary" != $'0\t128000\tfalse' ]; then
  echo "expected compatibility aliases to be repaired in metrics.json: $metrics_summary" >&2
  exit 1
fi

echo "self improve metrics compatibility alias repair test passed"
