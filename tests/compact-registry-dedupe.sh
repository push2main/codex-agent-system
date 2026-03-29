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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/queues" "$TEST_ROOT/projects"

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-approved-dup",
            "title": "Preserve only one approved duplicate",
            "project": "codex-agent-system",
            "status": "approved",
            "created_at": "2026-03-25T23:55:00Z",
            "updated_at": "2026-03-26T00:05:00Z",
            "reason": "A" * 90000,
            "history": [
                {
                    "at": "2026-03-26T00:05:00Z",
                    "action": "approve",
                    "to_status": "approved",
                    "note": "keep-me",
                }
            ],
        },
        {
            "id": "task-approved-dup",
            "title": "Preserve only one approved duplicate",
            "project": "codex-agent-system",
            "status": "approved",
            "created_at": "2026-03-25T23:55:00Z",
            "updated_at": "2026-03-26T00:04:00Z",
            "reason": "A" * 90000,
        },
        {
            "id": "task-completed-dup",
            "title": "Preserve only one completed duplicate",
            "project": "codex-agent-system",
            "status": "completed",
            "created_at": "2026-03-25T07:00:00Z",
            "updated_at": "2026-03-25T07:10:00Z",
            "reason": "B" * 90000,
            "history": [
                {
                    "at": "2026-03-25T07:10:00Z",
                    "action": "execute_success",
                    "to_status": "completed",
                    "note": "keep-history",
                }
            ],
        },
        {
            "id": "task-completed-dup",
            "title": "Preserve only one completed duplicate",
            "project": "codex-agent-system",
            "status": "completed",
            "created_at": "2026-03-25T07:00:00Z",
            "updated_at": "2026-03-25T07:09:00Z",
            "reason": "B" * 90000,
        },
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

: >"$TEST_ROOT/codex-memory/tasks.log"
cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.5,
  "recent_success_rate": 0.5,
  "timeout_failure_rate": 0.0,
  "first_pass_success_rate": 0.5,
  "approved_tasks": 2,
  "pending_approval_tasks": 0,
  "approved_backlog": 2,
  "task_registry_pressure_bytes": 400000,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "zero_step_timeout_rate": 0.0,
  "total_tasks": 4
}
EOF

cat >"$TEST_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-25T08:00:00Z",
  "signals": []
}
EOF

before_size="$(wc -c <"$TEST_ROOT/codex-memory/tasks.json")"

(
  cd "$TEST_ROOT"
  bash scripts/compact-registry.sh >/dev/null
)

after_size="$(wc -c <"$TEST_ROOT/codex-memory/tasks.json")"

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$before_size" "$after_size" <<'PY'
import json
import sys

tasks_path = sys.argv[1]
before_size = int(sys.argv[2])
after_size = int(sys.argv[3])

payload = json.loads(open(tasks_path, "r", encoding="utf-8").read())
tasks = payload.get("tasks", [])

if len(tasks) != 2:
    raise SystemExit(f"expected 2 deduped tasks, found {len(tasks)}")

approved = [task for task in tasks if task.get("status") == "approved"]
completed = [task for task in tasks if task.get("status") == "completed"]

if len(approved) != 1:
    raise SystemExit(f"expected 1 approved task, found {len(approved)}")
if len(completed) != 1:
    raise SystemExit(f"expected 1 completed task, found {len(completed)}")

approved_history = approved[0].get("history") or []
completed_history = completed[0].get("history") or []
if len(approved_history) != 1 or approved_history[0].get("note") != "keep-me":
    raise SystemExit("expected richer approved duplicate to be preserved")
if len(completed_history) != 1 or completed_history[0].get("note") != "keep-history":
    raise SystemExit("expected richer completed duplicate to be preserved")

if not after_size < before_size:
    raise SystemExit(f"expected registry size to shrink ({before_size} -> {after_size})")
PY

if [ -f "$TEST_ROOT/codex-memory/tasks-archive.json" ] && [ -s "$TEST_ROOT/codex-memory/tasks-archive.json" ]; then
  echo "expected no archive output when dedupe alone resolves pressure" >&2
  exit 1
fi

echo "compact registry dedupe test passed"
