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
  "updated_at": "2026-03-29T15:38:09Z"
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
updated_at=2026-03-29T15:38:09Z
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 10,
  "success_rate": 0.13,
  "timeout_failure_records": 2,
  "timeout_failure_rate": 0.2,
  "analysis_runs": 0,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "last_task_score": 0,
  "manual_recovery_records": 0
}
EOF

cat >"$TEST_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "codex-agent-system",
  "generated_at": "2026-03-29T15:38:09Z",
  "counts": {
    "detected": 0,
    "generated": 0,
    "submitted": 0,
    "skipped": 0,
    "blocked_analysis": 0
  },
  "pause": {
    "active": true,
    "reason": "paused_by_file",
    "file": "/tmp/repo/codex-logs/self-improve-paused",
    "detected_at": "2026-03-28T10:29:42Z",
    "age_seconds": 90000,
    "escalation": {
      "active": true,
      "kind": "pause_age_threshold",
      "severity": "warning",
      "threshold_seconds": 21600,
      "title": "Long-lived self-improve pause",
      "summary": "Self-improve has been paused for 90000s, exceeding the 21600s review threshold."
    },
    "remediation": {
      "active": true,
      "kind": "remove_pause_file",
      "title": "Remove self-improve pause gate",
      "summary": "Delete /tmp/repo/codex-logs/self-improve-paused and rerun self-improve when autonomous improvement should resume.",
      "command": "rm -f /tmp/repo/codex-logs/self-improve-paused && bash scripts/self-improve.sh codex-agent-system"
    }
  },
  "gating": {
    "dominant_reason": "paused_by_file",
    "analysis_reason": "paused_by_file",
    "submission_reason": "paused_by_file"
  },
  "metrics_input": {
    "status": "complete",
    "refresh_performed": false,
    "reason": "complete_snapshot",
    "missing_keys": []
  },
  "metrics_snapshot": {
    "zero_step_timeout_rate": 0.91
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
        with urllib.request.urlopen(f"{base_url}/api/dashboard", timeout=1) as response:
            dashboard = json.load(response)
        with urllib.request.urlopen(f"{base_url}/api/project-summaries", timeout=1) as response:
            summaries = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard endpoints did not become ready")

self_improve = dashboard["metrics"]["selfImprove"]
summary = summaries["projects"][0]["self_improve_summary"]
overview = summaries["projects"][0]["project_overview_signal"]

expected_summary = "Self-improve has been paused for 90000s, exceeding the 21600s review threshold."
expected_remediation = "Delete /tmp/repo/codex-logs/self-improve-paused and rerun self-improve when autonomous improvement should resume."

assert self_improve["pause"]["active"] is True, self_improve
assert self_improve["pause"]["escalation"]["active"] is True, self_improve
assert self_improve["operator_signal"]["kind"] == "self_improve_pause_escalated", self_improve
assert self_improve["operator_signal"]["title"] == "Long-lived self-improve pause", self_improve
assert self_improve["operator_signal"]["summary"] == expected_summary, self_improve
assert self_improve["operator_signal"]["remediation"]["summary"] == expected_remediation, self_improve

assert summary["operator_signal"]["kind"] == "self_improve_pause_escalated", summary
assert summary["operator_signal"]["summary"] == expected_summary, summary

assert overview["source"] == "self_improve", overview
assert overview["kind"] == "self_improve_pause_escalated", overview
assert overview["summary"] == expected_summary, overview
assert overview["detail"] == expected_remediation, overview
assert overview["command"] == "rm -f /tmp/repo/codex-logs/self-improve-paused && bash scripts/self-improve.sh codex-agent-system", overview
PY

echo "dashboard self-improve pause escalation signal test passed"
