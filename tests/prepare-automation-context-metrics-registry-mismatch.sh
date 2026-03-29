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
  "tasks": [
    {
      "id": "task-001-approved",
      "title": "Approved fixture task",
      "project": "codex-agent-system",
      "status": "approved",
      "score": 8,
      "updated_at": "2099-01-01T05:10:00Z"
    },
    {
      "id": "task-002-pending",
      "title": "Pending fixture task",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 5,
      "updated_at": "2099-01-01T05:11:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2099-01-01T05:00:00Z","project":"codex-agent-system","task":"Completed fixture task","task_id":"task-000-completed","result":"SUCCESS","attempts":1,"score":8}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 1.0,
  "timeout_failure_rate": 0.0,
  "first_pass_success_rate": 1.0,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 0,
  "task_registry_pressure_bytes": 128000,
  "strategy_saturation": false,
  "zero_step_timeout_rate": 0.0
}
EOF

touch -t 202603250510 "$TEST_ROOT/codex-learning/metrics.json"
touch -t 202603250510 "$TEST_ROOT/codex-memory/tasks.json"
touch -t 202603250510 "$TEST_ROOT/codex-memory/tasks.log"

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

jq -e '
  .status == "success" and
  .data.metrics_input.status == "refreshed" and
  .data.metrics_input.reason == "registry_count_mismatch" and
  .data.metrics_input.refresh_performed == true and
  .data.metrics_input.missing_keys == []
' "$OUTPUT_FILE" >/dev/null

metrics_summary="$(
  jq -r '
    [
      .approved_tasks,
      .pending_approval_tasks,
      .approved_backlog,
      .task_registry_total
    ] | @tsv
  ' "$TEST_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'1\t1\t1\t2' ]; then
  echo "expected prepare-automation-context to refresh registry-mismatched metrics: $metrics_summary" >&2
  exit 1
fi

echo "prepare automation context registry mismatch test passed"
