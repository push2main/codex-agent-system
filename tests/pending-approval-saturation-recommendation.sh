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
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-saturation-recovery",
      "title": "Choose a different bounded experiment after strategy saturation stalls the board",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "pending_approval",
      "strategy_template": "strategy_saturation_rescue",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z",
      "saturation_recovery": {
        "kind": "replace_saturated_experiment",
        "replaces_task_id": "task-learning-2",
        "replaces_title": "Feed execution learning back into future provider and task decisions",
        "replaces_strategy_template": "enterprise_learning_feedback",
        "replaces_category": "code_quality"
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-24T09:00:00Z"
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=idle
project=
task=
last_result=NONE
note=waiting_for_approval=1
updated_at=2026-03-24T09:00:00Z
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pending_approval_tasks": 1,
  "approved_tasks": 0,
  "task_registry_total": 1,
  "pending_approval_blocked_detected": true,
  "queue_starvation_detected": false,
  "retry_churn_detected": false
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_PRIORITY_FILE="$TEST_ROOT/codex-memory/priority.json" \
DASHBOARD_TASK_LOG_FILE="$TEST_ROOT/codex-memory/tasks.log" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_STATUS_FILE="$TEST_ROOT/status.txt" \
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
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            registry = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard saturation recommendation endpoint did not become ready")

summary = registry["summary"]
assert summary["approvalRecommendation"]["task_id"] == "task-saturation-recovery"
assert summary["approvalRecommendation"]["saturation_recovery"] == {
    "kind": "replace_saturated_experiment",
    "replaces_task_id": "task-learning-2",
    "replaces_title": "Feed execution learning back into future provider and task decisions",
    "replaces_strategy_template": "enterprise_learning_feedback",
    "replaces_category": "code_quality",
}
assert summary["approvalRecommendation"]["reason"] == (
    "Review the saturation-recovery task: Replace Feed execution learning back into future provider and task decisions with a different bounded experiment."
)
assert summary["nextAction"]["state"] == "approval"
assert summary["nextAction"]["message"] == (
    "Review saturation recovery: Replace Feed execution learning back into future provider and task decisions with a different bounded experiment"
)

with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
    metrics = json.load(response)

assert metrics["approvalRecommendation"]["saturation_recovery"]["replaces_task_id"] == "task-learning-2"
assert metrics["nextAction"]["message"] == (
    "Review saturation recovery: Replace Feed execution learning back into future provider and task decisions with a different bounded experiment"
)
PY

echo "pending approval saturation recommendation test passed"
