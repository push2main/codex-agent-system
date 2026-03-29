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
      "id": "task-single-success",
      "title": "Only one persisted success should not force a 100% first-pass rate",
      "project": "codex-agent-system",
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
      "id": "task-failed-context",
      "title": "Keep unrelated failed tasks out of the first-pass denominator",
      "project": "codex-agent-system",
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
{"timestamp":"2026-03-28T00:00:00Z","project":"codex-agent-system","task":"recent first-pass success 1","result":"SUCCESS","attempts":1,"score":8}
{"timestamp":"2026-03-28T00:01:00Z","project":"codex-agent-system","task":"recent retry success 1","result":"SUCCESS","attempts":2,"score":8}
{"timestamp":"2026-03-28T00:02:00Z","project":"codex-agent-system","task":"recent retry success 2","result":"SUCCESS","attempts":3,"score":8}
{"timestamp":"2026-03-28T00:03:00Z","project":"codex-agent-system","task":"recent first-pass success 2","result":"SUCCESS","attempts":1,"score":8}
{"timestamp":"2026-03-28T00:04:00Z","project":"codex-agent-system","task":"recent retry success 3","result":"SUCCESS","attempts":2,"score":8}
EOF

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null

python3 - "$METRICS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metrics = json.load(handle)

assert metrics["first_pass_success_count"] == 2, metrics
assert metrics["multi_attempt_resolved_count"] == 3, metrics
assert metrics["first_pass_success_rate"] == 0.4, metrics
assert metrics["low_first_pass_success_detected"] is True, metrics
PY

node - "$ROOT_DIR" "$TASKS_FILE" "$TASK_LOG_FILE" <<'JS'
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const rootDir = process.argv[2];
const tasksPath = process.argv[3];
const recordsPath = process.argv[4];
const serverPath = path.join(rootDir, "codex-dashboard", "server.js");
const tasks = JSON.parse(fs.readFileSync(tasksPath, "utf8")).tasks;
const records = fs.readFileSync(recordsPath, "utf8")
  .trim()
  .split("\n")
  .filter(Boolean)
  .map((line) => JSON.parse(line));

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
const signal = sandbox.module.exports.buildFirstPassSuccessSignal("", tasks, records);
if (signal.first_pass_success_count !== 2) {
  throw new Error(`dashboard first_pass_success_count=${signal.first_pass_success_count}`);
}
if (signal.multi_attempt_resolved_count !== 3) {
  throw new Error(`dashboard multi_attempt_resolved_count=${signal.multi_attempt_resolved_count}`);
}
if (signal.first_pass_success_rate !== 0.4) {
  throw new Error(`dashboard first_pass_success_rate=${signal.first_pass_success_rate}`);
}
if (signal.detected !== true) {
  throw new Error(`dashboard detected=${signal.detected}`);
}
JS

echo "first-pass task-log fallback test passed"
