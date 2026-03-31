#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"

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
  "$REPO_ROOT/projects/codex-agent-system" \
  "$REPO_ROOT/projects/superheld" \
  "$EXTERNAL_PROJECT_ROOT/.codex-agent" \
  "$EXTERNAL_PROJECT_ROOT/packages/schema"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-remote-completed",
      "title": "Remote completed task",
      "project": "superheld",
      "status": "completed",
      "created_at": "2026-03-29T21:00:00Z",
      "updated_at": "2026-03-29T21:05:00Z",
      "completed_at": "2026-03-29T21:05:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-29T21:05:00Z"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-29T21:05:00Z","project":"superheld","task":"Remote completed task","result":"SUCCESS","failure_kind":"","task_id":"task-remote-completed","attempts":1,"score":8,"run_id":"run-superheld-success"}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/packages/schema/incident.schema.json" <<'EOF'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "Incident",
  "type": "object",
  "examples": [
    {
      "incident_type": "credential_recovery_required",
      "summary": "Credential recovery example"
    }
  ]
}
EOF

cat >"$REPO_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$REPO_ROOT",
  "repo_url": "https://github.com/push2main/codex-agent-system/",
  "automation_id": "push2main-codex-agent-system",
  "memory_file": "$REPO_ROOT/projects/codex-agent-system/memory.md",
  "spec_file": "$REPO_ROOT/projects/codex-agent-system/spec.md",
  "policy_file": "$REPO_ROOT/projects/codex-agent-system/policy.json",
  "task_registry_file": "$REPO_ROOT/codex-memory/tasks.json"
}
EOF

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
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

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.10,
  "timeout_failure_rate": 0.11,
  "first_pass_success_rate": 0.64,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "approved_backlog": 0,
  "task_registry_total": 19,
  "task_registry_pressure_bytes": 4096,
  "strategy_saturation": false,
  "retry_churn_detected": false,
  "self_improve_paused": false,
  "self_improve_pause_escalated": false,
  "self_improve_pause_age_seconds": 0,
  "external_signal_status": "fresh",
  "total_tasks": 19
}
EOF

cat >"$REPO_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-29T21:10:00Z",
  "signals": [
    {
      "source_id": "fixture",
      "title": "Fresh signal",
      "published_at": "2026-03-29T21:05:00Z",
      "fresh": true
    }
  ],
  "errors": []
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh superheld >/dev/null
)

metrics_summary="$(
  jq -r '
    [
      .task_registry_total,
      .total_tasks
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/metrics.json"
)"
if [ "$metrics_summary" != $'19\t19' ]; then
  echo "expected shared metrics to remain unchanged for external project fallback: $metrics_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .metrics_input.status,
      .metrics_input.refresh_performed,
      .metrics_input.reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'complete\tfalse\texternal_shared_metrics_fallback' ]; then
  echo "unexpected external shared metrics fallback summary: $artifact_summary" >&2
  exit 1
fi

if rg -q '\[validate-metrics\] DRIFT DETECTED|Refreshed persisted metrics before analysis|Command failed at line' "$REPO_ROOT/codex-logs/system.log"; then
  echo "expected external shared metrics fallback to avoid refresh/drift noise" >&2
  exit 1
fi

echo "self improve external shared metrics fallback test passed"
