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

mkdir -p "$REPO_ROOT"
cp -R "$ROOT_DIR/scripts" "$REPO_ROOT/scripts"
mkdir -p "$REPO_ROOT/codex-memory" "$REPO_ROOT/codex-learning" "$REPO_ROOT/codex-logs" "$REPO_ROOT/queues" "$REPO_ROOT/projects/codex-agent-system" "$REPO_ROOT/projects/superheld"
mkdir -p "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-local",
      "title": "Local pending task",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z"
    }
  ]
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-remote",
      "title": "Remote approved task",
      "project": "superheld",
      "status": "approved",
      "created_at": "2026-03-24T08:05:00Z",
      "updated_at": "2026-03-24T08:05:00Z",
      "approved_at": "2026-03-24T08:05:00Z"
    }
  ]
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"

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

LOCAL_BYTES="$(wc -c <"$REPO_ROOT/codex-memory/tasks.json" | tr -d ' ')"
TOTAL_BYTES="$(
  python3 - "$REPO_ROOT/codex-memory/tasks.json" "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
import os
import sys

print(sum(os.path.getsize(path) for path in sys.argv[1:]))
PY
)"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<EOF
{
  "success_rate": 0.12,
  "recent_success_rate": 0.08,
  "timeout_failure_rate": 0.11,
  "first_pass_success_rate": 0.64,
  "approved_tasks": 0,
  "pending_approval_tasks": 1,
  "approved_backlog": 0,
  "task_registry_pressure_bytes": $TOTAL_BYTES,
  "shared_registry_bytes": $TOTAL_BYTES,
  "local_registry_bytes": $TOTAL_BYTES,
  "registry_pressure_scope": "none",
  "registry_pressure_dominant_source": {
    "project": "superheld",
    "file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json",
    "payload_bytes": $(wc -c <"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" | tr -d ' ')
  },
  "registry_pressure_local_source": {
    "project": "codex-agent-system",
    "file": "$REPO_ROOT/codex-memory/tasks.json",
    "payload_bytes": $LOCAL_BYTES
  },
  "strategy_saturation": false,
  "self_improve_paused": false,
  "self_improve_pause_escalated": false,
  "self_improve_pause_age_seconds": 0,
  "retry_churn_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 2
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

artifact_summary="$(
  jq -r '
    [
      .metrics_input.status,
      .metrics_input.refresh_performed,
      .metrics_input.reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"

if [ "$artifact_summary" != $'refreshed\ttrue\tregistry_source_mismatch' ]; then
  echo "unexpected self-improve registry-source mismatch summary: $artifact_summary" >&2
  exit 1
fi

metrics_summary="$(
  jq -r '
    [
      .local_registry_bytes,
      .registry_pressure_local_source.payload_bytes
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/metrics.json"
)"

if [ "$metrics_summary" != "$LOCAL_BYTES"$'\t'"$LOCAL_BYTES" ]; then
  echo "expected refreshed local registry bytes to match local source payload: $metrics_summary" >&2
  exit 1
fi

echo "self improve registry source mismatch refresh test passed"
