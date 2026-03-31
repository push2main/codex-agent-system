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
  "tasks": [
    {
      "id": "task-001-running-product-work",
      "title": "Implement family alert banner",
      "project": "superheld",
      "status": "running",
      "updated_at": "2026-03-30T00:00:00Z"
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.14,
  "first_pass_success_rate": 0.75,
  "timeout_failure_rate": 0.19,
  "zero_step_timeout_rate": 0.95,
  "retry_classification_coverage": 0.9,
  "retry_classified_count": 9,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 1,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 25
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

date +%s >"$REPO_ROOT/codex-logs/self-improve-superheld-cooldown"

(
  cd "$REPO_ROOT"
  REGISTRY_FILE="$REPO_ROOT/codex-memory/tasks.json" \
  IMPROVEMENT_COOLDOWN_SECONDS=3600 \
  bash scripts/self-improve.sh superheld >/dev/null
)

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.dominant_reason,
      .gating.analysis_reason,
      .metrics_snapshot.running_tasks
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "$artifact_summary" != $'0\t0\tcooldown_active\tcooldown_active\t1' ]; then
  echo "expected active project execution to block the zero-step timeout cooldown bypass, got: $artifact_summary" >&2
  exit 1
fi

pending_count="$(
  jq '[.tasks[] | select(.status == "pending_approval")] | length' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if [ "${pending_count:-0}" != "0" ]; then
  echo "expected cooldown path to avoid generating new superheld tasks while product work is already running, got: $pending_count" >&2
  exit 1
fi

echo "self improve active project execution blocks emergency bypass test passed"
