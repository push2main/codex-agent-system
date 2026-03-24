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
            "id": "task-registry-pressure",
            "title": "Persist task-registry payload pressure metrics",
            "project": "codex-agent-system",
            "category": "performance",
            "status": "pending_approval",
            "updated_at": "2026-03-24T01:05:00Z",
            "reason": "x" * 530000,
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
  "task_registry_payload_bytes",
  "task_registry_pressure_detected",
  "task_registry_pressure_primary_surface",
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

assert metrics["task_registry_payload_bytes"] > 512000
assert metrics["task_registry_pressure_detected"] is True
assert metrics["task_registry_pressure_primary_surface"] == "dashboard_read_path"
PY

echo "task registry pressure metrics alignment test passed"
