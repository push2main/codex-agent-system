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
      "id": "task-superheld-stale-failed",
      "title": "project local stale failed task",
      "project": "superheld",
      "status": "running",
      "updated_at": "2026-03-22T18:00:00Z",
      "execution": {
        "state": "running",
        "attempt": 2,
        "max_retries": 2,
        "provider": "codex",
        "result": "RUNNING",
        "updated_at": "2026-03-22T18:00:00Z",
        "will_retry": false,
        "lane": "lane-4",
        "lease_state": "claimed",
        "lease_claimed_at": "2026-03-22T18:00:00Z",
        "lease_expires_at": "2026-03-22T18:05:00Z"
      },
      "history": [
        {
          "at": "2026-03-22T18:00:00Z",
          "action": "execute_start",
          "from_status": "approved",
          "to_status": "running",
          "project": "superheld",
          "queue_task": "project local stale failed task",
          "note": "Queue execution started."
        }
      ]
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
  STALE_RUNNING_TASK_SECONDS=999999 reclaim_stale_running_registry_tasks
) >"$TMP_DIR/recovered.txt"

grep -q $'superheld\tproject local stale failed task\tmarked stale running task as failed' "$TMP_DIR/recovered.txt"

python3 - "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
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
assert execution_context["task_id"] == "task-superheld-stale-failed"
assert failure_context["failure_kind"] == "stale_task_timeout"
assert failure_context["task_id"] == "task-superheld-stale-failed"
assert task["history"][-1]["action"] == "execute_stale_failure"
PY

echo "project local stale running failed context test passed"
