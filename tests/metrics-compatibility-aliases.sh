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

python3 - "$TASKS_FILE" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-approved",
            "title": "Keep approved work visible in compatibility metrics",
            "project": "codex-agent-system",
            "status": "approved",
            "updated_at": "2026-03-25T08:00:00Z",
        },
        {
            "id": "task-queued",
            "title": "Keep queued work visible in compatibility metrics",
            "project": "codex-agent-system",
            "status": "queued",
            "updated_at": "2026-03-25T08:01:00Z",
        },
        {
            "id": "task-running",
            "title": "Keep running work visible in compatibility metrics",
            "project": "codex-agent-system",
            "status": "running",
            "updated_at": "2026-03-25T08:02:00Z",
        },
        {
            "id": "task-failed-strategy-a",
            "title": "Detect low first-pass success before repeated retries dominate the board",
            "project": "codex-agent-system",
            "status": "failed",
            "strategy_template": "first_pass_success_guard",
            "root_source_task_id": "strategy::first-pass-success",
            "task_intent": {
                "source": "strategy_anomaly"
            },
            "updated_at": "2026-03-25T08:03:00Z",
            "reason": "x" * 530000,
        },
        {
            "id": "task-failed-strategy-b",
            "title": "Detect low first-pass success before repeated retries dominate the board",
            "project": "codex-agent-system",
            "status": "failed",
            "strategy_template": "first_pass_success_guard",
            "root_source_task_id": "strategy::first-pass-success",
            "task_intent": {
                "source": "strategy_anomaly"
            },
            "updated_at": "2026-03-25T08:04:00Z",
        }
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

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
const payloadBytes = fs.statSync(tasksPath).size;

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
const metrics = sandbox.module.exports.buildPersistedMetrics(tasks, [], null, {
  task_registry_payload_bytes: payloadBytes,
});

for (const field of [
  "approved_backlog",
  "queued_tasks",
  "running_tasks",
  "task_registry_pressure_bytes",
  "strategy_saturation",
]) {
  if (JSON.stringify(metrics[field]) !== JSON.stringify(persisted[field])) {
    throw new Error(`mismatch for ${field}: api=${JSON.stringify(metrics[field])} persisted=${JSON.stringify(persisted[field])}`);
  }
}
JS

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert metrics["approved_backlog"] == 1
assert metrics["queued_tasks"] == 1
assert metrics["running_tasks"] == 1
assert metrics["task_registry_pressure_bytes"] == metrics["task_registry_payload_bytes"]
assert metrics["task_registry_pressure_bytes"] > 512000
assert metrics["strategy_saturation"] is True
assert metrics["strategy_saturation_detected"] is True
PY

echo "metrics compatibility aliases test passed"
