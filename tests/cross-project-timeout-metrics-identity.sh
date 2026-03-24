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
            "id": "task-timeout-shared",
            "title": "Historical duplicate id in root project",
            "project": "codex-agent-system",
            "category": "stability",
            "status": "pending_approval",
            "created_at": "2026-03-24T16:00:00Z",
            "updated_at": "2026-03-24T16:00:00Z",
        },
        {
            "id": "task-timeout-shared",
            "title": "Reconcile late success after timeout",
            "project": "superheld",
            "category": "stability",
            "status": "completed",
            "created_at": "2026-03-24T16:01:00Z",
            "updated_at": "2026-03-24T16:06:00Z",
            "completed_at": "2026-03-24T16:06:00Z",
            "execution": {
                "state": "completed",
                "attempt": 2,
                "max_retries": 2,
                "result": "SUCCESS",
                "updated_at": "2026-03-24T16:06:00Z",
                "will_retry": False,
            },
            "execution_context": {
                "run_id": "run-timeout-reconciled",
                "result": "SUCCESS",
                "attempts": 2,
                "updated_at": "2026-03-24T16:06:00Z",
            },
        },
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

cat >"$TASK_LOG_FILE" <<'EOF'
{"timestamp":"2026-03-24T16:02:00Z","project":"superheld","task":"Reconcile late success after timeout","result":"FAILURE","failure_kind":"timeout","task_id":"task-timeout-shared","attempts":2,"score":0,"run_id":"run-timeout-reconciled"}
EOF

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null

node - "$ROOT_DIR" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" <<'JS'
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const rootDir = process.argv[2];
const tasksPath = process.argv[3];
const taskLogPath = process.argv[4];
const metricsPath = process.argv[5];
const serverPath = path.join(rootDir, "codex-dashboard", "server.js");
const tasks = JSON.parse(fs.readFileSync(tasksPath, "utf8")).tasks;
const records = fs
  .readFileSync(taskLogPath, "utf8")
  .split(/\r?\n/)
  .map((line) => line.trim())
  .filter(Boolean)
  .map((line) => JSON.parse(line));
const persisted = JSON.parse(fs.readFileSync(metricsPath, "utf8"));
const payloadBytes = fs.statSync(tasksPath).size;

let source = fs.readFileSync(serverPath, "utf8");
source = source.replace(
  /const server = HTTPS_ENABLED[\s\S]*$/,
  "module.exports = { buildPersistedMetrics, buildProjectHealthMetrics };",
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
const { buildPersistedMetrics, buildProjectHealthMetrics } = sandbox.module.exports;
const metrics = buildPersistedMetrics(tasks, records, null, {
  task_registry_payload_bytes: payloadBytes,
});
const projectHealth = buildProjectHealthMetrics("superheld", tasks, records);

for (const field of ["timeout_failure_records", "timeout_failure_rate"]) {
  if (JSON.stringify(metrics[field]) !== JSON.stringify(persisted[field])) {
    throw new Error(`mismatch for ${field}: api=${JSON.stringify(metrics[field])} persisted=${JSON.stringify(persisted[field])}`);
  }
}

if (projectHealth.timeout_failure_records !== 0 || projectHealth.timeout_failure_rate !== 0) {
  throw new Error(`project health still reports resolved timeout pressure: ${JSON.stringify(projectHealth)}`);
}
JS

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    metrics = json.load(handle)

assert metrics["timeout_failure_records"] == 0
assert metrics["timeout_failure_rate"] == 0
PY

echo "cross-project timeout metrics identity test passed"
