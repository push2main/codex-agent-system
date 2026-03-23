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
SIGNALS_FILE="$TMP_DIR/external-signals.json"

cat >"$TASKS_FILE" <<'EOF'
{
  "tasks": [
    {
      "id": "task-external-review",
      "title": "Review external signal: OpenAI Python releases - v2.29.0",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-23T11:55:00Z"
    }
  ]
}
EOF

: >"$TASK_LOG_FILE"

cat >"$SIGNALS_FILE" <<'EOF'
{
  "updated_at": "2026-03-23T11:52:18Z",
  "signal_count": 2,
  "signals": [
    {
      "source_id": "openai-python-releases",
      "source_label": "OpenAI Python releases",
      "title": "v2.29.0",
      "url": "https://github.com/openai/openai-python/releases/tag/v2.29.0",
      "published_at": "2026-03-17T17:53:05Z",
      "fresh": true
    },
    {
      "source_id": "playwright-releases",
      "source_label": "Playwright releases",
      "title": "v1.58.2",
      "url": "https://github.com/microsoft/playwright/releases/tag/v1.58.2",
      "published_at": "2026-02-06T16:41:43Z",
      "fresh": false
    }
  ],
  "errors": []
}
EOF

python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" "$SIGNALS_FILE" >/dev/null

node - "$ROOT_DIR" "$TASKS_FILE" "$METRICS_FILE" "$SIGNALS_FILE" <<'JS'
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const rootDir = process.argv[2];
const tasksPath = process.argv[3];
const metricsPath = process.argv[4];
const signalsPath = process.argv[5];
const serverPath = path.join(rootDir, "codex-dashboard", "server.js");
const tasks = JSON.parse(fs.readFileSync(tasksPath, "utf8")).tasks;
const persisted = JSON.parse(fs.readFileSync(metricsPath, "utf8"));
const signals = JSON.parse(fs.readFileSync(signalsPath, "utf8"));

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
const metrics = sandbox.module.exports.buildPersistedMetrics(tasks, [], signals);

for (const field of [
  "external_signal_status",
  "external_signal_count",
  "fresh_external_signal_count",
  "external_signal_error_count",
  "external_signal_updated_at",
  "latest_external_signal_source",
  "latest_external_signal_title",
  "latest_external_signal_url",
  "latest_external_signal_published_at",
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

assert metrics["external_signal_status"] == "fresh"
assert metrics["external_signal_count"] == 2
assert metrics["fresh_external_signal_count"] == 1
assert metrics["external_signal_error_count"] == 0
assert metrics["external_signal_updated_at"] == "2026-03-23T11:52:18Z"
assert metrics["latest_external_signal_source"] == "OpenAI Python releases"
assert metrics["latest_external_signal_title"] == "v2.29.0"
PY

echo "external signal metrics alignment test passed"
