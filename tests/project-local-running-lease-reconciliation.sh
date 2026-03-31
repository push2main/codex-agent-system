#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/projects/superheld" \
  "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-ghost-running",
      "title": "project local ghost running task",
      "project": "superheld",
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

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_PROJECT_ROOT",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
}
EOF

: >"$TEST_ROOT/queues/superheld.txt"

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  printf '' | reconcile_running_registry_tasks_to_active_leases
) >"$TMP_DIR/reconciled.txt"

grep -q $'superheld\tproject local ghost running task\trequeued missing live worker lease' "$TMP_DIR/reconciled.txt"
grep -qx 'project local ghost running task' "$TEST_ROOT/queues/superheld.txt"

python3 - "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = payload["tasks"][0]

assert task["status"] == "approved"
assert task["execution"]["state"] == "retrying"
assert task["execution"]["lease_state"] == "released"
assert task["execution"]["will_retry"] is True
assert task["history"][-1]["action"] == "execute_reconcile"
PY

echo "project local running lease reconciliation test passed"
