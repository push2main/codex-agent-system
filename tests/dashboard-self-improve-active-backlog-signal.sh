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

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-25T18:05:00Z"
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
updated_at=2026-03-25T18:05:00Z
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 10,
  "success_rate": 0.2,
  "timeout_failure_records": 1,
  "timeout_failure_rate": 0.1,
  "analysis_runs": 3,
  "pending_approval_tasks": 2,
  "approved_tasks": 1,
  "task_registry_total": 0,
  "last_task_score": 2.1,
  "manual_recovery_records": 0
}
EOF

cat >"$TEST_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "codex-agent-system",
  "generated_at": "2026-03-25T18:05:00Z",
  "counts": {
    "detected": 1,
    "generated": 1,
    "submitted": 0,
    "skipped": 1,
    "blocked_analysis": 0
  },
  "gating": {
    "dominant_reason": "submission_limit",
    "analysis_reason": "none",
    "submission_reason": "active_self_improve_backlog",
    "active_self_improve_count": 3,
    "active_self_improve_cap": 3,
    "backlog_bypass_active": false,
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
    "success_rate": 0.12
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

expected_summary = "3/3 active self-improve tasks are already pending, approved, queued, or running; new improvements stay blocked until the backlog drains."
expected_remediation = "Complete, reject, or shelve one active self-improve task before generating another experiment."

assert self_improve["gating"]["active_self_improve_count"] == 3, self_improve
assert self_improve["gating"]["active_self_improve_cap"] == 3, self_improve
assert self_improve["operator_signal"]["kind"] == "active_self_improve_backlog", self_improve
assert self_improve["operator_signal"]["title"] == "Active self-improve backlog is full", self_improve
assert self_improve["operator_signal"]["summary"] == expected_summary, self_improve
assert self_improve["operator_signal"]["remediation"]["summary"] == expected_remediation, self_improve

assert summary["operator_signal"]["kind"] == "active_self_improve_backlog", summary
assert summary["operator_signal"]["summary"] == expected_summary, summary
assert summary["gating"]["active_self_improve_count"] == 3, summary
assert summary["gating"]["active_self_improve_cap"] == 3, summary

assert overview["source"] == "self_improve", overview
assert overview["kind"] == "active_self_improve_backlog", overview
assert overview["summary"] == expected_summary, overview
assert overview["detail"] == "Active self-improve backlog 3/3.", overview
PY

echo "dashboard self-improve active backlog signal test passed"
