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
for index in range(90):
    tasks.append({
        "id": f"task-{index + 1:03d}-approved-backlog",
        "title": f"Approved backlog task {index + 1}",
        "project": "codex-agent-system",
        "status": "approved",
        "updated_at": "2026-03-25T10:00:00Z",
    })

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"tasks": tasks}, handle, indent=2)
    handle.write("\n")
PY

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.35,
  "first_pass_success_rate": 0.35,
  "timeout_failure_rate": 0.04,
  "approved_tasks": 90,
  "pending_approval_tasks": 0,
  "task_registry_payload_bytes": 666040,
  "task_registry_pressure_detected": true,
  "retry_churn_detected": false,
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
  echo "expected fallback backlog gate to keep only one self-improve task under overload" >&2
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
if [ "$task_title" != "Drain approval backlog" ]; then
  echo "expected overload without timeout or retry churn to preserve the approval-backlog task" >&2
  exit 1
fi

echo "self improve backlog drain fallback test passed"
