#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

REPO_ROOT="$TMP_DIR/repo"

mkdir -p "$REPO_ROOT"
cp -R "$ROOT_DIR/scripts" "$REPO_ROOT/scripts"
mkdir -p "$REPO_ROOT/codex-memory" "$REPO_ROOT/codex-learning" "$REPO_ROOT/codex-logs" "$REPO_ROOT/queues" "$REPO_ROOT/projects"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "external-approved-1",
      "title": "External approved task 1",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-2",
      "title": "External approved task 2",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-3",
      "title": "External approved task 3",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-4",
      "title": "External approved task 4",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-5",
      "title": "External approved task 5",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-6",
      "title": "External approved task 6",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-7",
      "title": "External approved task 7",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-8",
      "title": "External approved task 8",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-9",
      "title": "External approved task 9",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-10",
      "title": "External approved task 10",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-11",
      "title": "External approved task 11",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-12",
      "title": "External approved task 12",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-13",
      "title": "External approved task 13",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-14",
      "title": "External approved task 14",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "external-approved-15",
      "title": "External approved task 15",
      "project": "superheld",
      "status": "approved"
    },
    {
      "id": "local-pending-1",
      "title": "Local pending improvement",
      "project": "codex-agent-system",
      "status": "pending_approval"
    },
    {
      "id": "local-pending-2",
      "title": "Another local pending improvement",
      "project": "codex-agent-system",
      "status": "pending_approval"
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.12,
  "first_pass_success_rate": 0.43,
  "timeout_failure_rate": 0.11,
  "approved_tasks": 15,
  "pending_approval_tasks": 2,
  "task_registry_total": 17,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
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
    [.tasks[] | select((.task_intent.source // "") == "self-improve" and .project == "codex-agent-system")] | length
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "${task_count:-0}" -ne 1 ]; then
  echo "expected the normal single-submission limit to remain active" >&2
  exit 1
fi

python3 - "$REPO_ROOT/codex-memory/tasks.json" "$REPO_ROOT/codex-learning/self-improve-run.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
artifact = json.loads(Path(sys.argv[2]).read_text())
titles = {
    task.get("title")
    for task in payload["tasks"]
    if (task.get("task_intent") or {}).get("source") == "self-improve"
    and task.get("project") == "codex-agent-system"
}

assert titles == {"Reduce timeout rate"}, titles
assert artifact["counts"]["detected"] == 2, artifact["counts"]
assert artifact["counts"]["generated"] == 2, artifact["counts"]
assert artifact["counts"]["submitted"] == 1, artifact["counts"]
assert artifact["gating"]["backlog_gate_active"] is False, artifact["gating"]
assert artifact["gating"]["overload"]["active"] is False, artifact["gating"]["overload"]
assert artifact["metrics_snapshot"]["backlog"] == 2, artifact["metrics_snapshot"]
assert artifact["metrics_snapshot"]["approved_backlog"] == 2, artifact["metrics_snapshot"]
assert artifact["metrics_snapshot"]["queue_starvation_detected"] is False, artifact["metrics_snapshot"]
PY

echo "self improve project-local backlog gate test passed"
