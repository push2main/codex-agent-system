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
mkdir -p "$TEST_ROOT/codex-memory"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-fresh-requeue",
      "title": "fresh grounded missing source requeue",
      "project": "superheld",
      "status": "approved",
      "updated_at": "2026-03-29T23:41:50Z",
      "execution": {
        "attempt": 4,
        "failure_kind": "missing_source_file"
      },
      "history": [
        {
          "at": "2026-03-29T23:41:50Z",
          "action": "auto_requeue_grounded_missing_source",
          "from_status": "failed",
          "to_status": "approved"
        }
      ]
    },
    {
      "id": "task-still-chronic",
      "title": "still chronic",
      "project": "superheld",
      "status": "approved",
      "updated_at": "2026-03-29T23:41:50Z",
      "execution": {
        "attempt": 4,
        "failure_kind": "missing_source_file"
      },
      "history": [
        {
          "at": "2026-03-29T23:35:30Z",
          "action": "execute_retry",
          "from_status": "running",
          "to_status": "approved"
        }
      ]
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  python3 scripts/strategy-chronic-tasks.py codex-memory/tasks.json >/dev/null
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
tasks = {task["id"]: task for task in payload["tasks"]}

assert tasks["task-fresh-requeue"]["status"] == "approved"
assert "status_reason" not in tasks["task-fresh-requeue"]

assert tasks["task-still-chronic"]["status"] == "failed"
assert tasks["task-still-chronic"]["status_reason"].startswith("Chronic failure after 4 attempts")
PY

echo "strategy chronic tasks fresh requeue grace test passed"
