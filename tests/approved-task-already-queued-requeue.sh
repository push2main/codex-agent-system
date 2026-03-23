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

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-approved-already-queued",
      "title": "recover approved task after duplicate approval",
      "project": "codex-agent-system",
      "status": "approved",
      "approved_at": "2026-03-23T14:41:14Z",
      "queue_handoff": {
        "at": "2026-03-23T14:41:14Z",
        "project": "codex-agent-system",
        "task": "recover approved task after duplicate approval",
        "status": "already_queued",
        "provider": "codex"
      },
      "history": [
        {
          "at": "2026-03-23T14:41:14Z",
          "action": "approve",
          "from_status": "pending_approval",
          "to_status": "approved",
          "project": "codex-agent-system",
          "queue_task": "recover approved task after duplicate approval",
          "note": "Task was already queued or running."
        }
      ]
    }
  ]
}
EOF

: >"$TEST_ROOT/queues/codex-agent-system.txt"
: >"$TEST_ROOT/status.txt"

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  reconcile_approved_registry_tasks_to_queue
) >"$TMP_DIR/first-pass.txt"

grep -qx $'codex-agent-system\trecover approved task after duplicate approval' "$TMP_DIR/first-pass.txt"

python3 - "$TEST_ROOT/queues/codex-agent-system.txt" <<'PY'
from pathlib import Path
import sys

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
assert lines == ["recover approved task after duplicate approval"], lines
PY

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  reconcile_approved_registry_tasks_to_queue
) >"$TMP_DIR/second-pass.txt"

test ! -s "$TMP_DIR/second-pass.txt"

python3 - "$TEST_ROOT/queues/codex-agent-system.txt" <<'PY'
from pathlib import Path
import sys

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
assert lines == ["recover approved task after duplicate approval"], lines
PY

echo "approved already-queued task requeue test passed"
