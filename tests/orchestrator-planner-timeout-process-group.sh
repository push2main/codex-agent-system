#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/planner-timeout"
PID_FILE="$TMP_DIR/planner-child.pid"

cleanup() {
  if [ -f "$PID_FILE" ]; then
    child_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${child_pid:-}" ]; then
      kill "$child_pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/agents/planner.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
sleep 30 &
child_pid=\$!
printf '%s\n' "\$child_pid" >"$PID_FILE"
wait "\$child_pid"
EOF
chmod +x "$TEST_ROOT/agents/planner.sh"

set +e
(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  TASK_TIMEOUT_SECONDS=30 \
  PLANNER_TIMEOUT_SECONDS=1 \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "planner timeout task" \
    "task-planner-timeout"
) >"$TMP_DIR/orchestrator.out" 2>&1
status=$?
set -e

if [ "$status" -ne 3 ]; then
  echo "expected orchestrator to fail with planner timeout exit 3, got $status" >&2
  cat "$TMP_DIR/orchestrator.out" >&2 || true
  exit 1
fi

if [ ! -f "$PID_FILE" ]; then
  echo "expected planner child pid file to be written before timeout" >&2
  exit 1
fi

child_pid="$(cat "$PID_FILE")"
sleep 0.2
if kill -0 "$child_pid" 2>/dev/null; then
  echo "expected planner timeout to terminate child process tree, but pid $child_pid is still alive" >&2
  exit 1
fi

latest_run_dir="$(find "$TEST_ROOT/codex-logs/runs" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
if [ -z "$latest_run_dir" ]; then
  echo "expected orchestrator run directory to be created" >&2
  exit 1
fi

python3 - "$latest_run_dir/result.txt" "$latest_run_dir/failure-classification.json" <<'PY'
import json
import sys
from pathlib import Path

summary = {}
for raw_line in Path(sys.argv[1]).read_text().splitlines():
    line = raw_line.strip()
    if not line or "=" not in line:
        continue
    key, value = line.split("=", 1)
    summary[key] = value

classification = json.loads(Path(sys.argv[2]).read_text())

assert summary["result"] == "FAILURE"
assert summary["failure_kind"] == "timeout"
assert summary["failed_step_index"] == "0"
assert summary["total_step_attempts"] == "0"
assert classification["category"] == "timeout"
assert classification["retriable"] is False
assert classification["reason"] == "Planner timed out after 1s before step execution began"
PY

echo "orchestrator planner-timeout process-group test passed"
