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
for index in range(12):
    tasks.append({
        "id": f"task-{index + 1:03d}-approved-backlog",
        "title": f"Approved backlog task {index + 1}",
        "project": "codex-agent-system",
        "status": "approved",
        "updated_at": "2026-03-25T10:00:00Z",
    })
for index in range(4):
    tasks.append({
        "id": f"task-{index + 13:03d}-pending-approval",
        "title": f"Pending approval task {index + 1}",
        "project": "codex-agent-system",
        "status": "pending_approval",
        "updated_at": "2026-03-25T10:05:00Z",
    })

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"tasks": tasks}, handle, indent=2)
    handle.write("\n")
PY

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.15,
  "recent_success_rate": 0.28,
  "first_pass_success_rate": 0.00,
  "timeout_failure_rate": 0.38,
  "zero_step_timeout_rate": 0.94,
  "retry_classification_coverage": 0.87,
  "retry_classified_count": 54,
  "retry_total_count": 62,
  "diagnostic_coverage": 1.0,
  "recent_diagnostic_coverage": 1.0,
  "failures_with_diagnostic": 443,
  "total_failure_records": 443,
  "approved_tasks": 12,
  "approved_backlog": 12,
  "pending_approval_tasks": 4,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 87748,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": true,
  "queue_starvation_detected": true,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 3,
  "loop_effort_extra_step_attempts": 3,
  "external_signal_status": "stale",
  "pipeline_stale": true,
  "pipeline_stale_since": "2026-03-25T07:27:18Z",
  "total_tasks": 522
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
  echo "expected overload gate to keep exactly one self-improve task in the queue-starvation recovery scenario" >&2
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
  echo "expected approval backlog drain to outrank stale-pipeline recovery when approved work is the live blocker" >&2
  exit 1
fi

preserved_reason="$(
  jq -r '.gating.overload.preserved_reason // ""' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$preserved_reason" != "approved_backlog_starvation" ]; then
  echo "unexpected overload-gate preserved reason: $preserved_reason" >&2
  exit 1
fi

echo "self improve approved backlog priority test passed"
