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
      "id": "task-live-running",
      "title": "live running task",
      "project": "codex-agent-system",
      "status": "running",
      "updated_at": "2026-03-23T09:00:00Z",
      "execution": {
        "state": "running",
        "attempt": 1,
        "max_retries": 2,
        "provider": "codex",
        "result": "RUNNING",
        "updated_at": "2026-03-23T09:00:00Z",
        "will_retry": false,
        "lane": "lane-1",
        "lease_id": "lane-1-2026-03-23T09:00:00Z",
        "lease_state": "claimed",
        "lease_claimed_at": "2026-03-23T09:00:00Z",
        "lease_expires_at": "2099-03-23T09:05:00Z"
      },
      "history": []
    },
    {
      "id": "task-ghost-running",
      "title": "ghost running task",
      "project": "codex-agent-system",
      "status": "running",
      "updated_at": "2026-03-23T09:00:10Z",
      "execution": {
        "state": "running",
        "attempt": 1,
        "max_retries": 2,
        "provider": "codex",
        "result": "RUNNING",
        "updated_at": "2026-03-23T09:00:10Z",
        "will_retry": false,
        "lane": "lane-9",
        "lease_id": "lane-9-2026-03-23T09:00:10Z",
        "lease_state": "claimed",
        "lease_claimed_at": "2026-03-23T09:00:10Z",
        "lease_expires_at": "2099-03-23T09:05:10Z"
      },
      "history": []
    }
  ]
}
EOF

: >"$TEST_ROOT/queues/codex-agent-system.txt"

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  cat <<'EOF' | reconcile_running_registry_tasks_to_active_leases
lane-1	lane-1-2026-03-23T09:00:00Z	codex-agent-system	live running task
EOF
) >"$TMP_DIR/reconciled.txt"

grep -q $'codex-agent-system\tghost running task\trequeued missing live worker lease' "$TMP_DIR/reconciled.txt"
grep -qx 'ghost running task' "$TEST_ROOT/queues/codex-agent-system.txt"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tasks = {task["id"]: task for task in payload["tasks"]}

live = tasks["task-live-running"]
ghost = tasks["task-ghost-running"]

assert live["status"] == "running"
assert live["execution"]["lease_state"] == "claimed"
assert live["execution"]["lease_id"] == "lane-1-2026-03-23T09:00:00Z"

assert ghost["status"] == "approved"
assert ghost["execution"]["state"] == "retrying"
assert ghost["execution"]["lease_state"] == "released"
assert ghost["execution"]["will_retry"] is True
assert ghost["history"][-1]["action"] == "execute_reconcile"
PY

echo "running lease reconciliation test passed"
