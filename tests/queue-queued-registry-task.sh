#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/agents/orchestrator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF
chmod +x "$TEST_ROOT/agents/orchestrator.sh"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-queued",
      "title": "repair queued registry handoff",
      "execution_task": "repair queued registry handoff",
      "project": "codex-agent-system",
      "status": "queued",
      "execution_provider": "codex",
      "created_at": "2026-03-27T19:00:00Z",
      "updated_at": "2026-03-27T19:00:00Z",
      "execution": {
        "state": "queued",
        "attempt": 0,
        "max_retries": 2,
        "provider": "codex",
        "updated_at": "2026-03-27T19:00:00Z"
      },
      "history": [
        {
          "at": "2026-03-27T19:00:00Z",
          "action": "metadata_repair",
          "from_status": "queued",
          "to_status": "queued",
          "project": "codex-agent-system",
          "queue_task": "repair queued registry handoff",
          "note": "Regression fixture for queued-task lease claims."
        }
      ]
    }
  ]
}
EOF

cat >"$TEST_ROOT/queues/codex-agent-system.txt" <<'EOF'
repair queued registry handoff
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

(
  cd "$TEST_ROOT"
  QUEUE_WORKERS=1 \
  QUEUE_POLL_SECONDS=1 \
  TASK_TIMEOUT_SECONDS=20 \
  bash "$TEST_ROOT/scripts/multi-queue.sh" --once >/dev/null
)

python3 - "$TEST_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
tasks = json.loads((root / "codex-memory" / "tasks.json").read_text())["tasks"]
task = next(item for item in tasks if item["id"] == "task-queued")

assert task["status"] == "completed", task
assert task["execution"]["state"] == "completed", task["execution"]
assert any(entry.get("action") == "execute_start" for entry in task.get("history", [])), task.get("history")
assert any(entry.get("action") == "execute_success" for entry in task.get("history", [])), task.get("history")

queue_file = root / "queues" / "codex-agent-system.txt"
remaining = [line.strip() for line in queue_file.read_text().splitlines() if line.strip()]
assert remaining == [], remaining
PY

echo "queued registry task queue execution test passed"
