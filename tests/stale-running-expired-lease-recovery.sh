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
      "id": "task-expired-lease-running",
      "title": "recover expired lease running task",
      "project": "codex-agent-system",
      "status": "running",
      "updated_at": "2026-03-23T08:00:00Z",
      "execution": {
        "state": "running",
        "attempt": 1,
        "max_retries": 2,
        "provider": "codex",
        "result": "RUNNING",
        "updated_at": "2026-03-23T08:00:00Z",
        "will_retry": false,
        "lane": "lane-1",
        "lease_state": "claimed",
        "lease_claimed_at": "2026-03-23T08:00:00Z",
        "lease_expires_at": "2026-03-23T08:05:00Z"
      },
      "history": [
        {
          "at": "2026-03-23T08:00:00Z",
          "action": "execute_start",
          "from_status": "approved",
          "to_status": "running",
          "project": "codex-agent-system",
          "queue_task": "recover expired lease running task",
          "note": "Queue execution started."
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
last_result=SUCCESS
note=waiting_for_tasks=1
updated_at=2026-03-23T09:00:00Z
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  STALE_RUNNING_TASK_SECONDS=999999 reclaim_stale_running_registry_tasks
) >"$TMP_DIR/recovered.txt"

grep -q $'codex-agent-system\trecover expired lease running task\trequeued stale running task' "$TMP_DIR/recovered.txt"
grep -qx 'recover expired lease running task' "$TEST_ROOT/queues/codex-agent-system.txt"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = payload["tasks"][0]
assert task["status"] == "approved"
assert task["execution"]["state"] == "retrying"
assert task["execution"]["lease_state"] == "released"
assert task["execution"]["will_retry"] is True
assert task["history"][-1]["action"] == "execute_reclaim"
PY

echo "stale running expired lease recovery test passed"
