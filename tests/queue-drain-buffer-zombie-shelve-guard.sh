#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-001-queue-drain-buffer-zombie-oldest",
      "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
      "project": "codex-agent-system",
      "status": "shelved",
      "strategy_template": "queue_drain_completion_guard",
      "source_task_id": "strategy::queue-drain-completion",
      "root_source_task_id": "strategy::queue-drain-completion",
      "original_failed_root_id": "strategy::queue-drain-completion",
      "updated_at": "2026-03-23T10:00:00Z",
      "history": [
        {
          "at": "2026-03-23T10:00:00Z",
          "action": "zombie_guard",
          "from_status": "running",
          "to_status": "shelved",
          "project": "codex-agent-system",
          "queue_task": "Keep an executable system-work buffer when the queue drains under low completion rate",
          "note": "Task shelved by zombie guard: 8 prior failures exceed threshold of 5."
        }
      ]
    },
    {
      "id": "task-002-queue-drain-buffer-zombie-latest",
      "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
      "project": "codex-agent-system",
      "status": "shelved",
      "strategy_template": "queue_drain_completion_guard",
      "source_task_id": "strategy::queue-drain-completion",
      "root_source_task_id": "strategy::queue-drain-completion",
      "original_failed_root_id": "strategy::queue-drain-completion",
      "updated_at": "2026-03-23T10:05:00Z",
      "history": [
        {
          "at": "2026-03-23T10:05:00Z",
          "action": "zombie_guard",
          "from_status": "running",
          "to_status": "shelved",
          "project": "codex-agent-system",
          "queue_task": "Keep an executable system-work buffer when the queue drains under low completion rate",
          "note": "Task shelved by zombie guard: 9 prior failures exceed threshold of 5."
        }
      ]
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.11
}
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  reconcile_approved_registry_tasks_to_queue
) >"$TMP_DIR/requeued.txt"

test ! -s "$TMP_DIR/requeued.txt"
test ! -f "$TEST_ROOT/queues/codex-agent-system.txt"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
from pathlib import Path
import json
import sys

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tasks = payload["tasks"]
assert len(tasks) == 2
assert all(task["status"] == "shelved" for task in tasks)
assert all(task["history"][-1]["action"] == "zombie_guard" for task in tasks)
PY

echo "queue drain buffer zombie shelve guard test passed"
