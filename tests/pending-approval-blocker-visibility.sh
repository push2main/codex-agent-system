#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

TASKS_FILE="$TMP_DIR/tasks.json"

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

node - "$ROOT_DIR" "$TASKS_FILE" <<'JS'
const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const rootDir = process.argv[2];
const tasksPath = process.argv[3];
const serverPath = path.join(rootDir, "codex-dashboard", "server.js");
const tasks = JSON.parse(fs.readFileSync(tasksPath, "utf8")).tasks;

let source = fs.readFileSync(serverPath, "utf8");
source = source.replace(
  /const server = HTTPS_ENABLED[\s\S]*$/,
  "module.exports = { buildProjectHealthMetrics, buildStrategyHealthGuard };",
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

const { buildProjectHealthMetrics, buildStrategyHealthGuard } = sandbox.module.exports;
const projectHealth = buildProjectHealthMetrics("codex-agent-system", tasks, []);
assert.equal(projectHealth.pending_approval_blocked_detected, true);
assert.equal(projectHealth.queue_starvation_detected, false);

const guard = buildStrategyHealthGuard("codex-agent-system", tasks, [], { state: "idle" }, []);
assert.equal(guard.pending_approval_blocked_detected, true);
assert.equal(guard.healthy, true);
assert.equal(
  guard.summary,
  "Waiting on 1 pending approval task(s); no executable work is currently queued or running.",
);

const queuedGuard = buildStrategyHealthGuard(
  "codex-agent-system",
  tasks,
  [{ project: "codex-agent-system", task: "Execute approved follow-up" }],
  { state: "queued", project: "codex-agent-system", task: "Execute approved follow-up" },
  [],
);
assert.equal(queuedGuard.pending_approval_blocked_detected, false);
assert.equal(
  queuedGuard.summary,
  "No persisted retry churn or queue starvation signals are active.",
);
JS

echo "pending approval blocker visibility test passed"
