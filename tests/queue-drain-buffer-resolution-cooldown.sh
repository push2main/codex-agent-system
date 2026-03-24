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

python3 - <<'PY' >"$TEST_ROOT/codex-memory/tasks.json"
import json
from datetime import datetime, timedelta, timezone

recent = (datetime.now(timezone.utc) - timedelta(minutes=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
payload = {
    "tasks": [
        {
            "id": "task-001-queue-drain-buffer-recent",
            "title": "Keep an executable system-work buffer when the queue drains under low completion rate",
            "project": "codex-agent-system",
            "status": "completed",
            "strategy_template": "queue_drain_completion_guard",
            "source_task_id": "strategy::queue-drain-completion",
            "root_source_task_id": "strategy::queue-drain-completion",
            "original_failed_root_id": "strategy::queue-drain-completion",
            "updated_at": recent,
            "completed_at": recent,
        }
    ]
}
print(json.dumps(payload, indent=2))
PY

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
assert len(tasks) == 1
assert tasks[0]["status"] == "completed"
assert tasks[0]["strategy_template"] == "queue_drain_completion_guard"
PY

echo "queue drain buffer resolution cooldown test passed"
