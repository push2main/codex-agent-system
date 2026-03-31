#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/missing-source"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-missing-source",
      "title": "missing source task",
      "project": "missing-source",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-25T10:00:00Z",
      "updated_at": "2026-03-25T10:00:00Z",
      "history": []
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T10:05:00Z","project":"missing-source","task":"missing source task","result":"FAILURE","failure_kind":"missing_source_file","task_id":"task-missing-source","attempts":1,"score":0,"run_id":"run-missing-source-1"}
EOF

WORKER_OUTPUT="$TMP_DIR/queue-worker.out"

if (
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-1" \
    "$PROJECT_DIR" \
    "missing-source" \
    "missing source task" \
    "1" \
    "codex" \
    "lease-missing-source" \
    "task-missing-source"
) >"$WORKER_OUTPUT" 2>&1; then
  echo "queue-worker unexpectedly succeeded for missing-source fixture" >&2
  exit 1
fi

if [ -s "$TEST_ROOT/queues/missing-source.txt" ]; then
  echo "missing-source task was unexpectedly requeued" >&2
  exit 1
fi

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
task = payload["tasks"][0]
execution = task["execution"]
execution_context = task["execution_context"]
failure_context = task["failure_context"]

assert task["status"] == "failed"
assert task["last_failure_kind"] == "missing_source_file"
assert execution["state"] == "failed"
assert execution["result"] == "FAILURE"
assert execution["attempt"] == 2
assert execution["will_retry"] is False
assert execution["lease_state"] == "released"
assert execution_context["result"] == "FAILURE"
assert execution_context["failure_kind"] == "missing_source_file"
assert execution_context["failed_step"] == "Task blocked by non-retryable failure guard: last failure was missing_source_file."
assert failure_context["failure_kind"] == "missing_source_file"
assert failure_context["failed_step"] == "Task blocked by non-retryable failure guard: last failure was missing_source_file."
assert task["history"][-1]["action"] == "non_retryable_guard"
PY

echo "queue worker missing-source non-retriable test passed"
