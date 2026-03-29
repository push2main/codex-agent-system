#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects/codex-agent-system" "$TEST_ROOT/projects/superheld"
mkdir -p "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-local-pending",
      "title": "Local pending task",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T05:10:00Z"
    }
  ]
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-remote-pending",
      "title": "Remote pending task",
      "project": "superheld",
      "status": "pending_approval",
      "updated_at": "2026-03-25T05:11:00Z"
    },
    {
      "id": "task-remote-queued",
      "title": "Remote queued task",
      "project": "superheld",
      "status": "queued",
      "updated_at": "2026-03-25T05:12:00Z"
    },
    {
      "id": "task-remote-running",
      "title": "Remote running task",
      "project": "superheld",
      "status": "running",
      "updated_at": "2026-03-25T05:13:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T05:00:00Z","project":"codex-agent-system","task":"Completed local task","task_id":"task-local-completed","result":"SUCCESS","attempts":1,"score":8}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 1.0,
  "timeout_failure_rate": 0.0,
  "first_pass_success_rate": 1.0,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "approved_tasks_cross_project": 0,
  "pending_approval_tasks": 1,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 4,
  "task_registry_pressure_bytes": 128000,
  "strategy_saturation": false,
  "zero_step_timeout_rate": 0.0
}
EOF

touch -t 202603250514 "$TEST_ROOT/codex-learning/metrics.json"
touch -t 202603250510 "$TEST_ROOT/codex-memory/tasks.json"
touch -t 202603250513 "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
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

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_PROJECT_ROOT",
  "repo_url": "https://github.com/push2main/superheld",
  "memory_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
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
  .data.metrics_input.status == "complete" and
  .data.metrics_input.reason == "complete_snapshot" and
  .data.metrics_input.refresh_performed == false and
  .data.metrics_input.missing_keys == [] and
  .data.project_health.scope == "project_local" and
  .data.project_health.approved_tasks == 0 and
  .data.project_health.pending_approval_tasks == 1
' "$OUTPUT_FILE" >/dev/null

metrics_summary="$(
  jq -r '
    [
      .approved_tasks,
      .pending_approval_tasks,
      .queued_tasks,
      .running_tasks,
      .task_registry_total
    ] | @tsv
  ' "$TEST_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'0\t1\t0\t0\t4' ]; then
  echo "expected prepare-automation-context to keep local runtime counts stable: $metrics_summary" >&2
  exit 1
fi

echo "prepare automation context cross-project runtime local-scope test passed"
