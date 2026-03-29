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
      "id": "local-success-1",
      "title": "Local success one",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "2026-03-25T05:10:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "result": "SUCCESS",
        "updated_at": "2026-03-25T05:10:00Z"
      }
    },
    {
      "id": "local-success-2",
      "title": "Local success two",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "2026-03-25T05:15:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "result": "SUCCESS",
        "updated_at": "2026-03-25T05:15:00Z"
      }
    },
    {
      "id": "local-approved",
      "title": "Local approved task",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T05:20:00Z"
    },
    {
      "id": "global-approved-without-project",
      "title": "Unscoped approved task",
      "status": "approved",
      "updated_at": "2026-03-25T05:21:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T05:10:00Z","project":"codex-agent-system","task":"Local success one","task_id":"local-success-1","result":"SUCCESS","attempts":1,"score":8,"total_step_attempts":2}
{"timestamp":"2026-03-25T05:15:00Z","project":"codex-agent-system","task":"Local success two","task_id":"local-success-2","result":"SUCCESS","attempts":1,"score":7,"total_step_attempts":2}
{"timestamp":"2026-03-25T05:18:00Z","project":"superheld","task":"Remote timeout one","task_id":"remote-timeout-1","result":"FAILURE","failure_kind":"timeout","attempts":2,"score":0,"total_step_attempts":0}
{"timestamp":"2026-03-25T05:19:00Z","project":"superheld","task":"Remote timeout two","task_id":"remote-timeout-2","result":"FAILURE","failure_kind":"timeout","attempts":2,"score":0,"total_step_attempts":0}
{"timestamp":"2026-03-25T05:21:00Z","task":"Unscoped failure","task_id":"global-failure-1","result":"FAILURE","failure_kind":"timeout","attempts":1,"score":0,"total_step_attempts":0}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.2,
  "timeout_failure_rate": 0.4,
  "first_pass_success_rate": 0.64,
  "approved_tasks": 4,
  "pending_approval_tasks": 2,
  "approved_backlog": 4,
  "task_registry_pressure_bytes": 128000,
  "strategy_saturation": false,
  "zero_step_timeout_rate": 1.0
}
EOF

touch -t 202603250530 "$TEST_ROOT/codex-learning/metrics.json"
touch -t 202603250520 "$TEST_ROOT/codex-memory/tasks.json"
touch -t 202603250520 "$TEST_ROOT/codex-memory/tasks.log"

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
  .data.project_health.scope == "project_local" and
  .data.project_health.total_tasks == 2 and
  .data.project_health.success_rate == 1 and
  .data.project_health.recent_success_rate == 1 and
  .data.project_health.timeout_failure_rate == 0 and
  .data.project_health.zero_step_timeout_rate == 0 and
  .data.project_health.first_pass_success_rate == 1 and
  .data.project_health.approved_tasks == 1 and
  .data.project_health.pending_approval_tasks >= 1 and
  .data.self_improve_artifact_refresh.enabled == true and
  .data.self_improve_artifact_refresh.performed == true and
  .data.self_improve_artifact_refresh.reason == "self_improve_run_missing" and
  .data.self_improve_artifact_refresh.status == "refreshed"
' "$OUTPUT_FILE" >/dev/null

echo "prepare automation context project-local health test passed"
