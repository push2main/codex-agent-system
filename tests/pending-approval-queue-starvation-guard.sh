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
      "id": "task-pending-review-only",
      "title": "Review the next bounded experiment",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-24T08:00:00Z"
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

if (persisted.queue_starvation_detected !== false) {
  throw new Error(`persisted queue_starvation_detected=${persisted.queue_starvation_detected}`);
}
if (metrics.queue_starvation_detected !== false) {
  throw new Error(`api queue_starvation_detected=${metrics.queue_starvation_detected}`);
}
if (persisted.pending_approval_blocked_detected !== true) {
  throw new Error(
    `persisted pending_approval_blocked_detected=${persisted.pending_approval_blocked_detected}`,
  );
}
if (metrics.pending_approval_blocked_detected !== true) {
  throw new Error(`api pending_approval_blocked_detected=${metrics.pending_approval_blocked_detected}`);
}
JS

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

assert persisted["pending_approval_tasks"] == 1
assert persisted["approved_tasks"] == 0
assert persisted["queue_starvation_detected"] is False
assert persisted["pending_approval_blocked_detected"] is True
PY

echo "pending approval queue starvation guard test passed"
