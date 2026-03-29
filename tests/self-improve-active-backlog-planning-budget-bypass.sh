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
      "id": "task-003-improve-first-pass",
      "title": "Improve first-pass success rate",
      "project": "codex-agent-system",
      "status": "queued",
      "updated_at": "2026-03-25T10:10:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-004-timeout-rate",
      "title": "Reduce timeout rate",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T10:15:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.16,
  "first_pass_success_rate": 0.84,
  "timeout_failure_rate": 0.18,
  "zero_step_timeout_rate": 0.93,
  "retry_classification_coverage": 0.82,
  "retry_classified_count": 41,
  "retry_total_count": 50,
  "approved_tasks": 1,
  "pending_approval_tasks": 3,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 240
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | [length, (last | .title // "")]
    | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_summary" != $'5\tCap pre-step planning budget' ]; then
  echo "expected planning-budget emergency fallback to bypass the active self-improve backlog cap: $task_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.submission_reason
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'2\t1\tcritical_low_success_rate' ]; then
  echo "unexpected planning-budget emergency bypass artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve active backlog planning budget bypass test passed"
