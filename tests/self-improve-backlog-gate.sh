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
  "tasks": []
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "first_pass_success_rate": 0.43,
  "timeout_failure_rate": 0.11,
  "approved_tasks": 90,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 666040,
  "task_registry_pressure_detected": true,
  "retry_churn_detected": true,
  "strategy_saturation_detected": true,
  "saturated_failed_tasks": 3,
  "loop_effort_task_count": 17,
  "loop_effort_extra_step_attempts": 31,
  "external_signal_status": "fresh",
  "total_tasks": 385
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
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected backlog gate to keep only one self-improve task under overload" >&2
  exit 1
fi

task_title="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | first
    | .title // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_title" != "Reduce timeout rate" ]; then
  echo "expected backlog gate to preserve only the timeout-reduction task under overload" >&2
  exit 1
fi

task_max_retries="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve"))
    | first
    | .execution.max_retries // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_max_retries" != "2" ]; then
  echo "expected self-improve tasks to inherit the default max_retries=2 policy" >&2
  exit 1
fi

echo "self improve backlog gate test passed"
