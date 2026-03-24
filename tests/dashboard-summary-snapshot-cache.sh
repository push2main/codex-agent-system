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
  local port=4995
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
  "$TEST_ROOT/projects/registry-smoke" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-summary-cache",
      "title": "Cache repeated dashboard summary snapshots",
      "project": "registry-smoke",
      "category": "performance",
      "status": "running",
      "score": 3.4,
      "created_at": "2026-03-24T00:00:00Z",
      "updated_at": "2026-03-24T00:01:00Z",
      "execution": {
        "state": "running",
        "attempt": 1,
        "max_retries": 2
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-24T00:00:00Z"
}
EOF

cat >"$TEST_ROOT/codex-learning/external-signals.json" <<'EOF'
{
  "updated_at": "2026-03-24T00:00:00Z",
  "signals": [],
  "errors": []
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
state=running
project=registry-smoke
task=Cache repeated dashboard summary snapshots
last_result=NONE
note=lane=1
updated_at=2026-03-24T00:01:00Z
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 1,
  "success_rate": 0,
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 1,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 1,
  "last_task_score": 3.4,
  "manual_recovery_records": 0
}
EOF

printf '{"project":"registry-smoke","task":"Cache repeated dashboard summary snapshots","result":"SUCCESS","attempts":1,"score":1}\n' >"$TEST_ROOT/codex-memory/tasks.log"
printf "Cache repeated dashboard summary snapshots\n" >"$TEST_ROOT/queues/registry-smoke.txt"
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

TRACKED_FILES=(
  "$TEST_ROOT/codex-memory/tasks.json"
  "$TEST_ROOT/codex-memory/tasks.log"
  "$TEST_ROOT/status.txt"
  "$TEST_ROOT/queues/registry-smoke.txt"
)

TRACKED_PATHS="$(
  printf '%s:' "${TRACKED_FILES[@]}"
)"
TRACKED_PATHS="${TRACKED_PATHS%:}"

DASHBOARD_PORT="$(find_free_port)"
NODE_OPTIONS="--require=$TMP_DIR/count-reads.js" \
READ_COUNT_LOG="$READ_COUNT_LOG" \
READ_COUNT_TRACKED="$TRACKED_PATHS" \
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_EXTERNAL_SIGNALS_FILE="$TEST_ROOT/codex-learning/external-signals.json" \
DASHBOARD_STRATEGY_LATEST_FILE="$TEST_ROOT/codex-logs/strategy-latest.json" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
DASHBOARD_PROJECTS_DIR="$TEST_ROOT/projects" \
DASHBOARD_QUEUES_DIR="$TEST_ROOT/queues" \
node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" <<'PY'
import json
import sys
import time
import urllib.request

port = sys.argv[1]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/status", timeout=1) as response:
            payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

assert payload["project"] == "registry-smoke"

for route in ("/api/metrics", "/api/task-registry", "/api/dashboard"):
    with urllib.request.urlopen(f"{base_url}{route}", timeout=2) as response:
        payload = json.load(response)
    if route == "/api/metrics":
        assert payload["taskRegistryTotal"] == 1
    if route == "/api/task-registry":
        assert payload["tasks"][0]["id"] == "task-summary-cache"
    if route == "/api/dashboard":
        assert payload["taskRegistry"]["tasks"][0]["id"] == "task-summary-cache"
PY

kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
DASHBOARD_PID=""

python3 - "$READ_COUNT_LOG" "${TRACKED_FILES[@]}" <<'PY'
import json
import os
import sys
from pathlib import Path

counts_path = Path(sys.argv[1])
tracked = []
for value in sys.argv[2:]:
    path = Path(value)
    tracked.append(str(path.resolve() if path.exists() else Path(os.path.abspath(value))))
counts = json.loads(counts_path.read_text(encoding="utf-8"))

for file_path in tracked:
    observed = counts.get(file_path, 0)
    if observed != 1:
      raise SystemExit(f"expected exactly one read for {file_path}, observed {observed}")
PY

echo "dashboard summary snapshot cache test passed"
