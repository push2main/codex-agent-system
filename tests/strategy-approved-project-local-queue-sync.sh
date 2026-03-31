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
mkdir -p "$TEST_ROOT/projects/superheld/repo/.codex-agent" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs"

cat >"$TEST_ROOT/projects/superheld/repo/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-approved-requeue",
      "title": "[self-improve:medium] Document mandatory MVP protection cases in first slice",
      "project": "superheld",
      "status": "approved",
      "created_at": "2026-03-30T10:51:26Z",
      "approved_at": "2026-03-30T10:53:05Z",
      "updated_at": "2026-03-30T10:57:26Z",
      "execution_provider": "codex",
      "task_intent": {
        "source": "self-improve",
        "objective": "[self-improve:medium] Document mandatory MVP protection cases in first slice",
        "project": "superheld",
        "category": "learning",
        "context_hint": "Add a deterministic section to first-slice architecture.",
        "constraints": [],
        "success_signals": [],
        "affected_files": [
          "docs/architecture/first-slice.md"
        ]
      },
      "task_shape": {
        "approval_ready": true,
        "manual_review_required": false,
        "editable_files": [
          "docs/architecture/first-slice.md"
        ],
        "frozen_files": [],
        "verification_command": ""
      },
      "execution_brief": {
        "approved_at": "2026-03-30T10:53:05Z",
        "project": "superheld",
        "queue_task": "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope.",
        "provider": "codex",
        "queue_status": "queued",
        "status": "queued"
      },
      "queue_handoff": {
        "at": "2026-03-30T10:53:05Z",
        "project": "superheld",
        "task": "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope.",
        "status": "queued",
        "provider": "codex"
      },
      "history": [
        {
          "at": "2026-03-30T10:57:26Z",
          "action": "execute_failure",
          "from_status": "running",
          "to_status": "failed",
          "project": "superheld",
          "queue_task": "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope.",
          "note": "Queue execution failed after exhausting retries."
        },
        {
          "at": "2026-03-30T11:02:46Z",
          "action": "manual_requeue",
          "from_status": "failed",
          "to_status": "approved",
          "project": "superheld",
          "queue_task": "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope.",
          "note": "Requeued after planner inspect-step collapse fix."
        }
      ]
    }
  ]
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=idle
project=
task=
last_result=NONE
note=test
restart_needed=false
updated_at=2026-03-30T11:00:00Z
EOF

(
  cd "$TEST_ROOT"
  python3 scripts/strategy-approved-queue-sync.py projects/superheld/repo/.codex-agent/tasks.json superheld status.txt
) >"$TMP_DIR/queue-sync.json"

python3 - "$TMP_DIR/queue-sync.json" "$TEST_ROOT/queues/superheld.txt" "$TEST_ROOT/projects/superheld/repo/.codex-agent/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

result = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert result["status"] == "success", result
assert result["requeued"] == [
    "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope."
], result

queue_lines = [
    line.strip()
    for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert queue_lines == [
    "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope."
], queue_lines

registry = json.loads(Path(sys.argv[3]).read_text(encoding="utf-8"))
task = registry["tasks"][0]
assert task["status"] == "approved", task
assert task["queue_handoff"]["status"] == "queued", task["queue_handoff"]
assert task["execution_brief"]["queue_status"] == "queued", task["execution_brief"]
assert task["history"][-1]["action"] == "queue_rehydrate", task["history"][-1]
PY

(
  cd "$TEST_ROOT"
  python3 scripts/strategy-approved-queue-sync.py projects/superheld/repo/.codex-agent/tasks.json superheld status.txt
) >"$TMP_DIR/queue-sync-second.json"

test ! -s "$TMP_DIR/queue-sync-second.json"

python3 - "$TEST_ROOT/queues/superheld.txt" "$TEST_ROOT/projects/superheld/repo/.codex-agent/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

queue_lines = [
    line.strip()
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
assert queue_lines == [
    "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope."
], queue_lines

registry = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
task = registry["tasks"][0]
assert task["history"][-1]["action"] == "queue_rehydrate", task["history"][-1]
PY

echo "strategy approved project-local queue sync test passed"
