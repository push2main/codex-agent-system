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
    readDashboardArtifacts,
    __setOverrides(overrides) {
      if (overrides.readTaskRegistrySummarySnapshot) readTaskRegistrySummarySnapshot = overrides.readTaskRegistrySummarySnapshot;
      if (overrides.readDashboardSettings) readDashboardSettings = overrides.readDashboardSettings;
      if (overrides.readJsonFile) readJsonFile = overrides.readJsonFile;
      if (overrides.listProjects) listProjects = overrides.listProjects;
      if (overrides.readCodexAuthHealth) readCodexAuthHealth = overrides.readCodexAuthHealth;
      if (overrides.readRuntimeDashboardStatus) readRuntimeDashboardStatus = overrides.readRuntimeDashboardStatus;
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

const { readDashboardArtifacts, __setOverrides } = sandbox.module.exports;
const summarySnapshot = {
  tasks: [{ id: "task-1" }],
  queueTasks: [{ project: "codex-agent-system", task: "Review" }],
  status: { state: "queued", project: "codex-agent-system" },
  taskLog: "",
  taskLogRecords: [],
};
const settings = { approval_mode: "manual", updated_at: "2026-03-24T00:00:00Z" };
const externalSignals = { updated_at: "2026-03-23T11:52:18Z", signals: [], errors: [] };
const authHealth = { active: false, blocks_queue: false };
const runtimeStatus = { runtime: { reload_drift: { restart_needed: false } }, capabilities: {} };
const strategyPayload = { status: "success", message: "ok", data: { board_updates: [], board_tasks: [] } };
const strategyStat = { mtimeMs: Date.now() };

__setOverrides({
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
  listProjects: async () => ["codex-agent-system"],
  readCodexAuthHealth: async () => authHealth,
  readRuntimeDashboardStatus: async () => runtimeStatus,
  fspStat: async () => strategyStat,
});

(async () => {
  const basic = await readDashboardArtifacts();
  assert.equal(basic.summarySnapshot, summarySnapshot);
  assert.equal(basic.settings, settings);
  assert.equal(basic.externalSignals, externalSignals);
  assert.equal(Array.isArray(basic.projects), true);
  assert.equal(basic.projects.length, 0);
  assert.equal(basic.authHealth, authHealth);
  assert.equal(basic.runtimeDashboardStatus, runtimeStatus);
  assert.equal(basic.strategyLatestPayload, null);
  assert.equal(basic.strategyLatestStat, null);

  const expanded = await readDashboardArtifacts({ includeProjects: true, includeStrategyLatest: true });
  assert.equal(Array.isArray(expanded.projects), true);
  assert.equal(expanded.projects.length, 1);
  assert.equal(expanded.projects[0], "codex-agent-system");
  assert.equal(expanded.strategyLatestPayload, strategyPayload);
  assert.equal(expanded.strategyLatestStat, strategyStat);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
JS

echo "dashboard artifact bundle test passed"
