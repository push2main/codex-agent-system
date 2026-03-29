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
for index in range(10):
    tasks.append({
        "id": f"task-{index + 1:03d}-approved-backlog",
        "title": f"Approved backlog task {index + 1}",
        "project": "codex-agent-system",
        "status": "approved",
        "updated_at": "2026-03-25T10:00:00Z",
    })
for index in range(2):
    tasks.append({
        "id": f"task-{index + 11:03d}-queued-work",
        "title": f"Queued worker task {index + 1}",
        "project": "codex-agent-system",
        "status": "queued",
        "updated_at": "2026-03-25T10:05:00Z",
    })
tasks.append({
    "id": "task-013-running-work",
    "title": "Running worker task 1",
    "project": "codex-agent-system",
    "status": "running",
    "updated_at": "2026-03-25T10:06:00Z",
})

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"tasks": tasks}, handle, indent=2)
    handle.write("\n")
PY

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.48,
  "recent_success_rate": 0.50,
  "first_pass_success_rate": 0.64,
  "timeout_failure_rate": 0.01,
  "approved_tasks": 10,
  "approved_backlog": 10,
  "pending_approval_tasks": 0,
  "queued_tasks": 2,
  "running_tasks": 1,
  "queue_starvation_detected": false,
  "pending_approval_blocked_detected": false,
  "task_registry_payload_bytes": 64000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 160
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
if [ "${task_count:-0}" -ne 0 ]; then
  echo "expected approval backlog without a blocking signal to avoid creating a self-improve task" >&2
  exit 1
fi

echo "self improve backlog signal gate test passed"
