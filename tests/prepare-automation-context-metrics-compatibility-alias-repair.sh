#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
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

cat >"$TEST_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$TEST_ROOT",
  "repo_url": "https://github.com/push2main/codex-agent-system/",
  "automation_id": "push2main-codex-agent-system",
  "memory_file": "$TEST_ROOT/projects/codex-agent-system/memory.md",
  "spec_file": "$TEST_ROOT/projects/codex-agent-system/spec.md",
  "policy_file": "$TEST_ROOT/projects/codex-agent-system/policy.json",
  "task_registry_file": "$TEST_ROOT/codex-memory/tasks.json"
}
EOF

OUTPUT_FILE="$TMP_DIR/context.json"
(
  cd "$TEST_ROOT"
  HOME="$TMP_DIR/home" bash scripts/prepare-automation-context.sh \
    codex-agent-system \
    2 >"$OUTPUT_FILE"
)

artifact_summary="$(
  jq -r '
    [
      .status,
      .data.metrics_input.status,
      .data.metrics_input.refresh_performed,
      .data.metrics_input.reason,
      (.data.metrics_input.missing_keys | join(","))
    ] | @tsv
  ' "$OUTPUT_FILE"
)"

if [ "$artifact_summary" != $'success\trefreshed\ttrue\tmissing_required_keys\t' ]; then
  echo "unexpected prepare-automation-context alias-repair summary: $artifact_summary" >&2
  exit 1
fi

metrics_summary="$(
  jq -r '
    [
      .approved_backlog,
      .task_registry_pressure_bytes,
      .strategy_saturation
    ] | @tsv
  ' "$TEST_ROOT/codex-learning/metrics.json"
)"

if [ "$metrics_summary" != $'0\t128000\tfalse' ]; then
  echo "expected compatibility aliases to be repaired in metrics.json: $metrics_summary" >&2
  exit 1
fi

echo "prepare automation context metrics compatibility alias repair test passed"
