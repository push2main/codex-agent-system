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
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects/codex-agent-system/automation-memory"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$REPO_ROOT",
  "task_registry_file": "$REPO_ROOT/codex-memory/tasks.json",
  "automation_id": "push2main-codex-agent-system"
}
EOF

cat >"$REPO_ROOT/projects/codex-agent-system/automation-memory/push2main-codex-agent-system.md" <<'EOF'
# Automation Memory

project: codex-agent-system
automation_id: push2main-codex-agent-system

- 2026-03-25T15:18:30Z | weakness=self_improve_priority_ordering | improvement=rank_non_overload_improvements_by_existing_signal_and_priority_scores_and_add_regression | outcome=success | next=Reduce registry pressure | external_sync_pending=false
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.17,
  "zero_step_timeout_rate": 0.92,
  "retry_classification_coverage": 0.8,
  "retry_classified_count": 8,
  "retry_total_count": 10,
  "approved_tasks": 2,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 620000,
  "task_registry_pressure_detected": true,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 476
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

(
  cd "$REPO_ROOT"
  HOME="$TMP_DIR/home" IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

submitted_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.status // "") == "pending_approval"))
    | first
    | .title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"

if [ "$submitted_title" != "Reduce timeout rate" ]; then
  echo "expected higher-priority timeout remediation to ignore lower-priority automation memory preference, got: $submitted_title" >&2
  exit 1
fi

echo "self improve automation memory priority band test passed"
