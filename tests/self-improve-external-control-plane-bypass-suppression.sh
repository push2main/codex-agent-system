#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
EXTERNAL_WORKSPACE="$TMP_DIR/superheld-repo"

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
  "$REPO_ROOT/projects/superheld" \
  "$EXTERNAL_WORKSPACE/.codex-agent"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.18,
  "recent_success_rate": 0.22,
  "first_pass_success_rate": 0.81,
  "timeout_failure_rate": 0.11,
  "zero_step_timeout_rate": 0.95,
  "retry_classification_coverage": 1.0,
  "retry_classified_count": 10,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 0,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": true,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 24
}
EOF

touch "$REPO_ROOT/codex-memory/tasks.log"
touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$EXTERNAL_WORKSPACE/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_WORKSPACE/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_WORKSPACE/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
}
EOF

cat >"$REPO_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "superheld",
  "selected_improvement": "",
  "counts": {
    "detected": 3,
    "generated": 0,
    "submitted": 0,
    "skipped": 0,
    "blocked_analysis": 3
  },
  "gating": {
    "dominant_reason": "external_control_plane_task",
    "analysis_reason": "external_control_plane_task",
    "submission_reason": "none"
  }
}
EOF

date +%s >"$REPO_ROOT/codex-logs/self-improve-superheld-cooldown"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=600 \
  bash scripts/self-improve.sh superheld >/dev/null
)

artifact_summary="$(
  jq -r '
    [
      .gating.dominant_reason,
      .gating.analysis_reason,
      .counts.generated,
      .counts.submitted
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "$artifact_summary" != $'cooldown_active\tcooldown_active\t0\t0' ]; then
  echo "expected previous external-control-plane-only run to suppress emergency bypass, got: $artifact_summary" >&2
  exit 1
fi

pending_count="$(
  jq '[.tasks[] | select(.status == "pending_approval")] | length' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if [ "${pending_count:-0}" != "0" ]; then
  echo "expected cooldown suppression path to avoid generating new superheld tasks, got: $pending_count" >&2
  exit 1
fi

echo "self improve external control plane bypass suppression test passed"
