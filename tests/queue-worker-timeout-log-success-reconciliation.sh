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
  "$TEST_ROOT/projects/timeout-log-success" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/scripts/run-with-timeout.py" <<'EOF'
#!/usr/bin/env python3
import os
import subprocess
import sys

root = os.getcwd()
env = os.environ.copy()
command = (
    "sleep 1; "
    "source scripts/lib.sh; "
    "append_task_log_record "
    "\"timeout-log-success\" "
    "\"timeout log success task\" "
    "\"SUCCESS\" "
    "\"1\" "
    "\"100\" "
    "\"\" "
    "\"\" "
    "\"run-timeout-log-success-001\" "
    "\"299\" "
    "\"codex\" "
    "\"\" "
    "\"2\" "
    "\"task-timeout-log-success\"; "
    "sleep 1; "
    "source scripts/lib.sh; "
    "persist_task_run_context "
    "\"timeout-log-success\" "
    "\"timeout log success task\" "
    "\"FAILURE\" "
    "\"run-timeout-log-success-002\" "
    "\"1\" "
    "\"2\" "
    "\"0\" "
    "\"300\" "
    "\"2\" "
    "\"2\" "
    "\"2\" "
    "\"late failure write should not override completed success\" "
    "\"\" "
    "\"codex\" "
    "\"2026-03-24T00:02:00Z\" "
    "\"task-timeout-log-success\" "
    "\"timeout\""
)
subprocess.Popen(["bash", "-lc", command], cwd=root, env=env)
print(f"TIMEOUT after {sys.argv[1]} seconds: {' '.join(sys.argv[2:])}", file=sys.stderr)
raise SystemExit(124)
EOF
chmod +x "$TEST_ROOT/scripts/run-with-timeout.py"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-timeout-log-success",
      "title": "timeout log success task",
      "project": "timeout-log-success",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-24T00:00:00Z",
      "updated_at": "2026-03-24T00:00:00Z",
      "history": []
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

WORKER_OUTPUT="$TMP_DIR/queue-worker.out"

(
  cd "$TEST_ROOT"
  TASK_TIMEOUT_SECONDS=60 \
  QUEUE_TIMEOUT_LATE_SUCCESS_MAX_POLLS=4 \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-1" \
    "$TEST_ROOT/projects/timeout-log-success" \
    "timeout-log-success" \
    "timeout log success task" \
    "0" \
    "codex" \
    "" \
    "task-timeout-log-success"
) >"$WORKER_OUTPUT" 2>&1

sleep 3

grep -q 'TIMEOUT after 60 seconds:' "$WORKER_OUTPUT"
grep -q 'preserving completed status' "$TEST_ROOT/codex-logs/system.log"

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$TEST_ROOT/codex-memory/tasks.log" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
task = payload["tasks"][0]
execution = task["execution"]
execution_context = task.get("execution_context") if isinstance(task.get("execution_context"), dict) else {}

assert task["status"] == "completed"
assert execution["state"] == "completed"
assert execution["result"] == "SUCCESS"
assert execution["lease_state"] == "released"
assert task["history"][-1]["action"] == "execute_success"
assert "timeout because success evidence was already persisted" in task["history"][-1]["note"]
assert execution_context.get("result") != "FAILURE"
assert "failure_context" not in task
assert task.get("last_failure_kind") in (None, "")

records = [
    json.loads(line)
    for line in Path(sys.argv[2]).read_text().splitlines()
    if line.strip()
]
assert len(records) == 1
record = records[0]
assert record["result"] == "SUCCESS"
assert record["task_id"] == "task-timeout-log-success"
assert record["run_id"] == "run-timeout-log-success-001"
PY

echo "queue worker timeout log success reconciliation test passed"
