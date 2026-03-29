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
  "$TEST_ROOT/projects/codex-agent-system" \
  "$TEST_ROOT/queues"

cat >"$TEST_ROOT/projects/codex-agent-system/project.json" <<EOF
{
  "project": "codex-agent-system",
  "project_id": "codex-agent-system",
  "workspace": "$TEST_ROOT",
  "repo_url": "https://example.com/codex-agent-system.git",
  "memory_file": "$TEST_ROOT/projects/codex-agent-system/memory.md",
  "spec_file": "$TEST_ROOT/projects/codex-agent-system/spec.md",
  "policy_file": "$TEST_ROOT/projects/codex-agent-system/policy.json",
  "task_registry_file": "$TEST_ROOT/codex-memory/tasks.json"
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$TEST_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "codex-agent-system",
  "generated_at": "2026-03-25T08:30:00Z",
  "counts": {
    "detected": 1,
    "generated": 0,
    "submitted": 0,
    "skipped": 1,
    "blocked_analysis": 0
  },
  "gating": {
    "dominant_reason": "none",
    "analysis_reason": "none",
    "submission_reason": "none",
    "backlog_gate_active": false,
    "overload": {
      "active": false,
      "preserved_title": "",
      "preserved_reason": "inactive",
      "candidate_count": 0,
      "blocked_candidate_count": 0,
      "candidates": []
    }
  },
  "metrics_input": {
    "status": "refreshed",
    "refresh_performed": true,
    "reason": "stale_against_tasks_json",
    "missing_keys": []
  },
  "metrics_snapshot": {
    "retry_classification_coverage": 0.75,
    "retry_classified_count": 6,
    "retry_total_count": 8
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-25T08:30:00Z"
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

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 0,
  "success_rate": 1,
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 1,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "last_task_score": 0,
  "manual_recovery_records": 0
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=idle
project=codex-agent-system
task=
last_result=SUCCESS
updated_at=2026-03-25T08:30:00Z
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-memory/context.md"
: >"$TEST_ROOT/codex-memory/decisions.md"
: >"$TEST_ROOT/codex-memory/learnings.md"
cat >"$TEST_ROOT/codex-memory/knowledge.json" <<'EOF'
{"rules":[]}
EOF
: >"$TEST_ROOT/codex-logs/system.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
DASHBOARD_SETTINGS_FILE="$TEST_ROOT/codex-memory/dashboard-settings.json" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_ROOT/codex-logs/system.log" \
DASHBOARD_METRICS_FILE="$TEST_ROOT/codex-learning/metrics.json" \
DASHBOARD_SELF_IMPROVE_RUN_FILE="$TEST_ROOT/codex-learning/self-improve-run.json" \
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
        with urllib.request.urlopen(f"{base_url}/api/project-summaries", timeout=1) as response:
            payload = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("project summaries endpoint did not become ready")

summary = payload["projects"][0]["self_improve_summary"]
overview = payload["projects"][0]["project_overview_signal"]

assert summary["metrics_input"]["status"] == "refreshed", summary
assert summary["metrics_input"]["reason"] == "stale_against_tasks_json", summary
assert summary["operator_signal"]["kind"] == "metrics_input_stale_refresh", summary
assert summary["operator_signal"]["title"] == "Refreshed stale self-improve metrics", summary
assert summary["operator_signal"]["summary"] == "Self-improve refreshed stale metrics before ranking improvements because tasks.json was newer than metrics.json.", summary
assert overview["active"] is True, overview
assert overview["source"] == "self_improve", overview
assert overview["kind"] == "metrics_input_stale_refresh", overview
assert overview["title"] == "Refreshed stale self-improve metrics", overview
assert overview["summary"] == "Self-improve refreshed stale metrics before ranking improvements because tasks.json was newer than metrics.json.", overview
PY

echo "dashboard self-improve metrics input signal test passed"
