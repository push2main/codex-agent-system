#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PORT=32123

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

TASKS_FILE="$TMP_DIR/tasks.json"
TASK_LOG_FILE="$TMP_DIR/tasks.log"
METRICS_FILE="$TMP_DIR/metrics.json"
STATUS_FILE="$TMP_DIR/status.txt"
DASHBOARD_SETTINGS_FILE="$TMP_DIR/dashboard-settings.json"

mkdir -p "$TMP_DIR/projects" "$TMP_DIR/queues"

cat >"$TASKS_FILE" <<'EOF'
{
  "tasks": [
    {
      "id": "task-first-pass-success",
      "title": "Keep first-pass completions visible in metrics",
      "project": "codex-agent-system",
      "score": 3.5,
      "status": "completed",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "will_retry": false
      }
    },
    {
      "id": "task-retried-success",
      "title": "Track multi-attempt resolutions separately",
      "project": "codex-agent-system",
      "score": 2.4,
      "status": "completed",
      "execution": {
        "state": "completed",
        "attempt": 2,
        "max_retries": 2,
        "result": "SUCCESS",
        "will_retry": false
      }
    },
    {
      "id": "task-failed-run",
      "title": "Ignore failed completions in first-pass success rate",
      "project": "codex-agent-system",
      "score": 0,
      "status": "failed",
      "execution": {
        "state": "completed",
        "attempt": 2,
        "max_retries": 2,
        "result": "FAILURE",
        "will_retry": false
      }
    }
  ]
}
EOF

cat >"$TASK_LOG_FILE" <<'EOF'
{"timestamp":"2026-03-23T10:00:00Z","project":"codex-agent-system","task":"Keep first-pass completions visible in metrics","result":"SUCCESS","attempts":1,"score":8,"branch":"main","pr_url":"","run_id":"run-1","duration_seconds":10}
{"timestamp":"2026-03-23T10:01:00Z","project":"codex-agent-system","task":"Track multi-attempt resolutions separately","result":"SUCCESS","attempts":2,"score":8,"branch":"main","pr_url":"","run_id":"run-2","duration_seconds":20}
{"timestamp":"2026-03-23T10:02:00Z","project":"codex-agent-system","task":"Ignore failed completions in first-pass success rate","result":"FAILURE","attempts":2,"score":0,"branch":"main","pr_url":"","run_id":"run-3","duration_seconds":30}
EOF

cat >"$STATUS_FILE" <<'EOF'
state=idle
project=
task=
last_result=NONE
note=Test status
updated_at=2026-03-23T10:03:00Z
EOF

cat >"$DASHBOARD_SETTINGS_FILE" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-23T10:03:00Z"
}
EOF

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null

DASHBOARD_PORT="$PORT" \
DASHBOARD_PROJECTS_DIR="$TMP_DIR/projects" \
DASHBOARD_QUEUES_DIR="$TMP_DIR/queues" \
DASHBOARD_TASK_REGISTRY_FILE="$TASKS_FILE" \
DASHBOARD_TASK_LOG_FILE="$TASK_LOG_FILE" \
DASHBOARD_METRICS_FILE="$METRICS_FILE" \
DASHBOARD_STATUS_FILE="$STATUS_FILE" \
DASHBOARD_SETTINGS_FILE="$DASHBOARD_SETTINGS_FILE" \
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
  "module.exports = { buildFirstPassSuccessSignal };",
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
const signal = sandbox.module.exports.buildFirstPassSuccessSignal("", tasks);
const expected = {
  first_pass_success_count: 1,
  multi_attempt_resolved_count: 1,
  first_pass_success_rate: 0.5,
  low_first_pass_success_detected: false,
};

if (persisted.first_pass_success_count !== expected.first_pass_success_count) {
  throw new Error(`persisted first_pass_success_count=${persisted.first_pass_success_count}`);
}
if (persisted.multi_attempt_resolved_count !== expected.multi_attempt_resolved_count) {
  throw new Error(`persisted multi_attempt_resolved_count=${persisted.multi_attempt_resolved_count}`);
}
if (persisted.first_pass_success_rate !== expected.first_pass_success_rate) {
  throw new Error(`persisted first_pass_success_rate=${persisted.first_pass_success_rate}`);
}
if (persisted.low_first_pass_success_detected !== expected.low_first_pass_success_detected) {
  throw new Error(`persisted low_first_pass_success_detected=${persisted.low_first_pass_success_detected}`);
}
if (signal.first_pass_success_count !== expected.first_pass_success_count) {
  throw new Error(`api first_pass_success_count=${signal.first_pass_success_count}`);
}
if (signal.multi_attempt_resolved_count !== expected.multi_attempt_resolved_count) {
  throw new Error(`api multi_attempt_resolved_count=${signal.multi_attempt_resolved_count}`);
}
if (signal.first_pass_success_rate !== expected.first_pass_success_rate) {
  throw new Error(`api first_pass_success_rate=${signal.first_pass_success_rate}`);
}
if (signal.detected !== expected.low_first_pass_success_detected) {
  throw new Error(`api detected=${signal.detected}`);
}
JS

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

metrics_path = sys.argv[1]

with open(metrics_path, "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

expected = {
    "first_pass_success_count": 1,
    "multi_attempt_resolved_count": 1,
    "first_pass_success_rate": 0.5,
    "low_first_pass_success_detected": False,
}

assert persisted["first_pass_success_count"] == expected["first_pass_success_count"]
assert persisted["multi_attempt_resolved_count"] == expected["multi_attempt_resolved_count"]
assert persisted["first_pass_success_rate"] == expected["first_pass_success_rate"]
assert persisted["low_first_pass_success_detected"] is expected["low_first_pass_success_detected"]
PY

echo "first-pass metrics alignment test passed"
