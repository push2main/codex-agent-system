#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node - "$ROOT_DIR/codex-dashboard/index.html" <<'JS'
const assert = require("assert/strict");
const fs = require("fs");
const vm = require("vm");

const htmlPath = process.argv[2];
const html = fs.readFileSync(htmlPath, "utf8");
const match = html.match(
  /function createCoalescedAsyncRunner\(task, onError\) \{[\s\S]*?\n      \}\n\n      function renderProjects/,
);

if (!match) {
  throw new Error("createCoalescedAsyncRunner definition not found");
}

const helperSource = match[0].replace(/\n\n      function renderProjects$/, "");
const sandbox = {
  module: { exports: {} },
  exports: {},
  setTimeout,
  clearTimeout,
  Promise,
};

vm.runInNewContext(`${helperSource}\nmodule.exports = { createCoalescedAsyncRunner };`, sandbox, {
  filename: htmlPath,
});

const { createCoalescedAsyncRunner } = sandbox.module.exports;

function deferred() {
  let resolve;
  const promise = new Promise((r) => {
    resolve = r;
  });
  return { promise, resolve };
}

(async () => {
  const barriers = [deferred(), deferred()];
  let callCount = 0;
  const runner = createCoalescedAsyncRunner(async () => {
    const index = callCount;
    callCount += 1;
    await barriers[index].promise;
  });

  const first = runner();
  const second = runner();

  assert.equal(callCount, 1);

  barriers[0].resolve();
  for (let attempt = 0; attempt < 20 && callCount < 2; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  assert.equal(callCount, 2);

  barriers[1].resolve();
  await first;
  await second;
  assert.equal(callCount, 2);

  let seenError = "";
  const failingRunner = createCoalescedAsyncRunner(
    async () => {
      throw new Error("boom");
    },
    (error) => {
      seenError = error.message;
    },
  );

  await failingRunner();
  assert.equal(seenError, "boom");

  let recoveryCount = 0;
  const recoveryRunner = createCoalescedAsyncRunner(async () => {
    recoveryCount += 1;
  });
  await recoveryRunner();
  await recoveryRunner();
  assert.equal(recoveryCount, 2);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
JS

echo "dashboard refresh coalescing test passed"
