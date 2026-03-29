#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"

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

write_metrics() {
  local repo_root="$1"
  cat >"$repo_root/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.14,
  "recent_success_rate": 0.14,
  "first_pass_success_rate": 0.82,
  "timeout_failure_rate": 0.33,
  "zero_step_timeout_rate": 0.6,
  "retry_classification_coverage": 0.82,
  "retry_classified_count": 41,
  "retry_total_count": 50,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "loop_effort_task_count": 0,
  "loop_effort_extra_step_attempts": 0,
  "external_signal_status": "fresh",
  "total_tasks": 240
}
EOF
}

make_repo "$REPO_ROOT"
write_metrics "$REPO_ROOT"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

created_affected_files="$(
  jq -r '
    .tasks
    | map(select(.title == "Reduce timeout rate"))
    | first
    | (.task_intent.affected_files // [])
    | join("\n")
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$created_affected_files" != $'agents/planner.sh\nagents/orchestrator.sh\nscripts/queue-worker.sh' ]; then
  echo "expected created self-improve task to mirror target_files into task_intent.affected_files: $created_affected_files" >&2
  exit 1
fi

python3 - "$REPO_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
task = next(item for item in payload["tasks"] if item.get("title") == "Reduce timeout rate")
task["task_intent"].pop("affected_files", None)
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

repaired_affected_files="$(
  jq -r '
    .tasks
    | map(select(.title == "Reduce timeout rate"))
    | first
    | (.task_intent.affected_files // [])
    | join("\n")
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$repaired_affected_files" != $'agents/planner.sh\nagents/orchestrator.sh\nscripts/queue-worker.sh' ]; then
  echo "expected self-improve metadata repair to restore task_intent.affected_files from target_files: $repaired_affected_files" >&2
  exit 1
fi

echo "self improve target-file intent test passed"
