#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR/codex-dashboard/index.html" <<'NODE'
const fs = require("fs");

const [htmlPath] = process.argv.slice(2);
const html = fs.readFileSync(htmlPath, "utf8");

const checks = [
  /@media \(min-width: 1180px\)\s*\{/,
  /\.layout\.console-layout\s*\{\s*grid-template-columns:\s*minmax\(0,\s*1\.38fr\)\s*minmax\(360px,\s*420px\);/m,
  /\.task-board-shell\s*\{\s*grid-template-columns:\s*minmax\(0,\s*1\.28fr\)\s*minmax\(320px,\s*0\.72fr\);/m,
  /\.task-board\s*\{[\s\S]*?grid-template-columns:\s*repeat\(2,\s*minmax\(0,\s*1fr\)\);/m,
  /\.task-column \.list\s*\{\s*max-height:\s*min\(68vh,\s*1100px\);\s*overflow:\s*auto;/m,
  /\.live-work-strip\s*\{\s*grid-column:\s*2;\s*grid-row:\s*7\s*\/\s*span\s*2;\s*position:\s*sticky;/m,
  /\.task-column\[data-task-scope="other"\] \.list\s*\{\s*display:\s*grid;\s*grid-template-columns:\s*repeat\(2,\s*minmax\(0,\s*1fr\)\);/m,
];

for (const pattern of checks) {
  if (!pattern.test(html)) {
    throw new Error(`missing expected desktop layout rule: ${pattern}`);
  }
}

console.log("dashboard desktop layout test passed");
NODE
