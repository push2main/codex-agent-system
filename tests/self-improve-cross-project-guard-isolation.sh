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

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T09:00:00Z","project":"other-project","task":"[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%","result":"FAILURE","failure_kind":"timeout","task_id":"other-timeout-1"}
{"timestamp":"2026-03-25T09:05:00Z","project":"other-project","task":"[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%","result":"FAILURE","failure_kind":"timeout","task_id":"other-timeout-2"}
{"timestamp":"2026-03-25T09:10:00Z","project":"other-project","task":"[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%","result":"FAILURE","failure_kind":"timeout","task_id":"other-timeout-3"}
{"timestamp":"2026-03-25T09:15:00Z","project":"other-project","task":"[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%","result":"FAILURE","failure_kind":"timeout","task_id":"other-timeout-4"}
{"timestamp":"2026-03-25T09:20:00Z","project":"other-project","task":"[self-improve:high] Reduce timeout rate -- Tasks are timing out at 17%","result":"FAILURE","failure_kind":"timeout","task_id":"other-timeout-5"}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.82,
  "recent_success_rate": 0.8,
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.11,
  "retry_classification_coverage": 0.9,
  "retry_classified_count": 9,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "task_registry_total": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 80
}
EOF

touch "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

python3 - "$REPO_ROOT/codex-memory/tasks.json" "$REPO_ROOT/codex-learning/self-improve-run.json" <<'PY'
import json
import sys
from pathlib import Path

tasks_payload = json.loads(Path(sys.argv[1]).read_text())
artifact = json.loads(Path(sys.argv[2]).read_text())

self_improve_tasks = [
    task
    for task in tasks_payload.get("tasks", [])
    if (task.get("task_intent") or {}).get("source") == "self-improve"
]

assert len(self_improve_tasks) == 1, self_improve_tasks
task = self_improve_tasks[0]
assert task.get("project") == "codex-agent-system", task
assert task.get("status") == "pending_approval", task
assert task.get("title") == "Reduce timeout rate", task
assert str(task.get("execution_task") or "").startswith("[self-improve:high] Reduce timeout rate --"), task

assert artifact["counts"]["generated"] == 1, artifact["counts"]
assert artifact["counts"]["submitted"] == 1, artifact["counts"]
assert artifact["metrics_snapshot"]["timeout_rate"] in (0.11, "0.11"), artifact["metrics_snapshot"]
PY

echo "self improve cross-project guard isolation test passed"
