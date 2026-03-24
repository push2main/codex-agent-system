#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR/codex-dashboard/server.js" <<'JS'
const assert = require("assert/strict");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const serverPath = process.argv[2];
let source = fs.readFileSync(serverPath, "utf8");
source = source.replace(
  /const server = HTTPS_ENABLED[\s\S]*$/,
  `module.exports = {
    readDashboardSnapshot,
    __setOverrides(overrides) {
      if (overrides.listProjects) listProjects = overrides.listProjects;
      if (overrides.readTaskRegistrySummarySnapshot) readTaskRegistrySummarySnapshot = overrides.readTaskRegistrySummarySnapshot;
      if (overrides.readDashboardSettings) readDashboardSettings = overrides.readDashboardSettings;
      if (overrides.readJsonFile) readJsonFile = overrides.readJsonFile;
      if (overrides.readMetrics) readMetrics = overrides.readMetrics;
      if (overrides.readStrategyHealth) readStrategyHealth = overrides.readStrategyHealth;
      if (overrides.readCodexAuthHealth) readCodexAuthHealth = overrides.readCodexAuthHealth;
      if (overrides.readRuntimeDashboardStatus) readRuntimeDashboardStatus = overrides.readRuntimeDashboardStatus;
      if (overrides.localAddresses) localAddresses = overrides.localAddresses;
      if (overrides.fspStat) fsp.stat = overrides.fspStat;
    },
  };`,
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

const { readDashboardSnapshot, __setOverrides } = sandbox.module.exports;
const summarySnapshot = {
  tasks: [{ id: "task-1", status: "pending_approval" }],
  queueTasks: [{ project: "codex-agent-system", task: "Review" }],
  status: { state: "queued", project: "codex-agent-system", task: "Review" },
  taskLog: "",
  taskLogRecords: [],
};
const settings = { approval_mode: "manual", updated_at: "2026-03-24T00:00:00Z" };
const externalSignals = { updated_at: "2026-03-23T11:52:18Z", signals: [], errors: [] };
const strategyPayload = { status: "success", message: "ok", data: { board_updates: [], board_tasks: [] } };
const strategyStat = { mtimeMs: Date.now() };
let metricsOptions = null;
let strategySnapshotArg = null;

__setOverrides({
  listProjects: async () => ["codex-agent-system"],
  readTaskRegistrySummarySnapshot: async () => summarySnapshot,
  readDashboardSettings: async () => settings,
  readJsonFile: async (filePath, fallback) => {
    if (String(filePath).endsWith("external-signals.json")) {
      return externalSignals;
    }
    if (String(filePath).endsWith("strategy-latest.json")) {
      return strategyPayload;
    }
    return fallback;
  },
  fspStat: async (filePath) => {
    if (String(filePath).endsWith("strategy-latest.json")) {
      return strategyStat;
    }
    throw new Error(`unexpected stat for ${filePath}`);
  },
  readMetrics: async (options = {}) => {
    metricsOptions = options;
    return { pendingApproval: 1, taskRegistryTotal: 1, queued: 1, externalResearch: { status: "fresh" } };
  },
  readStrategyHealth: async (snapshot) => {
    strategySnapshotArg = snapshot;
    return { status: "running", title: "Active", message: "ok", last_board_updates: 0 };
  },
  readCodexAuthHealth: async () => ({ active: false, blocks_queue: false, message: "healthy" }),
  readRuntimeDashboardStatus: async () => ({ runtime: {}, reload_drift_summary: "", capabilities: {} }),
  localAddresses: () => ["127.0.0.1"],
});

(async () => {
  const payload = await readDashboardSnapshot();
  assert.deepEqual(payload.projects, ["codex-agent-system"]);
  assert.equal(payload.metrics.pendingApproval, 1);
  assert.equal(metricsOptions.snapshot, summarySnapshot);
  assert.equal(metricsOptions.settings, settings);
  assert.equal(metricsOptions.externalSignals, externalSignals);
  assert.equal(strategySnapshotArg.tasks, summarySnapshot.tasks);
  assert.equal(strategySnapshotArg.queueTasks, summarySnapshot.queueTasks);
  assert.equal(strategySnapshotArg.status, summarySnapshot.status);
  assert.equal(strategySnapshotArg.taskLog, summarySnapshot.taskLog);
  assert.equal(strategySnapshotArg.taskLogRecords, summarySnapshot.taskLogRecords);
  assert.equal(strategySnapshotArg.strategyLatestPayload, strategyPayload);
  assert.equal(strategySnapshotArg.strategyLatestStat, strategyStat);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
JS

echo "dashboard snapshot preload threading test passed"
