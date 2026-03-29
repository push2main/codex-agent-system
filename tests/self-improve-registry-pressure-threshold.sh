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

run_self_improve() {
  local repo_root="$1"
  (
    cd "$repo_root"
    IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
  )
}

REPO_BELOW="$TMP_DIR/repo-below-threshold"
make_repo "$REPO_BELOW"

cat >"$REPO_BELOW/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_BELOW/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 511999,
  "task_registry_pressure_bytes": 511999,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 10
}
EOF

run_self_improve "$REPO_BELOW"

task_count_below="$(
  jq '
    [.tasks[] | select((.task_intent.source // "") == "self-improve")] | length
  ' "$REPO_BELOW/codex-memory/tasks.json"
)"
if [ "${task_count_below:-0}" -ne 0 ]; then
  echo "expected no registry-pressure task below shared threshold" >&2
  exit 1
fi

REPO_AT="$TMP_DIR/repo-at-threshold"
make_repo "$REPO_AT"

cat >"$REPO_AT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_AT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 512000,
  "task_registry_pressure_bytes": 512000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 10
}
EOF

run_self_improve "$REPO_AT"

queued_line="$(
  jq -r '
    .tasks
    | map(select(.task_intent.source == "self-improve"))
    | first
    | .execution_task // ""
  ' "$REPO_AT/codex-memory/tasks.json"
)"

case "$queued_line" in
  "[self-improve:medium] Reduce registry pressure -- "*)
    ;;
  *)
    echo "expected registry-pressure task at shared threshold" >&2
    exit 1
    ;;
esac

case "$queued_line" in
  *"500KB >= 500KB"*)
    ;;
  *)
    echo "expected registry-pressure reason to mention shared 500KB threshold" >&2
    exit 1
    ;;
esac

echo "self improve registry pressure threshold test passed"
