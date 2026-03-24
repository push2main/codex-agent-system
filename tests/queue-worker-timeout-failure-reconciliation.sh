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
  "$TEST_ROOT/projects/timeout-failure" \
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
    "\"timeout-failure\" "
    "\"timeout failure task\" "
    "\"FAILURE\" "
    "\"1\" "
    "\"0\" "
    "\"\" "
    "\"\" "
    "\"run-timeout-failure-001\" "
    "\"299\" "
    "\"codex\" "
    "\"\" "
    "\"2\" "
    "\"task-timeout-failure\"; "
    "persist_task_run_context "
    "\"timeout-failure\" "
    "\"timeout failure task\" "
    "\"FAILURE\" "
    "\"run-timeout-failure-001\" "
    "\"1\" "
    "\"2\" "
    "\"0\" "
    "\"299\" "
    "\"2\" "
    "\"1\" "
    "\"2\" "
    "\"Record the failed compatibility decision.\" "
    "\"$PWD/plan.json\" "
    "\"codex\" "
    "\"2026-03-24T00:00:05Z\" "
    "\"task-timeout-failure\""
)
subprocess.Popen(["bash", "-lc", command], cwd=root, env=env)
print(f"TIMEOUT after {sys.argv[1]} seconds: {' '.join(sys.argv[2:])}", file=sys.stderr)
raise SystemExit(124)
EOF
chmod +x "$TEST_ROOT/scripts/run-with-timeout.py"

cat >"$TEST_ROOT/plan.json" <<'EOF'
{
  "data": {
    "steps": [
      "Inspect extracted evidence.",
      "Record the failed compatibility decision."
    ]
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-timeout-failure",
      "title": "timeout failure task",
      "project": "timeout-failure",
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

if (
  cd "$TEST_ROOT"
  TASK_TIMEOUT_SECONDS=60 \
  QUEUE_TIMEOUT_LATE_SUCCESS_MAX_POLLS=4 \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-1" \
    "$TEST_ROOT/projects/timeout-failure" \
    "timeout-failure" \
    "timeout failure task" \
    "0" \
    "codex" \
    "" \
    "task-timeout-failure"
) >"$WORKER_OUTPUT" 2>&1; then
  echo "queue-worker unexpectedly succeeded for timeout failure fixture" >&2
  exit 1
fi

grep -q 'TIMEOUT after 60 seconds:' "$WORKER_OUTPUT"
grep -q 'persisting failure evidence' "$TEST_ROOT/codex-logs/system.log"
grep -qx 'timeout failure task' "$TEST_ROOT/queues/timeout-failure.txt"
if grep -q 'Task timed out after 60s on lane-1 for timeout-failure' "$TEST_ROOT/codex-logs/system.log"; then
  echo "queue-worker incorrectly classified reconciled failure as a timeout" >&2
  exit 1
fi

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$TEST_ROOT/codex-memory/tasks.log" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
task = payload["tasks"][0]
execution = task["execution"]
execution_context = task["execution_context"]
failure_context = task["failure_context"]

assert task["status"] == "approved"
assert execution["state"] == "retrying"
assert execution["attempt"] == 1
assert execution["result"] == "FAILURE"
assert execution["will_retry"] is True
assert execution["lease_state"] == "released"
assert execution_context["result"] == "FAILURE"
assert execution_context["completed_steps"] == 1
assert failure_context["failed_step_index"] == 2
assert task["history"][-1]["action"] == "execute_retry"
assert "requeued for another attempt" in task["history"][-1]["note"]

records = [
    json.loads(line)
    for line in Path(sys.argv[2]).read_text().splitlines()
    if line.strip()
]
assert len(records) == 1
record = records[0]
assert record["result"] == "FAILURE"
assert record["run_id"] == "run-timeout-failure-001"
assert "failure_kind" not in record
PY

echo "queue worker timeout failure reconciliation test passed"
