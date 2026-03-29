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
      "id": "task-001-cap-pre-step-planning-budget",
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
  "retry_classification_coverage": 0.82,
  "retry_classified_count": 41,
  "retry_total_count": 50,
  "approved_tasks": 12,
  "approved_backlog": 12,
  "pending_approval_tasks": 1,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": true,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 70,
  "loop_effort_extra_step_attempts": 163,
  "external_signal_status": "fresh",
  "total_tasks": 240
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

pending_titles="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | map(.title)
    | sort
    | join("\n")
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$pending_titles" != $'Break retry churn\nCap pre-step planning budget' ]; then
  echo "expected active planning-budget remediation to suppress generic timeout regeneration: $pending_titles" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .counts.generated,
      .counts.submitted,
      .gating.overload.preserved_title
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'1\t1\tBreak retry churn' ]; then
  echo "unexpected artifact summary when planning-budget task suppresses generic timeout: $artifact_summary" >&2
  exit 1
fi

echo "self improve active planning-budget suppression test passed"
