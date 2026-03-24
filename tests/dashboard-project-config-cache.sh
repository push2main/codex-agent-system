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
  local port=5090
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
  "tasks": []
}
EOF

cat >"$TEST_ROOT/projects/cache-smoke/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-cache-a",
      "title": "Cache project config reads for dashboard polling",
      "project": "cache-smoke",
      "category": "stability",
      "status": "pending_approval",
      "score": 2.8,
      "created_at": "2026-03-24T03:00:00Z",
      "updated_at": "2026-03-24T03:00:00Z",
      "task_intent": {
        "source": "dashboard_backlog",
        "objective": "Cache project config reads for dashboard polling",
        "project": "cache-smoke",
        "category": "stability",
        "context_hint": "auth workflow",
        "constraints": [],
        "success_signals": [],
        "affected_files": []
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/projects/cache-smoke/policy.json" <<'EOF'
{
  "project": "cache-smoke",
  "risk_profile": "strict",
  "auto_approve_allowed": true,
  "manual_review_required_keywords": ["auth workflow"]
}
EOF

cat >"$TEST_ROOT/projects/cache-smoke/project.json" <<EOF
{
  "project": "cache-smoke",
  "project_id": "cache-smoke",
  "workspace": "$TEST_ROOT/projects/cache-smoke",
  "repo_url": "https://example.com/cache-smoke",
  "policy_file": "$TEST_ROOT/projects/cache-smoke/policy.json",
  "task_registry_file": "$TEST_ROOT/projects/cache-smoke/tasks.json"
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-24T03:00:00Z"
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
  "last_task_score": 2.8,
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
task=Cache project config reads for dashboard polling
last_result=NONE
note=queued_at=2026-03-24T03:00:00Z
updated_at=2026-03-24T03:00:00Z
EOF

printf "Cache project config reads for dashboard polling\n" >"$TEST_ROOT/queues/cache-smoke.txt"
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

function recordRead(filePath) {
  const resolved = normalizePath(filePath);
  if (tracked.has(resolved)) {
    counts[resolved] = (counts[resolved] || 0) + 1;
  }
}

const originalReadFileSync = fs.readFileSync.bind(fs);
fs.readFileSync = function patchedReadFileSync(filePath, ...rest) {
  recordRead(filePath);
  return originalReadFileSync(filePath, ...rest);
};

const originalReadFile = fs.promises.readFile.bind(fs.promises);
fs.promises.readFile = async function patchedReadFile(filePath, ...rest) {
  recordRead(filePath);
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
TRACKED_PROJECT_FILE="$TEST_ROOT/projects/cache-smoke/project.json"
TRACKED_POLICY_FILE="$TEST_ROOT/projects/cache-smoke/policy.json"

NODE_OPTIONS="--require=$TMP_DIR/count-reads.js" \
READ_COUNT_LOG="$READ_COUNT_LOG" \
READ_COUNT_TRACKED="$TRACKED_PROJECT_FILE:$TRACKED_POLICY_FILE" \
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
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

python3 - "$DASHBOARD_PORT" "$TEST_ROOT/projects/cache-smoke/tasks.json" "$TRACKED_PROJECT_FILE" "$TRACKED_POLICY_FILE" <<'PY'
import json
import sys
import time
import urllib.request
from pathlib import Path

port = sys.argv[1]
tasks_path = Path(sys.argv[2])
project_path = Path(sys.argv[3])
policy_path = Path(sys.argv[4])
base_url = f"http://127.0.0.1:{port}"


def fetch_registry():
    with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=2) as response:
        return json.load(response)


for _ in range(30):
    try:
        payload = fetch_registry()
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard did not become ready")

task = payload["tasks"][0]
assert task["task_shape"]["manual_review_required"] is True
assert task["task_shape"]["risk_profile"] == "strict"

payload = fetch_registry()
assert payload["tasks"][0]["id"] == "task-cache-a"

tasks_path.write_text(
    json.dumps(
        {
            "tasks": [
                {
                    "id": "task-cache-b",
                    "title": "Cache project config reads for repeated registry rebuilds",
                    "project": "cache-smoke",
                    "category": "stability",
                    "status": "pending_approval",
                    "score": 3.0,
                    "created_at": "2026-03-24T03:01:00Z",
                    "updated_at": "2026-03-24T03:01:00Z",
                    "task_intent": {
                        "source": "dashboard_backlog",
                        "objective": "Cache project config reads for repeated registry rebuilds",
                        "project": "cache-smoke",
                        "category": "stability",
                        "context_hint": "auth workflow",
                        "constraints": [],
                        "success_signals": [],
                        "affected_files": [],
                    },
                }
            ]
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)

for _ in range(20):
    payload = fetch_registry()
    task = payload["tasks"][0]
    if task["id"] == "task-cache-b":
        break
    time.sleep(0.1)
else:
    raise SystemExit("dashboard did not reload task registry after task file change")

assert task["task_shape"]["manual_review_required"] is True

policy_path.write_text(
    json.dumps(
        {
            "project": "cache-smoke",
            "risk_profile": "standard",
            "auto_approve_allowed": True,
            "manual_review_required_keywords": [],
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)

for _ in range(20):
    payload = fetch_registry()
    task = payload["tasks"][0]
    if task["id"] == "task-cache-b" and task["task_shape"]["manual_review_required"] is False:
        break
    time.sleep(0.1)
else:
    raise SystemExit("dashboard did not invalidate task shaping after policy-only change")

assert task["task_shape"]["risk_profile"] == "standard"

project_path.write_text(
    json.dumps(
        {
            "project": "cache-smoke",
            "project_id": "cache-smoke",
            "workspace": str(project_path.parent),
            "repo_url": "https://example.com/cache-smoke",
            "policy_file": str(policy_path),
            "task_registry_file": str(tasks_path),
            "note": "signature bump to invalidate cached project metadata",
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
tasks_path.write_text(
    json.dumps(
        {
            "tasks": [
                {
                    "id": "task-cache-c",
                    "title": "Cache project config reads after config invalidation",
                    "project": "cache-smoke",
                    "category": "stability",
                    "status": "pending_approval",
                    "score": 3.2,
                    "created_at": "2026-03-24T03:02:00Z",
                    "updated_at": "2026-03-24T03:02:00Z",
                    "task_intent": {
                        "source": "dashboard_backlog",
                        "objective": "Cache project config reads after config invalidation",
                        "project": "cache-smoke",
                        "category": "stability",
                        "context_hint": "auth workflow",
                        "constraints": [],
                        "success_signals": [],
                        "affected_files": [],
                    },
                }
            ]
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)

for _ in range(20):
    payload = fetch_registry()
    task = payload["tasks"][0]
    if task["id"] == "task-cache-c":
        break
    time.sleep(0.1)
else:
    raise SystemExit("dashboard did not invalidate config caches after project or policy change")

assert task["task_shape"]["manual_review_required"] is False
assert task["task_shape"]["risk_profile"] == "standard"
PY

kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
DASHBOARD_PID=""

python3 - "$READ_COUNT_LOG" "$TRACKED_PROJECT_FILE" "$TRACKED_POLICY_FILE" <<'PY'
import json
import os
import sys
from pathlib import Path

counts_path = Path(sys.argv[1])
project_path = Path(sys.argv[2])
policy_path = Path(sys.argv[3])
counts = json.loads(counts_path.read_text(encoding="utf-8"))

def resolved(path_value: str) -> str:
    path = Path(path_value)
    return str(path.resolve() if path.exists() else Path(os.path.abspath(path_value)))

project_reads = counts.get(resolved(str(project_path)), 0)
policy_reads = counts.get(resolved(str(policy_path)), 0)

assert project_reads == 2, f"expected two project.json reads across initial load and config invalidation, observed {project_reads}"
assert policy_reads == 2, f"expected two policy.json reads across initial load and policy-only invalidation, observed {policy_reads}"
PY

echo "dashboard project config cache test passed"
