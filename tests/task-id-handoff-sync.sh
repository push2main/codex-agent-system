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
      "title": "shared queue title",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:30:00Z"
    },
    {
      "id": "task-newer-shared-title",
      "title": "shared queue title",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:30:00Z"
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  ensure_runtime_dirs

  claim_json="$(claim_task_lease "codex-agent-system" "shared queue title" "lane-1")"
  claimed_task_id="$(printf '%s' "$claim_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["task_id"])')"

  [ "$claimed_task_id" = "task-newer-shared-title" ]

  sync_task_registry_execution_state \
    "codex-agent-system" \
    "shared queue title" \
    "running" \
    "execute_start" \
    "Queue execution started." \
    "1" \
    "2" \
    "codex" \
    "lane-1" \
    "" \
    "0" \
    "$claimed_task_id"

  sync_task_registry_execution_state \
    "codex-agent-system" \
    "shared queue title" \
    "completed" \
    "execute_success" \
    "Queue execution completed successfully." \
    "1" \
    "2" \
    "codex" \
    "lane-1" \
    "" \
    "0" \
    "$claimed_task_id"
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tasks = {task["id"]: task for task in payload["tasks"]}

older = tasks["task-older-shared-title"]
newer = tasks["task-newer-shared-title"]

assert older["status"] == "approved"
assert "execution" not in older or older["execution"].get("state", "") != "completed"

assert newer["status"] == "completed"
assert newer["execution"]["state"] == "completed"
assert newer["execution"]["task_id"] == "task-newer-shared-title"
assert newer["history"][-1]["action"] == "execute_success"
PY

echo "task id handoff sync test passed"
