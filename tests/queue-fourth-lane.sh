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
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/agents/orchestrator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${1:-}"
TASK="${2:-}"
LOG_FILE="${TEST_ORCH_LOG:?}"

printf 'START|%s|%s|%s\n' "$(date +%s)" "$PROJECT_DIR" "$TASK" >>"$LOG_FILE"
sleep 2
printf 'END|%s|%s|%s\n' "$(date +%s)" "$PROJECT_DIR" "$TASK" >>"$LOG_FILE"
EOF
chmod +x "$TEST_ROOT/agents/orchestrator.sh"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {"id":"task-parallel-1","title":"parallel lane task one","project":"parallel-smoke","status":"approved","execution_provider":"codex","created_at":"2026-03-22T18:00:00Z","updated_at":"2026-03-22T18:00:00Z","history":[]},
    {"id":"task-parallel-2","title":"parallel lane task two","project":"parallel-smoke","status":"approved","execution_provider":"claude","created_at":"2026-03-22T18:00:01Z","updated_at":"2026-03-22T18:00:01Z","history":[]},
    {"id":"task-parallel-3","title":"parallel lane task three","project":"parallel-smoke","status":"approved","execution_provider":"codex","created_at":"2026-03-22T18:00:02Z","updated_at":"2026-03-22T18:00:02Z","history":[]},
    {"id":"task-parallel-4","title":"parallel lane task four","project":"parallel-smoke","status":"approved","execution_provider":"claude","created_at":"2026-03-22T18:00:03Z","updated_at":"2026-03-22T18:00:03Z","history":[]}
  ]
}
EOF

cat >"$TEST_ROOT/queues/parallel-smoke.txt" <<'EOF'
parallel lane task one
parallel lane task two
parallel lane task three
parallel lane task four
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

(
  cd "$TEST_ROOT"
  TEST_ORCH_LOG="$TEST_ROOT/orchestrator.log" \
  QUEUE_WORKERS=4 \
  QUEUE_POLL_SECONDS=1 \
  TASK_TIMEOUT_SECONDS=20 \
  bash "$TEST_ROOT/scripts/multi-queue.sh" daemon >"$TMP_DIR/queue.stdout" 2>&1
) &
QUEUE_PID=$!

python3 - "$TEST_ROOT" <<'PY'
import json
import sys
import time
from pathlib import Path

root = Path(sys.argv[1])
tasks_path = root / "codex-memory" / "tasks.json"

for _ in range(40):
    payload = json.loads(tasks_path.read_text())
    running = [task for task in payload["tasks"] if task.get("status") == "running"]
    lanes = {((task.get("execution") or {}).get("lane") or "") for task in running}
    if len(running) == 4 and lanes == {"lane-1", "lane-2", "lane-3", "lane-4"}:
        break
    time.sleep(0.2)
else:
    raise SystemExit("expected four tasks to be running in separate lanes")

for _ in range(40):
    payload = json.loads(tasks_path.read_text())
    completed = [task for task in payload["tasks"] if task.get("status") == "completed"]
    if len(completed) == 4:
      break
    time.sleep(0.25)
else:
    raise SystemExit("expected all four tasks to complete")

payload = json.loads(tasks_path.read_text())
lanes = {task["execution"]["lane"] for task in payload["tasks"]}
assert lanes == {"lane-1", "lane-2", "lane-3", "lane-4"}
assert all(task["execution"]["lease_state"] == "released" for task in payload["tasks"])
assert all(task["execution"]["result"] == "SUCCESS" for task in payload["tasks"])
PY

kill "$QUEUE_PID" >/dev/null 2>&1 || true
pkill -P "$QUEUE_PID" >/dev/null 2>&1 || true
wait "$QUEUE_PID" >/dev/null 2>&1 || true
QUEUE_PID=""

echo "queue fourth lane test passed"
