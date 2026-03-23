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
  "$TEST_ROOT/projects/timeout-smoke" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/scripts/run-with-timeout.py" <<'EOF'
#!/usr/bin/env python3
import sys

print(f"TIMEOUT after {sys.argv[1]} seconds: {' '.join(sys.argv[2:])}", file=sys.stderr)
raise SystemExit(124)
EOF
chmod +x "$TEST_ROOT/scripts/run-with-timeout.py"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-timeout-smoke",
      "title": "timeout classification task",
      "project": "timeout-smoke",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-23T10:00:00Z",
      "updated_at": "2026-03-23T10:00:00Z",
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
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-1" \
    "$TEST_ROOT/projects/timeout-smoke" \
    "timeout-smoke" \
    "timeout classification task" \
    "0" \
    "codex"
) >"$WORKER_OUTPUT" 2>&1; then
  echo "queue-worker unexpectedly succeeded for timeout fixture" >&2
  exit 1
fi

grep -qx 'timeout classification task' "$TEST_ROOT/queues/timeout-smoke.txt"
grep -q 'TIMEOUT after 60 seconds:' "$WORKER_OUTPUT"
grep -q 'Task timed out after 60s on lane-1 for timeout-smoke' "$TEST_ROOT/codex-logs/system.log"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
task = payload["tasks"][0]
execution = task["execution"]

assert task["status"] == "approved"
assert execution["state"] == "retrying"
assert execution["attempt"] == 1
assert execution["result"] == "FAILURE"
assert execution["will_retry"] is True
assert execution["lease_state"] == "released"
assert task["history"][-1]["action"] == "execute_retry"
PY

python3 - "$TEST_ROOT/codex-memory/tasks.log" "$TEST_ROOT/codex-learning/provider-stats.json" <<'PY'
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
assert record["attempts"] == 1
assert record["provider"] == "codex"
assert record["duration_seconds"] == 60
assert record["failure_kind"] == "timeout"

stats = json.loads(Path(sys.argv[2]).read_text())
assert stats["codex"]["general"]["task_count"] == 1
assert stats["codex"]["general"]["success_rate"] == 0
PY

echo "queue worker timeout classification test passed"
