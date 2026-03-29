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
      "id": "task-002-classify-retries",
      "title": "Improve retry failure classification coverage",
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
  "success_rate": 0.48,
  "recent_success_rate": 0.5,
  "first_pass_success_rate": 0.53,
  "timeout_failure_rate": 0.02,
  "zero_step_timeout_rate": 0.0,
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
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T09:00:00Z",
  "total_tasks": 200
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_count="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 4 ]; then
  echo "expected stale pipeline recovery to bypass the active self-improve cap" >&2
  exit 1
fi

latest_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | sort_by(.id)
    | last
    | .title
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$latest_title" != "Recover stale pipeline" ]; then
  echo "expected stale-pipeline recovery task to be created despite active cap" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.submission_reason,
      .gating.backlog_bypass_active
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1\tdefault_limit\ttrue' ]; then
  echo "unexpected stale-pipeline bypass artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve stale pipeline cap bypass test passed"
