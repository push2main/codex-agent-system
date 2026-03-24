#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
DASHBOARD_PID=""

cleanup() {
  if [ -n "$DASHBOARD_PID" ]; then
    kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
    wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

port_in_use() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

find_free_port() {
  local port=4990
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects/cache-smoke" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-cache-a",
      "title": "Cache unchanged dashboard registry reads",
      "project": "cache-smoke",
      "category": "performance",
      "status": "pending_approval",
      "score": 2.2,
      "created_at": "2026-03-24T02:00:00Z",
      "updated_at": "2026-03-24T02:00:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-24T02:00:00Z"
}
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 1,
  "success_rate": 0,
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 1,
  "pending_approval_tasks": 1,
  "approved_tasks": 0,
  "task_registry_total": 1,
  "last_task_score": 2.2,
  "manual_recovery_records": 0
}
EOF

cat >"$TEST_ROOT/codex-logs/strategy-latest.json" <<'EOF'
{
  "status": "success",
  "message": "Strategy health is available.",
  "data": {
    "board_updates": [],
    "board_tasks": []
  }
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=queued
project=cache-smoke
task=Cache unchanged dashboard registry reads
last_result=NONE
note=queued_at=2026-03-24T02:00:00Z
updated_at=2026-03-24T02:00:00Z
EOF

printf "Cache unchanged dashboard registry reads\n" >"$TEST_ROOT/queues/cache-smoke.txt"
: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

READ_COUNT_LOG="$TMP_DIR/read-counts.json"
cat >"$TMP_DIR/count-reads.js" <<'EOF'
const fs = require("fs");
const path = require("path");

function normalizePath(value) {
  try {
    return fs.realpathSync.native(value);
  } catch {
    return path.resolve(String(value));
  }
}

const tracked = new Set(
  String(process.env.READ_COUNT_TRACKED || "")
    .split(path.delimiter)
    .filter(Boolean)
    .map((value) => normalizePath(value)),
);
const logPath = process.env.READ_COUNT_LOG;
const counts = Object.create(null);
const originalReadFile = fs.promises.readFile.bind(fs.promises);

fs.promises.readFile = async function patchedReadFile(filePath, ...rest) {
  const resolved = normalizePath(filePath);
  if (tracked.has(resolved)) {
    counts[resolved] = (counts[resolved] || 0) + 1;
  }
  return originalReadFile(filePath, ...rest);
};

function persistCounts() {
  if (!logPath) {
    return;
  }
  fs.writeFileSync(logPath, `${JSON.stringify(counts, null, 2)}\n`, "utf8");
}

process.on("exit", persistCounts);
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    persistCounts();
    process.exit(0);
  });
}
EOF

DASHBOARD_PORT="$(find_free_port)"
TRACKED_TASKS_FILE="$TEST_ROOT/codex-memory/tasks.json"

NODE_OPTIONS="--require=$TMP_DIR/count-reads.js" \
READ_COUNT_LOG="$READ_COUNT_LOG" \
READ_COUNT_TRACKED="$TRACKED_TASKS_FILE" \
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TRACKED_TASKS_FILE" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_STRATEGY_LATEST_FILE="$TEST_ROOT/codex-logs/strategy-latest.json" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
DASHBOARD_PROJECTS_DIR="$TEST_ROOT/projects" \
DASHBOARD_QUEUES_DIR="$TEST_ROOT/queues" \
node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$TRACKED_TASKS_FILE" <<'PY'
import json
import sys
import time
import urllib.request
from pathlib import Path

port = sys.argv[1]
tasks_path = Path(sys.argv[2])
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

assert len(payload["tasks"]) == 1

with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=2) as response:
    metrics = json.load(response)
assert metrics["taskRegistryTotal"] == 1

updated_payload = {
    "tasks": [
        {
            "id": "task-cache-a",
            "title": "Cache unchanged dashboard registry reads",
            "project": "cache-smoke",
            "category": "performance",
            "status": "pending_approval",
            "score": 2.2,
            "created_at": "2026-03-24T02:00:00Z",
            "updated_at": "2026-03-24T02:00:00Z"
        },
        {
            "id": "task-cache-b",
            "title": "Invalidate cache after registry change with extra content",
            "project": "cache-smoke",
            "category": "performance",
            "status": "approved",
            "score": 3.1,
            "created_at": "2026-03-24T02:01:00Z",
            "updated_at": "2026-03-24T02:01:00Z",
            "reason": "extra bytes to force a new file signature"
        }
    ]
}
tasks_path.write_text(json.dumps(updated_payload, indent=2) + "\n", encoding="utf-8")

for _ in range(20):
    with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
        payload = json.load(response)
    if len(payload["tasks"]) == 2:
        break
    time.sleep(0.1)
else:
    raise SystemExit("dashboard did not invalidate the task-registry cache after file change")

ids = [task["id"] for task in payload["tasks"]]
assert ids == ["task-cache-b", "task-cache-a"], ids
PY

kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
DASHBOARD_PID=""

python3 - "$READ_COUNT_LOG" "$TRACKED_TASKS_FILE" <<'PY'
import json
import os
import sys
from pathlib import Path

counts_path = Path(sys.argv[1])
tracked_path = Path(sys.argv[2])
resolved = str(tracked_path.resolve() if tracked_path.exists() else Path(os.path.abspath(tracked_path)))
counts = json.loads(counts_path.read_text(encoding="utf-8"))
observed = counts.get(resolved, 0)
assert observed == 2, f"expected exactly two task-registry reads across cache hit + invalidation, observed {observed}"
PY

echo "dashboard task registry cache test passed"
