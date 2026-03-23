#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
QUEUE_PID=""

cleanup() {
  if [ -n "$QUEUE_PID" ]; then
    kill "$QUEUE_PID" >/dev/null 2>&1 || true
    pkill -P "$QUEUE_PID" >/dev/null 2>&1 || true
    wait "$QUEUE_PID" >/dev/null 2>&1 || true
  fi
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
  "$TEST_ROOT/projects/stale-prune-smoke" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/agents/orchestrator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
sleep 1
EOF
chmod +x "$TEST_ROOT/agents/orchestrator.sh"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id":"task-failed",
      "title":"stale failed task",
      "project":"stale-prune-smoke",
      "status":"failed",
      "execution_provider":"codex",
      "created_at":"2026-03-23T08:00:00Z",
      "updated_at":"2026-03-23T08:00:00Z",
      "history":[]
    },
    {
      "id":"task-approved",
      "title":"next approved task",
      "project":"stale-prune-smoke",
      "status":"approved",
      "execution_provider":"codex",
      "created_at":"2026-03-23T08:00:01Z",
      "updated_at":"2026-03-23T08:00:01Z",
      "history":[]
    }
  ]
}
EOF

cat >"$TEST_ROOT/queues/stale-prune-smoke.txt" <<'EOF'
stale failed task
next approved task
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

(
  cd "$TEST_ROOT"
  QUEUE_WORKERS=1 \
  QUEUE_POLL_SECONDS=1 \
  TASK_TIMEOUT_SECONDS=20 \
  bash "$TEST_ROOT/scripts/multi-queue.sh" daemon >"$TMP_DIR/queue.stdout" 2>&1
) &
QUEUE_PID=$!

python3 - "$TEST_ROOT" <<'PY'
import json
import time
from pathlib import Path

root = Path(__import__("sys").argv[1])
tasks_path = root / "codex-memory" / "tasks.json"
queue_path = root / "queues" / "stale-prune-smoke.txt"

for _ in range(40):
    payload = json.loads(tasks_path.read_text())
    approved = next(task for task in payload["tasks"] if task["title"] == "next approved task")
    remaining = [line.strip() for line in queue_path.read_text().splitlines() if line.strip()]
    if approved.get("status") == "completed" and "stale failed task" not in remaining:
        break
    time.sleep(0.25)
else:
    raise SystemExit("expected stale failed queue entry to be pruned and next task to complete")
PY

kill "$QUEUE_PID" >/dev/null 2>&1 || true
pkill -P "$QUEUE_PID" >/dev/null 2>&1 || true
wait "$QUEUE_PID" >/dev/null 2>&1 || true
QUEUE_PID=""

echo "queue stale entry prune test passed"
