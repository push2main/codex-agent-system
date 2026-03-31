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
      "id": "task-001-break-retry-churn",
      "title": "Break retry churn",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T10:00:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-queue-starvation-audit",
      "title": "Audit queue starvation signal",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T10:05:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-003-reduce-registry-pressure",
      "title": "Reduce registry pressure",
      "project": "codex-agent-system",
      "status": "queued",
      "updated_at": "2026-03-25T10:10:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "recent_success_rate": 0.14,
  "first_pass_success_rate": 0.38,
  "timeout_failure_rate": 0.04,
  "zero_step_timeout_rate": 0.10,
  "retry_classification_coverage": 0.88,
  "retry_classified_count": 22,
  "retry_total_count": 25,
  "approved_tasks": 1,
  "pending_approval_tasks": 2,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 200
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 3 ]; then
  echo "expected active self-improve backlog cap to prevent creating another task" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.submitted,
      .gating.submission_reason,
      .gating.dominant_reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'0\tactive_self_improve_backlog\tsubmission_limit' ]; then
  echo "unexpected active-backlog cap artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve active backlog cap test passed"
