#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR/codex-dashboard/index.html" <<'PY'
const fs = require("fs");
const vm = require("vm");

const [htmlPath] = process.argv.slice(2);
const html = fs.readFileSync(htmlPath, "utf8");

function extractFunction(name) {
  const pattern = new RegExp(`function ${name}\\([^)]*\\) \\{[\\s\\S]*?\\n      \\}`, "m");
  const match = html.match(pattern);
  if (!match) {
    throw new Error(`missing function ${name}`);
  }
  return match[0];
}

const source = [
  "var result = {};",
  extractFunction("tagTone"),
  extractFunction("formatActionLabel"),
  extractFunction("renderExecutionDetails"),
  `
  escapeHtml = function (value) {
    return String(value ?? "");
  };
  result.visible = renderExecutionDetails({
    execution: {
      state: "completed",
      result: "SUCCESS",
      attempt: 2,
      max_retries: 2,
      total_step_attempts: 5,
      updated_at: "2026-03-23T17:05:00Z"
    },
    history_preview: []
  });
  result.hidden = renderExecutionDetails({
    execution: {
      state: "completed",
      result: "SUCCESS",
      attempt: 2,
      max_retries: 2,
      total_step_attempts: 2,
      updated_at: "2026-03-23T17:05:00Z"
    },
    history_preview: []
  });
  `,
].join("\n");

const context = vm.createContext({});
vm.runInContext(source, context);

if (!context.result.visible.includes("attempt 2/2")) {
  throw new Error("expected bounded retry tag in execution details");
}
if (!context.result.visible.includes("5 step attempts")) {
  throw new Error("expected aggregate loop-effort tag in execution details");
}
if (context.result.hidden.includes("2 step attempts")) {
  throw new Error("did not expect redundant loop-effort tag when counts match");
}

console.log("dashboard loop effort visibility test passed");
PY
