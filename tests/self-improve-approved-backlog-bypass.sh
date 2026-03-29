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
      "id": "task-000-approved-backlog-01",
      "title": "Approved backlog task 1",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-02",
      "title": "Approved backlog task 2",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-03",
      "title": "Approved backlog task 3",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-04",
      "title": "Approved backlog task 4",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-05",
      "title": "Approved backlog task 5",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-06",
      "title": "Approved backlog task 6",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-07",
      "title": "Approved backlog task 7",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-08",
      "title": "Approved backlog task 8",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-09",
      "title": "Approved backlog task 9",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-10",
      "title": "Approved backlog task 10",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-11",
      "title": "Approved backlog task 11",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
    {
      "id": "task-000-approved-backlog-12",
      "title": "Approved backlog task 12",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-25T09:00:00Z"
    },
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
  "success_rate": 0.35,
  "recent_success_rate": 0.38,
  "first_pass_success_rate": 0.62,
  "timeout_failure_rate": 0.03,
  "zero_step_timeout_rate": 0.0,
  "retry_classification_coverage": 0.88,
  "retry_classified_count": 22,
  "retry_total_count": 25,
  "approved_tasks": 12,
  "approved_backlog": 12,
  "pending_approval_tasks": 1,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "queue_starvation_detected": true,
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
if [ "${task_count:-0}" -ne 4 ]; then
  echo "expected approved-backlog drain task to bypass the active self-improve cap" >&2
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
if [ "$latest_title" != "Drain approval backlog" ]; then
  echo "expected approval-backlog task to be created when approved work is starved" >&2
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
  echo "unexpected approved-backlog bypass artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve approved backlog bypass test passed"
