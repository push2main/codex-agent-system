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

python3 - "$REPO_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys

tasks = []
for index in range(11):
    tasks.append({
        "id": f"task-{index + 1:03d}-pending-approval",
        "title": f"Pending approval task {index + 1}",
        "project": "codex-agent-system",
        "status": "pending_approval",
        "updated_at": "2026-03-25T10:00:00Z",
    })

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"tasks": tasks}, handle, indent=2)
    handle.write("\n")
PY

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.22,
  "first_pass_success_rate": 0.56,
  "timeout_failure_rate": 0.02,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 11,
  "queued_tasks": 0,
  "running_tasks": 0,
  "queue_starvation_detected": true,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 140
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.title // "") == "Drain approval backlog"))
    | first
    | [
        .title // "",
        .execution_task // ""
      ] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [[ "$task_summary" != $'Drain approval backlog\t'* ]]; then
  echo "expected pending-only approval backlog to use the generic approval-backlog title: $task_summary" >&2
  exit 1
fi

if [[ "$task_summary" != *"11 active approvals are waiting (11 pending approval)."* ]]; then
  echo "expected pending-only approval backlog reason to mention pending approvals explicitly: $task_summary" >&2
  exit 1
fi

echo "self improve pending approval backlog title test passed"
