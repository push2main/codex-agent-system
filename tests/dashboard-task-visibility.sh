#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR/codex-dashboard/index.html" "$ROOT_DIR/codex-memory/tasks.json" <<'PY'
const fs = require("fs");
const vm = require("vm");

const [htmlPath, tasksPath] = process.argv.slice(2);
const html = fs.readFileSync(htmlPath, "utf8");
const tasks = JSON.parse(fs.readFileSync(tasksPath, "utf8")).tasks;

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
  extractFunction("taskStatusValue"),
  extractFunction("isHistoricalHandoff"),
  extractFunction("primaryOutcomeTag"),
  extractFunction("showHandoffStatusTag"),
  extractFunction("handoffDetailLabel"),
  `
  result.completed = tasks.find((task) => task.status === "completed");
  result.failed = tasks.find((task) => task.status === "failed");
  result.rejected = tasks.find((task) => task.status === "rejected");
  result.completedTag = primaryOutcomeTag(result.completed);
  result.failedTag = primaryOutcomeTag(result.failed);
  result.rejectedTag = primaryOutcomeTag(result.rejected);
  result.completedHandoffVisible = showHandoffStatusTag(result.completed);
  result.failedHandoffVisible = showHandoffStatusTag(result.failed);
  result.rejectedHandoffVisible = showHandoffStatusTag(result.rejected);
  result.completedHandoffLabel = handoffDetailLabel(result.completed);
  `,
].join("\n");

const context = vm.createContext({ tasks });
vm.runInContext(source, context);

if (!context.result.completed || !context.result.failed || !context.result.rejected) {
  throw new Error("expected completed, failed, and rejected tasks in fixture");
}
if (context.result.completedTag?.label !== "implemented") {
  throw new Error("completed task should render implemented tag");
}
if (context.result.failedTag?.label !== "implementation failed") {
  throw new Error("failed task should render implementation failed tag");
}
if (context.result.rejectedTag?.label !== "not approved") {
  throw new Error("rejected task should render not approved tag");
}
if (context.result.completedHandoffVisible !== false) {
  throw new Error("completed tasks should hide active handoff status");
}
if (context.result.failedHandoffVisible !== false) {
  throw new Error("failed tasks should hide active handoff status");
}
if (context.result.rejectedHandoffVisible !== false) {
  throw new Error("rejected tasks should hide active handoff status");
}
if (context.result.completedHandoffLabel !== "queued earlier") {
  throw new Error("completed tasks should describe handoff as historical");
}

console.log("dashboard task visibility test passed");
PY
