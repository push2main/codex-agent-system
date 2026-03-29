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
for index in range(3):
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

: >"$REPO_ROOT/codex-memory/tasks.log"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.62,
  "recent_success_rate": 0.58,
  "first_pass_success_rate": 0.71,
  "timeout_failure_rate": 0.02,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 3,
  "queued_tasks": 0,
  "running_tasks": 0,
  "queue_starvation_detected": false,
  "pending_approval_blocked_detected": true,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T07:27:18Z",
  "total_tasks": 160
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
  IMPROVEMENT_COOLDOWN_SECONDS=0 bash scripts/self-improve.sh codex-agent-system >/dev/null
)

task_summary="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.title // "") == "Drain approval backlog"))
    | first
    | [.title // "", .status // "", .shelved_reason // ""] | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$task_summary" != $'Drain approval backlog\tpending_approval\t' ]; then
  echo "expected stalled pending approvals to keep a drain approval backlog task active: $task_summary" >&2
  exit 1
fi

recover_count="$(
  jq '
    [.tasks[]
      | select((.task_intent.source // "") == "self-improve" and (.title // "") == "Recover stale pipeline")
    ] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${recover_count:-0}" -ne 0 ]; then
  echo "expected stalled pending approvals to avoid creating the broader recover stale pipeline task" >&2
  exit 1
fi

task_reason="$(
  jq -r '
    .tasks
    | map(select((.task_intent.source // "") == "self-improve" and (.title // "") == "Drain approval backlog"))
    | first
    | .reason // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [[ "$task_reason" != *"pending approvals are blocking execution while the queue is idle."* ]]; then
  echo "expected stalled pending approval reason to mention the blocking board state: $task_reason" >&2
  exit 1
fi

echo "self improve pending approval stale pipeline backlog test passed"
