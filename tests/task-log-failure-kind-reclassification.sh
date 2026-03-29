#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TMP_DIR/codex-memory" "$TMP_DIR/codex-learning" "$TMP_DIR/codex-logs"

export TASK_LOG="$TMP_DIR/codex-memory/tasks.log"
export TASK_REGISTRY_FILE="$TMP_DIR/codex-memory/tasks.json"
export METRICS_FILE="$TMP_DIR/codex-learning/metrics.json"
export INCIDENT_LOG_FILE="$TMP_DIR/codex-memory/incidents.jsonl"
export INCIDENTS_FILE="$TMP_DIR/codex-learning/incidents.json"

: >"$TASK_LOG"
printf '{"tasks":[]}\n' >"$TASK_REGISTRY_FILE"
printf '{}\n' >"$METRICS_FILE"

# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/lib.sh"

failed_step_text="Tests failed because expected output did not match the assertion."

append_task_log_record \
  "codex-agent-system" \
  "Tighten deterministic failure persistence" \
  "FAILURE" \
  "2" \
  "0" \
  "" \
  "" \
  "run-test-reclassify" \
  "42" \
  "codex" \
  "step_failure" \
  "2" \
  "task-test-reclassify" \
  "3" \
  "$failed_step_text"

python3 - "$TASK_LOG" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
assert len(records) == 1, records
record = records[0]
assert record["failure_kind"] == "test_failure", record
assert record["failed_step"] == "Tests failed because expected output did not match the assertion.", record
PY

incident_payload="$(classify_incident_record "FAILURE" "failed" "step_failure" "$failed_step_text" '{}')"

python3 - "$incident_payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
assert payload["failure_kind"] == "test_failure", payload
PY

echo "task log failure kind reclassification test passed"
