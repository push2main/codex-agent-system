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
  IMPROVEMENT_COOLDOWN_SECONDS=3600 \
  bash scripts/self-improve.sh other-project >/dev/null
)

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=3600 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

python3 - "$REPO_ROOT/codex-memory/tasks.json" "$REPO_ROOT/codex-learning/self-improve-run.json" <<'PY'
import json
import sys
from pathlib import Path

tasks_payload = json.loads(Path(sys.argv[1]).read_text())
artifact = json.loads(Path(sys.argv[2]).read_text())

codex_tasks = [
    task
    for task in tasks_payload.get("tasks", [])
    if task.get("project") == "codex-agent-system"
    and (task.get("task_intent") or {}).get("source") == "self-improve"
]

assert len(codex_tasks) >= 1, codex_tasks
assert all(task.get("status") == "pending_approval" for task in codex_tasks), codex_tasks
assert all(str(task.get("title") or "").strip() != "" for task in codex_tasks), codex_tasks

assert int(artifact["counts"]["generated"]) >= 1, artifact["counts"]
assert int(artifact["counts"]["submitted"]) >= 1, artifact["counts"]
assert artifact["gating"]["analysis_reason"] == "none", artifact["gating"]
assert artifact["gating"]["dominant_reason"] != "cooldown_active", artifact["gating"]
assert artifact["gating"]["submission_reason"] != "cooldown_active", artifact["gating"]
PY

if [ ! -f "$REPO_ROOT/codex-logs/self-improve-other-project-cooldown" ]; then
  echo "expected project-specific cooldown file for other-project" >&2
  exit 1
fi

if [ ! -f "$REPO_ROOT/codex-logs/self-improve-codex-agent-system-cooldown" ]; then
  echo "expected project-specific cooldown file for codex-agent-system" >&2
  exit 1
fi

echo "self improve cooldown project isolation test passed"
