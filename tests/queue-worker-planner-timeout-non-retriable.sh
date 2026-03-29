#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/planner-timeout"

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
  "$TEST_ROOT/queues" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-planner-timeout",
      "title": "planner timeout task",
      "project": "planner-timeout",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-25T10:00:00Z",
      "updated_at": "2026-03-25T10:00:00Z",
      "history": []
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

cat >"$TEST_ROOT/agents/planner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
sleep 2
EOF
chmod +x "$TEST_ROOT/agents/planner.sh"

WORKER_OUTPUT="$TMP_DIR/queue-worker.out"

if (
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  TASK_TIMEOUT_SECONDS=30 \
  PLANNER_TIMEOUT_SECONDS=1 \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-1" \
    "$PROJECT_DIR" \
    "planner-timeout" \
    "planner timeout task" \
    "0" \
    "codex" \
    "lease-planner-timeout" \
    "task-planner-timeout"
) >"$WORKER_OUTPUT" 2>&1; then
  echo "queue-worker unexpectedly succeeded for planner-timeout fixture" >&2
  exit 1
fi

if [ -s "$TEST_ROOT/queues/planner-timeout.txt" ]; then
  echo "planner-timeout task was unexpectedly requeued" >&2
  exit 1
fi

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
task = payload["tasks"][0]
execution = task["execution"]
execution_context = task["execution_context"]
failure_context = task["failure_context"]

assert task["status"] == "failed"
assert task["last_failure_kind"] == "timeout"
assert execution["state"] == "failed"
assert execution["result"] == "FAILURE"
assert execution["attempt"] == 1
assert execution["will_retry"] is False
assert execution["lease_state"] == "released"
assert execution_context["result"] == "FAILURE"
assert execution_context["failure_kind"] == "timeout"
assert execution_context["total_step_attempts"] == 0
assert execution_context["failed_step"] == "Planner timed out after 1s before step execution began"
assert failure_context["failure_kind"] == "timeout"
assert failure_context["failed_step"] == "Planner timed out after 1s before step execution began"
assert failure_context["failed_step_index"] == 0
assert task["history"][-1]["action"] == "execute_failure"
PY

python3 - "$TEST_ROOT/codex-memory/tasks.log" <<'PY'
import json
import sys
from pathlib import Path

records = [
    json.loads(line)
    for line in Path(sys.argv[1]).read_text().splitlines()
    if line.strip()
]
assert len(records) == 1
record = records[0]
assert record["result"] == "FAILURE"
assert record["failure_kind"] == "timeout"
assert record["total_step_attempts"] == 0
assert record["failed_step"] == "Planner timed out after 1s before step execution began"
PY

echo "queue worker planner-timeout non-retriable test passed"
