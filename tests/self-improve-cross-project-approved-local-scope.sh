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
      "id": "task-local-completed",
      "title": "Local completed task",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "2099-01-01T05:10:00Z",
      "execution": {
        "state": "completed",
        "result": "SUCCESS",
        "attempt": 1,
        "updated_at": "2099-01-01T05:10:00Z"
      }
    }
  ]
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-remote-approved-1",
      "title": "Remote approved task 1",
      "project": "superheld",
      "status": "approved",
      "updated_at": "2099-01-01T05:11:00Z"
    },
    {
      "id": "task-remote-approved-2",
      "title": "Remote approved task 2",
      "project": "superheld",
      "status": "approved",
      "updated_at": "2099-01-01T05:12:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2099-01-01T05:00:00Z","project":"codex-agent-system","task":"Completed local task","task_id":"task-local-completed","result":"SUCCESS","attempts":1,"score":8}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 1.0,
  "timeout_failure_rate": 0.0,
  "first_pass_success_rate": 1.0,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "approved_tasks_cross_project": 2,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 3,
  "task_registry_pressure_bytes": 128000,
  "strategy_saturation": false,
  "zero_step_timeout_rate": 0.0,
  "queue_starvation_detected": false,
  "pending_approval_blocked_detected": false
}
EOF

cat >"$TEST_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2099-01-01T05:00:00Z",
  "signals": [],
  "errors": []
}
EOF

touch -t 209901010513 "$TEST_ROOT/codex-learning/metrics.json"
touch -t 209901010510 "$TEST_ROOT/codex-memory/tasks.json"
touch -t 209901010512 "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
touch -t 209901010510 "$TEST_ROOT/codex-memory/tasks.log"
touch -t 209901010510 "$TEST_ROOT/codex-learning/external-signals.json"

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

(
  cd "$TEST_ROOT"
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

summary="$(
  jq -r '
    [
      .metrics_input.status,
      .metrics_input.refresh_performed,
      .metrics_input.reason
    ] | @tsv
  ' "$TEST_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$summary" != $'complete\tfalse\tcomplete_snapshot' ]; then
  echo "unexpected self-improve cross-project approved local-scope summary: $summary" >&2
  exit 1
fi

echo "self improve cross-project approved local-scope test passed"
