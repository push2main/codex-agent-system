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

mkdir -p "$TMP_DIR/projects" "$TMP_DIR/queues"

cat >"$TASKS_FILE" <<'EOF'
{
  "tasks": [
    {
      "id": "task-040-detect-low-first-pass-success-before-rep",
      "title": "Detect low first-pass success before repeated retries dominate the board",
      "project": "codex-agent-system",
      "status": "failed",
      "strategy_template": "first_pass_success_guard",
      "root_source_task_id": "strategy::first-pass-success",
      "task_intent": {
        "source": "strategy_anomaly"
      }
    },
    {
      "id": "task-043-detect-low-first-pass-success-before-rep",
      "title": "Detect low first-pass success before repeated retries dominate the board",
      "project": "codex-agent-system",
      "status": "failed",
      "strategy_template": "first_pass_success_guard",
      "root_source_task_id": "strategy::first-pass-success",
      "task_intent": {
        "source": "strategy_anomaly"
      }
    },
    {
      "id": "task-plain-failed-ui",
      "title": "Polish task card spacing",
      "project": "codex-agent-system",
      "status": "failed"
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
const expected = {
  strategy_saturation_detected: true,
  saturated_failed_tasks: 2,
};

if (persisted.strategy_saturation_detected !== expected.strategy_saturation_detected) {
  throw new Error(`persisted strategy_saturation_detected=${persisted.strategy_saturation_detected}`);
}
if (persisted.saturated_failed_tasks !== expected.saturated_failed_tasks) {
  throw new Error(`persisted saturated_failed_tasks=${persisted.saturated_failed_tasks}`);
}
if (metrics.strategy_saturation_detected !== expected.strategy_saturation_detected) {
  throw new Error(`api strategy_saturation_detected=${metrics.strategy_saturation_detected}`);
}
if (metrics.saturated_failed_tasks !== expected.saturated_failed_tasks) {
  throw new Error(`api saturated_failed_tasks=${metrics.saturated_failed_tasks}`);
}
JS

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

assert persisted["strategy_saturation_detected"] is True
assert persisted["saturated_failed_tasks"] == 2
PY

echo "strategy saturation metrics alignment test passed"
