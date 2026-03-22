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
  extractFunction("renderActiveTasks"),
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
  var activityTarget = {
    className: "activity-strip",
    innerHTML: "",
    classList: {
      add: function (name) {
        activityTarget.className = activityTarget.className.includes(name) ? activityTarget.className : activityTarget.className + " " + name;
      },
      remove: function (name) {
        activityTarget.className = activityTarget.className.replace(name, "").replace(/\\s+/g, " ").trim();
      }
    }
  };
  document = {
    querySelector: function (selector) {
      if (selector === "#activity-strip") {
        return activityTarget;
      }
      throw new Error("unexpected selector " + selector);
    }
  };
  escapeHtml = function (value) {
    return String(value ?? "");
  };
  renderActiveTasks([
    {
      title: "Parallel UI task",
      provider: "claude",
      lane: "lane-2",
      attempt: 1,
      step_count: 4,
      completed_steps: 2
    }
  ]);
  result.activityVisible = activityTarget.className.includes("visible");
  result.activityHtml = activityTarget.innerHTML;
  renderActiveTasks([]);
  result.activityHidden = !activityTarget.className.includes("visible") && activityTarget.innerHTML === "";
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
if (context.result.activityVisible !== true) {
  throw new Error("active task strip should become visible when active tasks exist");
}
if (!context.result.activityHtml.includes("claude") || !context.result.activityHtml.includes("lane-2")) {
  throw new Error("active task strip should render provider and lane badges");
}
if (context.result.activityHidden !== true) {
  throw new Error("active task strip should hide itself when no active tasks exist");
}

console.log("dashboard task visibility test passed");
PY
