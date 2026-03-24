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
  "$TEST_ROOT/projects/timeout-claimed-grace" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/scripts/run-with-timeout.py" <<'EOF'
#!/usr/bin/env python3
import os
import subprocess
import sys

root = os.getcwd()
env = os.environ.copy()
command = (
    "sleep 3.2; "
    "source scripts/lib.sh; "
    "persist_task_run_context "
    "\"timeout-claimed-grace\" "
    "\"shared timeout task\" "
    "\"SUCCESS\" "
    "\"run-timeout-claimed-grace-001\" "
    "\"1\" "
    "\"2\" "
    "\"100\" "
    "\"299\" "
    "\"2\" "
    "\"2\" "
    "\"0\" "
    "\"\" "
    "\"$PWD/plan.json\" "
    "\"codex\" "
    "\"\" "
    "\"task-timeout-claimed-target\""
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
      "Record the exact wrapper decision."
    ]
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-timeout-claimed-older",
      "title": "shared timeout task",
      "project": "timeout-claimed-grace",
      "status": "failed",
      "execution_provider": "codex",
      "created_at": "2026-03-24T00:00:00Z",
      "updated_at": "2026-03-24T00:02:00Z",
      "history": [],
      "execution_context": {
        "run_id": "older-run",
        "result": "FAILURE",
        "updated_at": "2026-03-24T00:02:00Z"
      }
    },
    {
      "id": "task-timeout-claimed-target",
      "title": "shared timeout task",
      "project": "timeout-claimed-grace",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-24T00:03:00Z",
      "updated_at": "2026-03-24T00:03:00Z",
      "history": [],
      "execution": {
        "lease_claimed_at": "2026-03-24T00:03:01Z"
      }
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

WORKER_OUTPUT="$TMP_DIR/queue-worker.out"

(
  cd "$TEST_ROOT"
  TASK_TIMEOUT_SECONDS=60 \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-1" \
    "$TEST_ROOT/projects/timeout-claimed-grace" \
    "timeout-claimed-grace" \
    "shared timeout task" \
    "0" \
    "codex" \
    "" \
    "task-timeout-claimed-target"
) >"$WORKER_OUTPUT" 2>&1

grep -q 'TIMEOUT after 60 seconds:' "$WORKER_OUTPUT"
grep -q 'preserving completed status' "$TEST_ROOT/codex-logs/system.log"

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$TEST_ROOT/codex-memory/tasks.log" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
tasks = {task["id"]: task for task in payload["tasks"]}
target = tasks["task-timeout-claimed-target"]
older = tasks["task-timeout-claimed-older"]

assert target["status"] == "completed"
assert target["execution"]["state"] == "completed"
assert target["execution"]["result"] == "SUCCESS"
assert target["execution_context"]["result"] == "SUCCESS"
assert target["history"][-1]["action"] == "execute_success"
assert "timeout because success evidence was already persisted" in target["history"][-1]["note"]

assert older["status"] == "failed"
assert older["execution_context"]["run_id"] == "older-run"
assert older.get("history", []) == []

records = [line for line in Path(sys.argv[2]).read_text().splitlines() if line.strip()]
assert records == []
PY

echo "queue worker timeout claimed task grace test passed"
