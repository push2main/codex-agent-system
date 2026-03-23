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
      "id": "task-older-shared-title",
      "title": "shared run-context title",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:30:00Z"
    },
    {
      "id": "task-newer-shared-title",
      "title": "shared run-context title",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:30:00Z"
    }
  ]
}
EOF

cat >"$TMP_DIR/plan.json" <<'EOF'
{
  "data": {
    "steps": [
      "Inspect same-title run context selection.",
      "Persist the failure context onto the claimed record."
    ]
  }
}
EOF

(
  cd "$TEST_ROOT"
  bash -lc 'source scripts/lib.sh; persist_task_run_context "codex-agent-system" "shared run-context title" "FAILURE" "run-shared-001" "2" "2" "0" "61" "2" "1" "2" "Persist the failure context onto the claimed record." "'"$TMP_DIR"'/plan.json" "codex" "2026-03-23T10:00:00Z" "task-older-shared-title"'
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tasks = {task["id"]: task for task in payload["tasks"]}

older = tasks["task-older-shared-title"]
newer = tasks["task-newer-shared-title"]

assert older["execution_context"]["run_id"] == "run-shared-001"
assert older["execution_context"]["task_id"] == "task-older-shared-title"
assert older["failure_context"]["task_id"] == "task-older-shared-title"
assert older["failure_context"]["failed_step_index"] == 2
assert older["failure_context"]["timestamp"] == "2026-03-23T10:00:00Z"

assert "execution_context" not in newer
assert "failure_context" not in newer
PY

echo "task id run context sync test passed"
