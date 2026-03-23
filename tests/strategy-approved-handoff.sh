#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
perl -0pi -e 's/const server = HTTPS_ENABLED\s+\? https\.createServer\(readTlsCredentials\(\), requestHandler\)\s+\: http\.createServer\(requestHandler\);\n\nserver\.listen\(PORT, "0\.0\.0\.0", \(\) => \{\n  const addresses = localAddresses\(\);\n  const addressText = dashboardUrls\(addresses\)\.join\(", "\);\n  fs\.appendFileSync\(\n    PATHS\.logs,\n    formatLogLine\("dashboard", "INFO", `Dashboard listening on \$\{addressText\}`\),\n    "utf8",\n  \);\n  console\.log\(`Dashboard listening on \$\{addressText\}`\);\n\}\);\n/module.exports = { transitionTaskRegistryItem, readTaskRegistryPayload, readTaskRegistry, summarizeTaskRegistry };\n/s' \
  "$TEST_ROOT/codex-dashboard/server.js"

mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "auto",
  "updated_at": "2026-03-22T20:45:00Z"
}
EOF

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 0,
  "success_rate": 0,
  "analysis_runs": 0,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "last_task_score": 0,
  "manual_recovery_records": 0
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-auto.json" >/dev/null
)

DASHBOARD_PROJECTS_DIR="$TEST_ROOT/projects" \
DASHBOARD_QUEUES_DIR="$TEST_ROOT/queues" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_PRIORITY_FILE="$TEST_ROOT/codex-memory/priority.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
node - "$TEST_ROOT" <<'NODE'
const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = process.argv[2];
const dashboard = require(path.join(root, "codex-dashboard", "server.js"));

(async () => {
  const seededRegistry = await dashboard.readTaskRegistryPayload();
  const seededTask = seededRegistry.tasks.find((task) => typeof task.strategy_template === "string" && task.strategy_template);
  assert.ok(seededTask, "expected a strategy-seeded task");
  assert.equal(seededTask.status, "pending_approval");
  assert.equal(seededTask.execution_provider, "codex");
  assert.ok(Array.isArray(seededTask.history));
  assert.equal(seededTask.history.length, 1);
  assert.deepEqual(seededTask.history[0], {
    at: seededTask.created_at,
    action: "create",
    from_status: "",
    to_status: "pending_approval",
    project: "codex-agent-system",
    queue_task: seededTask.title,
    note: "Task was added from enterprise-readiness strategy seeding to keep the backlog improving continuously.",
  });
  assert.equal(seededTask.approved_at, undefined);
  assert.equal(seededTask.queue_handoff, undefined);
  assert.equal(seededTask.execution_brief, undefined);

  const persistedRegistry = await dashboard.readTaskRegistryPayload();
  const persistedTask = persistedRegistry.tasks.find((task) => task.id === seededTask.id);
  assert.ok(persistedTask);
  assert.equal(persistedTask.status, "pending_approval");
  assert.deepEqual(persistedTask.history, seededTask.history);

  const queueFile = path.join(root, "queues", "codex-agent-system.txt");
  assert.equal(fs.existsSync(queueFile), false);

  delete require.cache[require.resolve(path.join(root, "codex-learning", "metrics.json"))];
  const persistedMetrics = require(path.join(root, "codex-learning", "metrics.json"));
  assert.equal(persistedMetrics.pending_approval_tasks, 2);
  assert.equal(persistedMetrics.approved_tasks, 0);
  assert.equal(persistedMetrics.task_registry_total, 2);

  const normalizedTasks = await dashboard.readTaskRegistry();
  const summary = dashboard.summarizeTaskRegistry(normalizedTasks);
  assert.equal(summary.byStatus.pending_approval, 2);
  assert.equal(summary.byStatus.approved, 0);
  assert.equal(summary.topApprovedTask, null);
  assert.equal(summary.topPendingTask.status, "pending_approval");
  assert.ok(normalizedTasks.filter((task) => task.status === "pending_approval").some((task) => task.id === summary.topPendingTask.id));
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE

echo "strategy approved handoff test passed"
