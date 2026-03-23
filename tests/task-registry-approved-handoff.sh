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
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
perl -0pi -e 's/const server = HTTPS_ENABLED\s+\? https\.createServer\(readTlsCredentials\(\), requestHandler\)\s+\: http\.createServer\(requestHandler\);\n\nserver\.listen\(PORT, "0\.0\.0\.0", \(\) => \{\n  const addresses = localAddresses\(\);\n  const addressText = dashboardUrls\(addresses\)\.join\(", "\);\n  fs\.appendFileSync\(\n    PATHS\.logs,\n    formatLogLine\("dashboard", "INFO", `Dashboard listening on \$\{addressText\}`\),\n    "utf8",\n  \);\n  console\.log\(`Dashboard listening on \$\{addressText\}`\);\n\}\);\n/module.exports = { updateTaskRegistryItem, transitionTaskRegistryItem, readTaskRegistryPayload, readTaskRegistry, summarizeTaskRegistry };\n/s' \
  "$TEST_ROOT/codex-dashboard/server.js"

mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-approved-handoff",
      "title": "create hello world script in shell",
      "impact": 6,
      "effort": 2,
      "confidence": 0.9,
      "category": "stability",
      "project": "registry-smoke",
      "reason": "Focused regression fixture for approved-task queue handoff.",
      "score": 4.05,
      "status": "pending_approval",
      "task_intent": {
        "source": "dashboard_backlog",
        "objective": "create hello world script in shell",
        "project": "registry-smoke",
        "category": "stability",
        "context_hint": "Keep the handoff metadata deterministic.",
        "constraints": [
          "Return JSON only",
          "Keep changes minimal"
        ],
        "success_signals": [
          "Queue handoff keeps intent metadata"
        ],
        "affected_files": [
          "tests/task-registry-approved-handoff.sh"
        ]
      },
      "created_at": "2026-03-22T15:00:00Z",
      "updated_at": "2026-03-22T15:00:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": {
      "weight": 1.8,
      "success_rate": 0.76
    },
    "ui": {
      "weight": 1.35,
      "success_rate": 0.81
    },
    "performance": {
      "weight": 1.1,
      "success_rate": 0.7
    },
    "code_quality": {
      "weight": 1.05,
      "success_rate": 0.79
    }
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

DASHBOARD_PROJECTS_DIR="$TEST_ROOT/projects" \
DASHBOARD_QUEUES_DIR="$TEST_ROOT/queues" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_PRIORITY_FILE="$TEST_ROOT/codex-memory/priority.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
node - "$TEST_ROOT" <<'NODE'
const assert = require("assert");
const path = require("path");

const root = process.argv[2];
const dashboard = require(path.join(root, "codex-dashboard", "server.js"));

(async () => {
  const expected = {
    source: "dashboard_backlog",
    objective: "create hello world script for registry smoke",
    project: "registry-smoke-updated",
    category: "stability",
    context_hint: "Keep the handoff metadata deterministic.",
    constraints: ["Return JSON only", "Keep changes minimal"],
    success_signals: ["Queue handoff keeps intent metadata"],
    affected_files: ["tests/task-registry-approved-handoff.sh"],
  };

  const updated = await dashboard.updateTaskRegistryItem("task-approved-handoff", {
    project: "registry-smoke-updated",
    title: "create hello world script for registry smoke",
  });
  assert.equal(updated.ok, true);
  assert.deepEqual(updated.task.task_intent, expected);
  assert.ok(updated.task.history.some((entry) => entry.action === "edit"));

  const transition = await dashboard.transitionTaskRegistryItem("task-approved-handoff", "approve");
  assert.equal(transition.ok, true);
  assert.equal(transition.task.status, "approved");
  assert.equal(transition.task.queue_handoff.task, "create hello world script for registry smoke");
  assert.equal(transition.task.queue_handoff.provider, "codex");
  const expectedBrief = {
    approved_at: transition.task.approved_at,
    project: "registry-smoke-updated",
    queue_task: "create hello world script for registry smoke",
    provider: "codex",
    queue_status: transition.task.queue_handoff.status,
    status: transition.task.queue_handoff.status,
    ...expected,
    task_intent: expected,
  };
  const expectedApprovalExecutionBrief = {
    approved_at: transition.task.approved_at,
    project: "registry-smoke-updated",
    queue_task: "create hello world script for registry smoke",
    provider: "codex",
    queue_status: transition.task.queue_handoff.status,
  };
  assert.deepEqual(transition.task.task_intent, expected);
  assert.deepEqual(transition.task.queue_handoff.task_intent, expected);
  assert.deepEqual(transition.task.approval_execution_brief, expectedApprovalExecutionBrief);
  assert.deepEqual(transition.task.execution_brief, expectedBrief);
  assert.ok(transition.task.history.some((entry) => entry.action === "edit"));
  assert.equal(transition.task.history.length, 2);
  assert.deepEqual(transition.task.history[1], {
    at: transition.task.approved_at,
    action: "approve",
    from_status: "pending_approval",
    to_status: "approved",
    project: "registry-smoke-updated",
    queue_task: "create hello world script for registry smoke",
    note:
      transition.task.queue_handoff.status === "already_queued"
        ? "Task was already present in the queue at approval time."
        : "Task was enqueued after approval.",
  });

  const persistedRegistry = await dashboard.readTaskRegistryPayload();
  const persistedTask = persistedRegistry.tasks.find((item) => item.id === "task-approved-handoff");
  assert.ok(persistedTask);
  assert.equal(persistedTask.status, "approved");
  assert.equal(persistedTask.approved_at, transition.task.approved_at);
  assert.deepEqual(persistedTask.task_intent, expected);
  assert.deepEqual(persistedTask.queue_handoff.task_intent, expected);
  assert.deepEqual(persistedTask.approval_execution_brief, expectedApprovalExecutionBrief);
  assert.deepEqual(persistedTask.execution_brief, expectedBrief);
  assert.ok(["queued", "already_queued"].includes(persistedTask.queue_handoff.status));
  assert.deepEqual(persistedTask.history, transition.task.history);

  const persistedMetrics = require(path.join(root, "codex-learning", "metrics.json"));
  assert.equal(persistedMetrics.pending_approval_tasks, 0);
  assert.equal(persistedMetrics.approved_tasks, 1);
  assert.equal(persistedMetrics.task_registry_total, 1);

  const normalizedTasks = await dashboard.readTaskRegistry();
  const summary = dashboard.summarizeTaskRegistry(normalizedTasks);
  assert.equal(summary.byStatus.pending_approval, 0);
  assert.equal(summary.byStatus.approved, 1);
  assert.equal(summary.nextAction.state, "ready");
  assert.equal(summary.topApprovedTask.id, "task-approved-handoff");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
NODE

echo "task registry approved handoff test passed"
