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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

(
  cd "$TEST_ROOT"
  bash -lc '
    source scripts/lib.sh
    persist_runtime_session_state "alpha" "Investigate runtime session state" "task-runtime-state" "run-runtime-001" "running" "background" "codex" "lane-1" "RUNNING" "2" "0" "Plan execution"
    append_runtime_session_event "alpha" "task-runtime-state" "run-runtime-001" "step_start" "Plan execution started." "step=1/2"
    append_runtime_session_blocker "alpha" "task-runtime-state" "run-runtime-001" "environment_gate" "Missing Android SDK"
    append_runtime_session_permission_request "alpha" "task-runtime-state" "run-runtime-001" "write_file" "apps/mobile/build.gradle"
    mark_runtime_session_foreground "alpha" "task-runtime-state" "run-runtime-001"
  '
)

python3 - "$TEST_ROOT/codex-logs/runtime-sessions/alpha/task-runtime-state.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

assert payload["project"] == "alpha"
assert payload["task_id"] == "task-runtime-state"
assert payload["run_id"] == "run-runtime-001"
assert payload["state"] == "running"
assert payload["visibility"] == "foreground"
assert payload["result"] == "RUNNING"
assert payload["provider"] == "codex"
assert payload["lane"] == "lane-1"
assert payload["step_count"] == 2
assert payload["completed_steps"] == 0
assert payload["current_step"] == "Plan execution"
assert payload["retrieved_at"]
assert payload["latest_activity"]["type"] == "step_start"
assert payload["latest_activity"]["summary"] == "Plan execution started."
assert payload["activity_history"][0]["type"] == "step_start"
assert payload["blockers"][0]["code"] == "environment_gate"
assert payload["blockers"][0]["reason"] == "Missing Android SDK"
assert payload["permission_requests"][0]["tool"] == "write_file"
assert payload["permission_requests"][0]["target"] == "apps/mobile/build.gradle"
PY

echo "runtime session state test passed"
