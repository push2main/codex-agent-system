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
      "id": "task-stale-running",
      "title": "recover ghost running task",
      "project": "codex-agent-system",
      "status": "running",
      "updated_at": "2026-03-22T18:00:00Z",
      "execution": {
        "state": "running",
        "attempt": 1,
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
          "queue_task": "recover ghost running task",
          "note": "Recovered running state from status.txt."
        }
      ]
    }
  ]
}
EOF

: >"$TEST_ROOT/queues/codex-agent-system.txt"
cat >"$TEST_ROOT/status.txt" <<'EOF'
state=running
project=codex-agent-system
task=some other task
last_result=RUNNING
note=test
updated_at=2026-03-22T21:00:00Z
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  mkdir -p "$TEST_ROOT/codex-logs/queue-retries"
  printf '1\n' >"$TEST_ROOT/codex-logs/queue-retries/codex-agent-system__recover_ghost_running_task.retry"
  STALE_RUNNING_TASK_SECONDS=60 reclaim_stale_running_registry_tasks
) >"$TMP_DIR/recovered.txt"

grep -q $'codex-agent-system\trecover ghost running task\trequeued stale running task' "$TMP_DIR/recovered.txt"
grep -qx 'recover ghost running task' "$TEST_ROOT/queues/codex-agent-system.txt"
python3 - "$TEST_ROOT" <<'PY'
import hashlib
import sys
from pathlib import Path

repo = Path(sys.argv[1])
retry_dir = repo / "codex-logs" / "queue-retries"
canonical = retry_dir / f"{hashlib.sha256('codex-agent-system::recover ghost running task'.encode('utf-8')).hexdigest()}.retry"
legacy = retry_dir / "codex-agent-system__recover_ghost_running_task.retry"
assert canonical.read_text(encoding="utf-8").strip() == "1"
assert not legacy.exists()
PY

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = payload["tasks"][0]
assert task["status"] == "approved"
assert task["execution"]["state"] == "retrying"
assert task["execution"]["lease_state"] == "released"
assert task["execution"]["max_retries"] == 2
assert task["execution"]["will_retry"] is True
assert task["history"][-1]["action"] == "execute_reclaim"
PY

echo "stale running recovery test passed"
