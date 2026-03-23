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
      "id": "task-pending-review",
      "title": "Review bounded corrective task",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-23T10:00:00Z"
    },
    {
      "id": "task-approved-retrying",
      "title": "Retry shaping logic with explicit verification",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-23T10:01:00Z",
      "execution": {
        "attempt": 2,
        "max_retries": 2,
        "result": "FAILURE"
      }
    },
    {
      "id": "task-resolved-after-retry",
      "title": "Persist retried completion outcome",
      "project": "codex-agent-system",
      "status": "completed",
      "completed_at": "2026-03-23T10:02:00Z",
      "execution": {
        "state": "completed",
        "attempt": 3,
        "max_retries": 3,
        "result": "SUCCESS"
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

if (persisted.retry_churn_detected !== true) {
  throw new Error(`persisted retry_churn_detected=${persisted.retry_churn_detected}`);
}
if (persisted.queue_starvation_detected !== true) {
  throw new Error(`persisted queue_starvation_detected=${persisted.queue_starvation_detected}`);
}
if (metrics.retry_churn_detected !== persisted.retry_churn_detected) {
  throw new Error(`api retry_churn_detected=${metrics.retry_churn_detected}`);
}
if (metrics.queue_starvation_detected !== persisted.queue_starvation_detected) {
  throw new Error(`api queue_starvation_detected=${metrics.queue_starvation_detected}`);
}
JS

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

assert persisted["retry_churn_detected"] is True
assert persisted["queue_starvation_detected"] is True
PY

echo "board health metrics alignment test passed"
