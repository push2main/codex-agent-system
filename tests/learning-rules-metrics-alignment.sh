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
RULES_FILE="$TMP_DIR/rules.md"
PROMPT_RULES_FILE="$TMP_DIR/prompt-rules.md"
KNOWLEDGE_FILE="$TMP_DIR/knowledge.json"

cat >"$TASKS_FILE" <<'EOF'
{
  "tasks": [
    {
      "id": "task-learning-metrics",
      "title": "Keep learned guidance counts aligned",
      "project": "codex-agent-system",
      "status": "completed",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "will_retry": false
      }
    }
  ]
}
EOF

cat >"$TASK_LOG_FILE" <<'EOF'
{"timestamp":"2026-03-29T10:00:00Z","project":"codex-agent-system","task":"Keep learned guidance counts aligned","result":"SUCCESS","attempts":1,"score":8,"run_id":"run-1"}
{"timestamp":"2026-03-29T10:05:00Z","project":"codex-agent-system","task":"Retry classification remained visible","result":"FAILURE","failure_kind":"timeout","attempts":2,"score":0,"run_id":"run-2"}
{"timestamp":"2026-03-29T10:10:00Z","project":"codex-agent-system","task":"Prompt rules are active guidance","result":"SUCCESS","attempts":1,"score":7,"run_id":"run-3"}
{"timestamp":"2026-03-29T10:15:00Z","project":"codex-agent-system","task":"Dashboard metrics stay aligned","result":"SUCCESS","attempts":1,"score":7,"run_id":"run-4"}
EOF

cat >"$RULES_FILE" <<'EOF'
# Learned Rules

- Keep registry-backed metrics deterministic.
- Count active guidance from persistent rules.
EOF

cat >"$PROMPT_RULES_FILE" <<'EOF'
# Prompt Rules

- Count active guidance from persistent rules.
- Include prompt rules in active guidance metrics.
EOF

cat >"$KNOWLEDGE_FILE" <<'EOF'
{
  "rules": [
    {"rule": "Rule one"},
    {"rule": "Rule two"},
    {"rule": "Rule three"},
    {"rule": "Rule four"}
  ]
}
EOF

RULES_FILE="$RULES_FILE" \
PROMPT_RULES_FILE="$PROMPT_RULES_FILE" \
KNOWLEDGE_FILE="$KNOWLEDGE_FILE" \
python3 "$ROOT_DIR/scripts/sync-task-artifacts.py" "$TASKS_FILE" "$TASK_LOG_FILE" "$METRICS_FILE" >/dev/null

DASHBOARD_RULES_FILE="$RULES_FILE" \
DASHBOARD_PROMPT_RULES_FILE="$PROMPT_RULES_FILE" \
DASHBOARD_KNOWLEDGE_FILE="$KNOWLEDGE_FILE" \
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
const metrics = sandbox.module.exports.buildPersistedMetrics(tasks, records);

for (const field of [
  "learning_rules_count",
  "learning_knowledge_count",
  "learning_rate_per_100_tasks",
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

assert metrics["learning_rules_count"] == 3
assert metrics["learning_knowledge_count"] == 4
assert metrics["learning_rate_per_100_tasks"] == 75.0
PY

echo "learning rules metrics alignment test passed"
