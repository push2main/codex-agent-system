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
      "id": "task-001-completed",
      "title": "Completed fixture task",
      "project": "codex-agent-system",
      "status": "completed",
      "score": 8,
      "updated_at": "2026-03-25T05:10:00Z",
      "execution": {
        "state": "completed",
        "result": "SUCCESS",
        "attempt": 1,
        "updated_at": "2026-03-25T05:10:00Z"
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T05:10:00Z","project":"codex-agent-system","task":"Completed fixture task","task_id":"task-001-completed","result":"SUCCESS","attempts":1,"score":8}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "timeout_failure_rate": 0.22,
  "first_pass_success_rate": 0.64,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_pressure_bytes": 128000,
  "strategy_saturation": false,
  "zero_step_timeout_rate": 1.25
}
EOF

touch -t 202603250500 "$TEST_ROOT/codex-learning/metrics.json"
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

MIRROR_FILE="$TEST_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md"
mkdir -p "$(dirname "$MIRROR_FILE")"
cat >"$MIRROR_FILE" <<'EOF'
# Automation Memory

project: codex-agent-system
automation_id: push2main-codex-agent-system

- 2026-03-25T05:00:00Z | first fixture entry | external_sync_pending=false
- 2026-03-25T05:05:00Z | second fixture entry | external_sync_pending=false
- 2026-03-25T05:10:00Z | third fixture entry | external_sync_pending=false
EOF

OUTPUT_FILE="$TMP_DIR/context.json"
(
  cd "$TEST_ROOT"
  HOME="$TMP_DIR/home" bash scripts/prepare-automation-context.sh \
    codex-agent-system \
    2 >"$OUTPUT_FILE"
)

DEFAULT_EXTERNAL_FILE="$TMP_DIR/home/.codex/automations/push2main-codex-agent-system/memory.md"
[ -f "$DEFAULT_EXTERNAL_FILE" ]

jq -e \
  --arg workspace "$TEST_ROOT" \
  --arg project_memory "$TEST_ROOT/projects/codex-agent-system/memory.md" \
  --arg spec_file "$TEST_ROOT/projects/codex-agent-system/spec.md" \
  --arg policy_file "$TEST_ROOT/projects/codex-agent-system/policy.json" \
  --arg registry_file "$TEST_ROOT/codex-memory/tasks.json" \
  --arg external_file "$DEFAULT_EXTERNAL_FILE" \
  '
    .status == "success" and
    .message == "Prepared automation context." and
    .data.project.name == "codex-agent-system" and
    .data.project.automation_id == "push2main-codex-agent-system" and
    .data.project.workspace == $workspace and
    .data.files.memory_file == $project_memory and
    .data.files.spec_file == $spec_file and
    .data.files.policy_file == $policy_file and
    .data.files.task_registry_file == $registry_file and
    .data.automation_memory.exists == true and
    .data.automation_memory.memory_file == $external_file and
    .data.automation_memory.source == "external" and
    .data.automation_memory.external_hydrated == false and
    .data.automation_memory.external_sync_pending == false and
    .data.automation_memory.readable == true and
    .data.automation_memory.requested_recent_entries == 2 and
    (.data.automation_memory.recent_entries | length) == 2 and
    .data.automation_memory.recent_entries[0] == "- 2026-03-25T05:10:00Z | third fixture entry | external_sync_pending=false" and
    (.data.automation_memory.recent_entries[1] | test("^-[[:space:]][0-9]{4}-[0-9]{2}-[0-9]{2}T.*\\| weakness=.* \\| external_sync_pending=false$")) and
    .data.metrics_input.status == "refreshed" and
    .data.metrics_input.reason == "invalid_bounded_metric_zero_step_timeout_rate" and
    .data.metrics_input.refresh_performed == true and
    .data.metrics_input.missing_keys == [] and
    .data.self_improve_artifact_refresh.enabled == true and
    .data.self_improve_artifact_refresh.performed == true and
    .data.self_improve_artifact_refresh.reason == "self_improve_run_missing" and
    .data.self_improve_artifact_refresh.status == "refreshed"
  ' "$OUTPUT_FILE" >/dev/null

metrics_summary="$(
  jq -r '
    [
      .success_rate,
      .timeout_failure_rate,
      .zero_step_timeout_rate,
      .approved_tasks,
      .pending_approval_tasks
    ] | @tsv
  ' "$TEST_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'1.0\t0.0\t0\t0\t0' ]; then
  echo "expected prepare-automation-context to refresh invalid metrics before emitting context: $metrics_summary" >&2
  exit 1
fi

echo "prepare automation context test passed"
