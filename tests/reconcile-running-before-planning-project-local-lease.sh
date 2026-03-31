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
      "id": "task-superheld-running",
      "title": "project local running task",
      "project": "superheld",
      "status": "running",
      "updated_at": "2026-03-30T12:58:45Z",
      "execution": {
        "state": "running",
        "attempt": 1,
        "max_retries": 2,
        "provider": "codex",
        "result": "RUNNING",
        "updated_at": "2026-03-30T12:58:45Z",
        "will_retry": false,
        "lane": "lane-3",
        "lease_id": "lane-3-2026-03-30T12:58:47Z",
        "lease_state": "claimed",
        "lease_claimed_at": "2026-03-30T12:58:47Z",
        "lease_expires_at": "2099-03-30T13:03:57Z"
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

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=running
project=superheld
task=project local running task
last_result=RUNNING
note=step=1/2 attempt=1
updated_at=2026-03-30T12:58:48Z
EOF

: >"$TEST_ROOT/queues/superheld.txt"

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  reconcile_running_registry_tasks_before_planning
)

python3 - "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
task = payload["tasks"][0]

assert task["status"] == "running"
assert task["execution"]["state"] == "running"
assert task["execution"]["lease_state"] == "claimed"
assert task["execution"]["lease_id"] == "lane-3-2026-03-30T12:58:47Z"
assert task.get("history") == []
PY

if [ -s "$TEST_ROOT/queues/superheld.txt" ]; then
  echo "expected no queue rehydrate for active project-local lease" >&2
  exit 1
fi

echo "reconcile running before planning project-local lease test passed"
