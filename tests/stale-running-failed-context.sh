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
      "id": "task-stale-failed",
      "title": "recover and fail stale running task",
      "project": "codex-agent-system",
      "status": "running",
      "updated_at": "2026-03-22T18:00:00Z",
      "execution": {
        "state": "running",
        "attempt": 2,
        "max_retries": 2,
        "provider": "codex",
        "result": "RUNNING",
        "updated_at": "2026-03-22T18:00:00Z",
        "will_retry": false
      },
      "history": [
        {
          "at": "2026-03-22T18:00:00Z",
          "action": "execute_start",
          "from_status": "approved",
          "to_status": "running",
          "project": "codex-agent-system",
          "queue_task": "recover and fail stale running task",
          "note": "Recovered running state from status.txt."
        }
      ]
    }
  ]
}
EOF

: >"$TEST_ROOT/queues/codex-agent-system.txt"
cat >"$TEST_ROOT/status.txt" <<'EOF'
state=idle
project=
task=
last_result=FAILURE
note=test
updated_at=2026-03-22T21:00:00Z
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  STALE_RUNNING_TASK_SECONDS=60 reclaim_stale_running_registry_tasks
) >"$TMP_DIR/recovered.txt"

grep -q $'codex-agent-system\trecover and fail stale running task\tmarked stale running task as failed' "$TMP_DIR/recovered.txt"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = payload["tasks"][0]
execution_context = task["execution_context"]
failure_context = task["failure_context"]

assert task["status"] == "failed"
assert task["last_failure_kind"] == "stale_task_timeout"
assert task["execution"]["state"] == "failed"
assert task["execution"]["failure_kind"] == "stale_task_timeout"
assert execution_context["result"] == "FAILURE"
assert execution_context["failure_kind"] == "stale_task_timeout"
assert execution_context["task_id"] == "task-stale-failed"
assert execution_context["failed_step"] == "Recovered stale running task without an active queue lane after retries were exhausted."
assert failure_context["failure_kind"] == "stale_task_timeout"
assert failure_context["task_id"] == "task-stale-failed"
assert failure_context["failed_step"] == "Recovered stale running task without an active queue lane after retries were exhausted."
assert task["history"][-1]["action"] == "execute_stale_failure"
PY

echo "stale running failed context test passed"
