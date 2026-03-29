#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-comment-only",
      "title": "In agents/planner.sh, add a comment documenting the MAX_STEP_CHARS=600 gate",
      "execution_task": "In agents/planner.sh, add a comment documenting the MAX_STEP_CHARS=600 gate",
      "project": "codex-agent-system",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-29T09:00:00Z",
      "updated_at": "2026-03-29T09:00:00Z",
      "task_intent": {
        "source": "self-improve",
        "objective": "In agents/planner.sh, add a comment documenting the MAX_STEP_CHARS=600 gate"
      },
      "history": []
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.13,
  "recent_success_rate": 0.0,
  "first_pass_success_rate": 0.0,
  "timeout_failure_rate": 0.35,
  "approved_tasks": 1,
  "approved_backlog": 1,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "retry_churn_detected": true,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "pipeline_stale": true,
  "self_improve_paused": true,
  "total_tasks": 587
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

WORKER_OUTPUT="$TMP_DIR/queue-worker.out"

if (
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-1" \
    "$PROJECT_DIR" \
    "codex-agent-system" \
    "In agents/planner.sh, add a comment documenting the MAX_STEP_CHARS=600 gate" \
    "0" \
    "codex" \
    "lease-low-signal" \
    "task-001-comment-only"
) >"$WORKER_OUTPUT" 2>&1; then
  echo "queue-worker unexpectedly succeeded for low-signal self-improve fixture" >&2
  exit 1
fi

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
task = payload["tasks"][0]

assert task["status"] == "shelved"
assert task["execution"]["state"] == "shelved"
assert task["execution"]["result"] == "RUNNING"
assert task["history"][-1]["action"] == "low_signal_self_improve_guard"
assert "comment/documentation-only work should not consume recovery capacity" in task["history"][-1]["note"]
PY

HELPER_BLOCKED="$(
  (
    cd "$TEST_ROOT"
    source "$TEST_ROOT/scripts/lib.sh"
    detect_low_signal_self_improve_task \
      "Update README deployment documentation" \
      "codex-agent-system" \
      ""
  ) | jq -r '.blocked'
)"
if [ "$HELPER_BLOCKED" != "false" ]; then
  echo "expected non-self-improve documentation task to stay allowed" >&2
  exit 1
fi

echo "queue worker low-signal self-improve guard test passed"
