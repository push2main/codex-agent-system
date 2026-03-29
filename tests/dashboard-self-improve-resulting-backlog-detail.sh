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
  local port=5030
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

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-26T02:21:52Z"
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
state=idle
project=codex-agent-system
task=
last_result=NONE
updated_at=2026-03-26T02:21:52Z
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 240,
  "success_rate": 0.14,
  "timeout_failure_records": 43,
  "timeout_failure_rate": 0.18,
  "analysis_runs": 6,
  "pending_approval_tasks": 3,
  "approved_tasks": 1,
  "task_registry_total": 0,
  "last_task_score": 1.2,
  "manual_recovery_records": 0
}
EOF

cat >"$TEST_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "codex-agent-system",
  "generated_at": "2026-03-26T02:21:52Z",
  "counts": {
    "detected": 2,
    "generated": 2,
    "submitted": 1,
    "skipped": 1,
    "blocked_analysis": 0
  },
  "gating": {
    "dominant_reason": "submission_limit",
    "analysis_reason": "none",
    "submission_reason": "critical_low_success_rate",
    "active_self_improve_count": 3,
    "resulting_active_self_improve_count": 4,
    "active_self_improve_cap": 3,
    "backlog_bypass_active": true,
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
    "status": "complete",
    "refresh_performed": false,
    "reason": "complete_snapshot",
    "missing_keys": []
  },
  "metrics_snapshot": {
    "success_rate": 0.14,
    "retry_classification_coverage": 0.82,
    "retry_classified_count": 41,
    "retry_total_count": 50,
    "zero_step_timeout_rate": 0.93,
    "diagnostic_coverage": 1.0,
    "failures_with_diagnostic": 43,
    "total_failure_records": 43
  }
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
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
            summaries = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard endpoint did not become ready")

summary = summaries["projects"][0]["self_improve_summary"]
overview = summaries["projects"][0]["project_overview_signal"]

assert summary["gating"]["active_self_improve_count"] == 3, summary
assert summary["gating"]["resulting_active_self_improve_count"] == 4, summary
assert overview["source"] == "self_improve", overview
assert overview["kind"] == "zero_step_timeout_pressure_high", overview
assert overview["detail"] == "Active self-improve backlog 4/3.", overview
PY

echo "dashboard self-improve resulting backlog detail test passed"
