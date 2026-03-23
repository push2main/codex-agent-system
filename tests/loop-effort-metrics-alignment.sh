#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

TASKS_FILE="$TMP_DIR/tasks.json"
TASK_LOG_FILE="$TMP_DIR/tasks.log"
METRICS_FILE="$TMP_DIR/metrics.json"

cat >"$TASKS_FILE" <<'EOF'
{
  "tasks": [
    {
      "id": "task-loop-effort-success",
      "title": "Complete the bounded execution path",
      "project": "codex-agent-system",
      "status": "completed",
      "completed_at": "2026-03-23T10:02:00Z",
      "execution": {
        "state": "completed",
        "attempt": 2,
        "max_retries": 2,
        "result": "SUCCESS"
      },
      "execution_context": {
        "attempts": 2,
        "total_step_attempts": 5
      }
    },
    {
      "id": "task-loop-effort-failure",
      "title": "Fail after extra step work",
      "project": "codex-agent-system",
      "status": "failed",
      "failed_at": "2026-03-23T10:03:00Z",
      "execution": {
        "state": "failed",
        "attempt": 1,
        "max_retries": 2,
        "result": "FAILURE"
      },
      "failure_context": {
        "attempts": 1,
        "total_step_attempts": 3
      }
    },
    {
      "id": "task-no-extra-effort",
      "title": "Stay within bounded retries",
      "project": "codex-agent-system",
      "status": "completed",
      "completed_at": "2026-03-23T10:04:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS"
      },
      "execution_context": {
        "attempts": 1,
        "total_step_attempts": 1
      }
    }
  ]
}
EOF

: >"$TASK_LOG_FILE"

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null

node - "$ROOT_DIR" "$TASKS_FILE" "$METRICS_FILE" <<'JS'
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const rootDir = process.argv[2];
const tasksPath = process.argv[3];
const metricsPath = process.argv[4];
const serverPath = path.join(rootDir, "codex-dashboard", "server.js");
const tasks = JSON.parse(fs.readFileSync(tasksPath, "utf8")).tasks;
const persisted = JSON.parse(fs.readFileSync(metricsPath, "utf8"));

let source = fs.readFileSync(serverPath, "utf8");
source = source.replace(
  /const server = HTTPS_ENABLED[\s\S]*$/,
  "module.exports = { buildPersistedMetrics };",
);

const sandbox = {
  module: { exports: {} },
  exports: {},
  require,
  __dirname: path.dirname(serverPath),
  __filename: serverPath,
  process,
  console,
  Buffer,
  setTimeout,
  clearTimeout,
};

vm.runInNewContext(source, sandbox, { filename: serverPath });
const metrics = sandbox.module.exports.buildPersistedMetrics(tasks, []);

if (persisted.loop_effort_detected !== true) {
  throw new Error(`persisted loop_effort_detected=${persisted.loop_effort_detected}`);
}
if (persisted.loop_effort_task_count !== 2) {
  throw new Error(`persisted loop_effort_task_count=${persisted.loop_effort_task_count}`);
}
if (persisted.loop_effort_extra_step_attempts !== 5) {
  throw new Error(`persisted loop_effort_extra_step_attempts=${persisted.loop_effort_extra_step_attempts}`);
}
if (metrics.loop_effort_detected !== persisted.loop_effort_detected) {
  throw new Error(`api loop_effort_detected=${metrics.loop_effort_detected}`);
}
if (metrics.loop_effort_task_count !== persisted.loop_effort_task_count) {
  throw new Error(`api loop_effort_task_count=${metrics.loop_effort_task_count}`);
}
if (metrics.loop_effort_extra_step_attempts !== persisted.loop_effort_extra_step_attempts) {
  throw new Error(`api loop_effort_extra_step_attempts=${metrics.loop_effort_extra_step_attempts}`);
}
JS

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

assert persisted["loop_effort_detected"] is True
assert persisted["loop_effort_task_count"] == 2
assert persisted["loop_effort_extra_step_attempts"] == 5
PY

echo "loop effort metrics alignment test passed"
