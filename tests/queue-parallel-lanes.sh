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
sleep 3
printf 'END|%s|%s|%s\n' "$(date +%s)" "$PROJECT_DIR" "$TASK" >>"$LOG_FILE"
EOF
chmod +x "$TEST_ROOT/agents/orchestrator.sh"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-parallel-1",
      "title": "parallel lane task one",
      "project": "parallel-smoke",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-22T18:00:00Z",
      "updated_at": "2026-03-22T18:00:00Z",
      "history": []
    },
    {
      "id": "task-parallel-2",
      "title": "parallel lane task two",
      "project": "parallel-smoke",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-22T18:00:01Z",
      "updated_at": "2026-03-22T18:00:01Z",
      "history": []
    }
  ]
}
EOF

cat >"$TEST_ROOT/queues/parallel-smoke.txt" <<'EOF'
parallel lane task one
parallel lane task two
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"project":"parallel-smoke","result":"SUCCESS","attempts":1}
{"project":"parallel-smoke","result":"SUCCESS","attempts":1}
{"project":"parallel-smoke","result":"SUCCESS","attempts":1}
{"project":"parallel-smoke","result":"SUCCESS","attempts":1}
EOF

(
  cd "$TEST_ROOT"
  TEST_ORCH_LOG="$TEST_ROOT/orchestrator.log" \
  QUEUE_WORKERS=2 \
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
target_ids = {"task-parallel-1", "task-parallel-2"}

for _ in range(40):
    payload = json.loads(tasks_path.read_text())
    started = [
        task for task in payload["tasks"]
        if task.get("id") in target_ids
        if ((task.get("execution") or {}).get("lane") or "") in {"lane-1", "lane-2"}
        and task.get("status") in {"running", "completed"}
    ]
    lanes = {((task.get("execution") or {}).get("lane") or "") for task in started}
    if len(started) == 2 and lanes == {"lane-1", "lane-2"}:
        break
    time.sleep(0.2)
else:
    raise SystemExit("expected both tasks to start in separate lanes")

for _ in range(40):
    payload = json.loads(tasks_path.read_text())
    completed = [
        task for task in payload["tasks"]
        if task.get("id") in target_ids and task.get("status") == "completed"
    ]
    if len(completed) == 2:
      break
    time.sleep(0.25)
else:
    raise SystemExit("expected both tasks to complete")

payload = json.loads(tasks_path.read_text())
target_tasks = [task for task in payload["tasks"] if task.get("id") in target_ids]
assert len(target_tasks) == 2
lanes = {((task.get("execution") or {}).get("lane") or "") for task in target_tasks}
assert lanes == {"lane-1", "lane-2"}
assert all(((task.get("execution") or {}).get("lease_state") or "") == "released" for task in target_tasks)
assert all(((task.get("execution") or {}).get("result") or "") == "SUCCESS" for task in target_tasks)
PY

python3 - "$TEST_ROOT/orchestrator.log" <<'PY'
import sys
from pathlib import Path

entries = [line.strip().split("|") for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
starts = [entry for entry in entries if entry[0] == "START"]
ends = [entry for entry in entries if entry[0] == "END"]
assert len(starts) >= 2
assert len(ends) >= 2
start_by_task = {entry[3]: int(entry[1]) for entry in starts}
end_by_task = {entry[3]: int(entry[1]) for entry in ends}
assert len(start_by_task) >= 2
ordered_tasks = list(start_by_task)
first_task = ordered_tasks[0]
second_task = ordered_tasks[1]
assert first_task != second_task
assert start_by_task[second_task] < end_by_task[first_task], (start_by_task, end_by_task)
PY

kill "$QUEUE_PID" >/dev/null 2>&1 || true
pkill -P "$QUEUE_PID" >/dev/null 2>&1 || true
wait "$QUEUE_PID" >/dev/null 2>&1 || true
QUEUE_PID=""

echo "queue parallel lanes test passed"
