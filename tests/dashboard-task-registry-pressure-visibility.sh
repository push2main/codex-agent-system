#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR/codex-dashboard/index.html" <<'NODE'
const fs = require("fs");

const [htmlPath] = process.argv.slice(2);
const html = fs.readFileSync(htmlPath, "utf8");

const checks = [
  /function formatBytes\(value\)\s*\{/,
  /const taskRegistryPressure = summary\.taskRegistryPressure \|\| \{\};/,
  /label:\s*"Registry pressure"/,
  /tone:\s*taskRegistryPressureDetected\s*\?\s*"warning"\s*:\s*"accent"/,
  /Registry pressure \$\{formatBytes\(taskRegistryPressureBytes\)\} on \$\{taskRegistryPressureSurface\}\./,
];

for (const pattern of checks) {
  if (!pattern.test(html)) {
    throw new Error(`missing expected task-registry pressure visibility rule: ${pattern}`);
  }
}

console.log("dashboard task-registry pressure visibility test passed");
NODE
