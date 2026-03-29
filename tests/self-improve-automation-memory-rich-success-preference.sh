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

- 2026-03-25T13:30:42Z | weakness=zero-step timeout emergency could be dropped by timeout-family non-retryable suppression | improvement=kept Reduce timeout rate eligible during zero-step timeout emergencies when the family was blocked only by prior timeout failures and added a regression test | outcome=success; verified=zero-step emergency tests passed duration_s=90 | next=Reduce timeout rate
EOF

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.11,
  "retry_classification_coverage": 0.8,
  "retry_classified_count": 8,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "external_signal_status": "fresh",
  "total_tasks": 100
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
    | map(select((.task_intent.source // "") == "self-improve"))
    | .[0].title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"

if [ "$submitted_title" != "Reduce timeout rate" ]; then
  echo "expected rich success automation memory entry to prioritize timeout reduction, got: $submitted_title" >&2
  exit 1
fi

echo "self improve automation memory rich success preference test passed"
