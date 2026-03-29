#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root"
  cp -R "$ROOT_DIR/scripts" "$repo_root/scripts"
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-retrying-with-loop-effort",
      "title": "Retrying task with persisted loop-effort evidence",
      "project": "codex-agent-system",
      "status": "running",
      "updated_at": "2026-03-28T07:00:00Z",
      "execution": {
        "state": "retrying",
        "attempt": 2,
        "total_step_attempts": 5,
        "max_retries": 2,
        "provider": "codex",
        "updated_at": "2026-03-28T07:00:00Z"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.92,
  "recent_success_rate": 0.92,
  "first_pass_success_rate": 0.86,
  "retry_success_rate": 0.91,
  "timeout_failure_rate": 0.01,
  "timeout_rate": 0.01,
  "zero_step_timeout_rate": 0.00,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 1,
  "task_registry_payload_bytes": 2048,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "fresh_external_signal_count": 1,
  "total_tasks": 12
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

pending_retry_churn_count="$(
  jq '
    [
      .tasks[]
      | select((.task_intent.source // "") == "self-improve")
      | select((.title // "") == "Break retry churn")
      | select((.status // "") == "pending_approval")
    ] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${pending_retry_churn_count:-0}" -ne 1 ]; then
  echo "expected retry-churn improvement when persisted loop-effort evidence exists" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.submitted,
      .selection.selected_title
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\tBreak retry churn' ]; then
  echo "expected Break retry churn to be selected with persisted loop-effort evidence: $artifact_summary" >&2
  exit 1
fi

echo "self improve retry churn positive loop effort test passed"
