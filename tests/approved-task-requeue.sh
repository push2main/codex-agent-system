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
      "id": "task-approved-orphan",
      "title": "rehydrate this approved task",
      "project": "codex-agent-system",
      "status": "approved",
      "approved_at": "2026-03-22T18:00:00Z",
      "queue_handoff": {
        "at": "2026-03-22T18:00:00Z",
        "project": "codex-agent-system",
        "task": "rehydrate this approved task",
        "status": "queued",
        "provider": "codex"
      }
    },
    {
      "id": "task-approved-existing",
      "title": "already queued approved task",
      "project": "codex-agent-system",
      "status": "approved",
      "approved_at": "2026-03-22T18:01:00Z",
      "queue_handoff": {
        "at": "2026-03-22T18:01:00Z",
        "project": "codex-agent-system",
        "task": "already queued approved task",
        "status": "queued",
        "provider": "codex"
      }
    },
    {
      "id": "task-running",
      "title": "currently running task",
      "project": "codex-agent-system",
      "status": "running"
    }
  ]
}
EOF

cat >"$TEST_ROOT/queues/codex-agent-system.txt" <<'EOF'
already queued approved task
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=running
project=codex-agent-system
task=currently running task
last_result=RUNNING
note=test
restart_needed=false
helper_scripts_marker=
updated_at=2026-03-22T18:01:30Z
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  reconcile_approved_registry_tasks_to_queue
) >"$TMP_DIR/requeued.txt"

grep -qx $'codex-agent-system\trehydrate this approved task' "$TMP_DIR/requeued.txt"

python3 - "$TEST_ROOT/queues/codex-agent-system.txt" <<'PY'
from pathlib import Path
import sys

lines = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
assert lines == [
    "already queued approved task",
    "rehydrate this approved task",
]
PY

echo "approved task requeue test passed"
