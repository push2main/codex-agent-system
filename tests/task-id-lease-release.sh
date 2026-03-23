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
      "title": "shared release title",
      "project": "codex-agent-system",
      "status": "running",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:30:00Z",
      "execution": {
        "state": "running",
        "lane": "lane-2",
        "lease_state": "claimed",
        "lease_id": "lane-2-older"
      }
    },
    {
      "id": "task-newer-shared-title",
      "title": "shared release title",
      "project": "codex-agent-system",
      "status": "running",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:30:00Z",
      "execution": {
        "state": "running",
        "lane": "lane-1",
        "lease_state": "claimed",
        "lease_id": "lane-1-newer"
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  release_task_lease "codex-agent-system" "shared release title" "lane-2" "task-older-shared-title"
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tasks = {task["id"]: task for task in payload["tasks"]}

older = tasks["task-older-shared-title"]
newer = tasks["task-newer-shared-title"]

assert older["execution"]["lease_state"] == "released"
assert older["execution"]["released_by_lane"] == "lane-2"
assert newer["execution"]["lease_state"] == "claimed"
assert newer["execution"]["lease_id"] == "lane-1-newer"
PY

echo "task id lease release test passed"
