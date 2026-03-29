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
      "id": "task-001-recover-stale-pipeline",
      "title": "Recover stale pipeline",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T10:00:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-002-reduce-timeout-rate",
      "title": "Reduce timeout rate",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T10:05:00Z",
      "task_intent": {
        "source": "self-improve"
      }
    },
    {
      "id": "task-003-cap-pre-step-planning-budget",
      "title": "Cap pre-step planning budget",
      "project": "codex-agent-system",
      "status": "pending_approval",
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
  "success_rate": 0.14,
  "recent_success_rate": 0.14,
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.33,
  "zero_step_timeout_rate": 0.94,
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T09:00:00Z",
  "retry_classification_coverage": 0.82,
  "retry_classified_count": 41,
  "retry_total_count": 50,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 3,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": true,
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

retired_timeout_summary="$(
  jq -r '
    .tasks
    | map(select(.id == "task-002-reduce-timeout-rate"))
    | first
    | [
        (.status // ""),
        (.shelved_reason // ""),
        (.history[-1].action // ""),
        (.history[-1].note // "")
      ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [[ "$retired_timeout_summary" != $'shelved\tauto-shelved: narrower `Cap pre-step planning budget` task is already active for the same zero-step timeout emergency\tauto_shelve\tTask was automatically retired because a narrower active self-improve task already covers the same zero-step timeout emergency: narrower `Cap pre-step planning budget` task is already active for the same zero-step timeout emergency.' ]]; then
  echo "expected generic timeout task to be auto-shelved once the planning-budget successor is already active: $retired_timeout_summary" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.submitted,
      .gating.submission_reason,
      .gating.retired_resolved_pending_tasks
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\tcritical_low_success_rate\t1' ]; then
  echo "expected retirement to free one active self-improve slot without tripping the active backlog cap: $artifact_summary" >&2
  exit 1
fi

echo "self improve superseded timeout pending retirement test passed"
