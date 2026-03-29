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
  local port=4980
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
  "$TEST_ROOT/projects/other-project" \
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

cat >"$TEST_ROOT/projects/other-project/project.json" <<EOF
{
  "project": "other-project",
  "project_id": "other-project",
  "workspace": "$TEST_ROOT",
  "repo_url": "https://example.com/other-project.git",
  "memory_file": "$TEST_ROOT/projects/other-project/memory.md",
  "spec_file": "$TEST_ROOT/projects/other-project/spec.md",
  "policy_file": "$TEST_ROOT/projects/other-project/policy.json",
  "task_registry_file": "$TEST_ROOT/projects/other-project/tasks.json"
}
EOF

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys

payload = {
    "tasks": [
        {
            "id": "task-self-improve",
            "title": "Expose self-improve project summaries",
            "project": "codex-agent-system",
            "category": "stability",
            "status": "pending_approval",
            "score": 2.4,
            "created_at": "2026-03-25T01:00:00Z",
            "updated_at": "2026-03-25T01:00:00Z",
            "reason": "x" * 530000,
        },
        {
            "id": "task-other",
            "title": "Unrelated project task",
            "project": "other-project",
            "category": "ui",
            "status": "approved",
            "score": 1.8,
            "created_at": "2026-03-25T01:00:00Z",
            "updated_at": "2026-03-25T01:00:00Z",
        },
    ]
}

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, indent=2)
    handle.write("\n")
PY

cat >"$TEST_ROOT/projects/other-project/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-other-dedicated",
      "title": "Smaller dedicated registry task",
      "project": "other-project",
      "category": "ui",
      "status": "approved",
      "score": 1.1,
      "created_at": "2026-03-25T01:00:00Z",
      "updated_at": "2026-03-25T01:00:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-learning/self-improve-run.json" <<'EOF'
{
  "status": "success",
  "project": "codex-agent-system",
  "generated_at": "2026-03-25T01:31:29Z",
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
    "backlog_gate_active": false,
    "overload": {
      "active": true,
      "preserved_title": "Improve retry failure classification coverage",
      "preserved_reason": "highest_unblocked_score",
      "candidate_count": 4,
      "blocked_candidate_count": 1,
      "candidates": [
        {
          "title": "Improve retry failure classification coverage",
          "blocked": false,
          "blocked_reason": "none",
          "score": 47,
          "static_priority": 35,
          "signal_priority": 12,
          "recent_failures_since_latest_success": 0,
          "recent_self_improve_failures": 0
        }
      ]
    }
  },
  "metrics_input": {
    "status": "refreshed",
    "refresh_performed": true,
    "reason": "missing_required_keys",
    "missing_keys": []
  },
  "metrics_snapshot": {
    "retry_classification_coverage": 0.22,
    "retry_classified_count": 13,
    "retry_total_count": 58
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-25T01:31:29Z"
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
project=codex-agent-system
task=Expose self-improve project summaries
last_result=NONE
note=queued_at=2026-03-25T01:31:29Z
updated_at=2026-03-25T01:31:29Z
EOF

cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "total_tasks": 2,
  "success_rate": 0.5,
  "timeout_failure_records": 0,
  "timeout_failure_rate": 0,
  "analysis_runs": 2,
  "pending_approval_tasks": 1,
  "approved_tasks": 1,
  "task_registry_total": 2,
  "last_task_score": 2.4,
  "manual_recovery_records": 0
}
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

projects = {entry["project"]: entry for entry in payload["projects"]}
primary = projects["codex-agent-system"]["self_improve_summary"]
secondary = projects["other-project"]["self_improve_summary"]
primary_pressure = projects["codex-agent-system"]["task_registry_pressure"]
secondary_pressure = projects["other-project"]["task_registry_pressure"]
primary_overview = projects["codex-agent-system"]["project_overview_signal"]
secondary_overview = projects["other-project"]["project_overview_signal"]

assert primary["status"] == "success", primary
assert primary["scoped_to_project"] is True, primary
assert primary["source_project"] == "codex-agent-system", primary
assert primary["counts"]["submitted"] == 1, primary
assert primary["gating"]["dominant_reason"] == "submission_limit", primary
assert primary["gating"]["overload"]["active"] is True, primary
assert primary["gating"]["overload"]["preserved_title"] == "Improve retry failure classification coverage", primary
assert primary["metrics_input"]["status"] == "refreshed", primary
assert primary["metrics_input"]["reason"] == "missing_required_keys", primary
assert primary["operator_signal"]["kind"] == "retry_classification_coverage_low", primary
assert primary["operator_signal"]["summary"] == "22% classified (13/58 retries); self-improve prioritized Improve retry failure classification coverage.", primary
assert primary_overview["active"] is True, primary_overview
assert primary_overview["source"] == "self_improve", primary_overview
assert primary_overview["kind"] == "retry_classification_coverage_low", primary_overview
assert primary_overview["title"] == "Low retry classification coverage", primary_overview
assert primary_overview["summary"] == "22% classified (13/58 retries); self-improve prioritized Improve retry failure classification coverage.", primary_overview

assert secondary["status"] == "unavailable", secondary
assert secondary["scoped_to_project"] is False, secondary
assert secondary["source_project"] == "codex-agent-system", secondary
assert secondary["counts"]["submitted"] == 0, secondary

assert primary_pressure["detected"] is True, primary_pressure
assert primary_pressure["dominant"] is True, primary_pressure
assert primary_pressure["payload_bytes"] > secondary_pressure["payload_bytes"], (primary_pressure, secondary_pressure)
assert primary_pressure["share_of_total"] > secondary_pressure["share_of_total"], (primary_pressure, secondary_pressure)
assert primary_pressure["shared_projects"] == ["codex-agent-system"], primary_pressure
assert primary_pressure["file"].endswith("/codex-memory/tasks.json"), primary_pressure
assert primary_pressure["headline"] == "Dominant registry pressure", primary_pressure
assert primary_pressure["summary"].endswith("of dashboard payload"), primary_pressure
assert primary_pressure["source_label"] == "codex-memory/tasks.json", primary_pressure

assert secondary_pressure["detected"] is True, secondary_pressure
assert secondary_pressure["dominant"] is False, secondary_pressure
assert secondary_pressure["shared_projects"] == ["other-project"], secondary_pressure
assert secondary_pressure["file"].endswith("/projects/other-project/tasks.json"), secondary_pressure
assert secondary_pressure["headline"] == "Registry pressure contributor", secondary_pressure
assert secondary_pressure["summary"].endswith("of dashboard payload"), secondary_pressure
assert secondary_pressure["source_label"] == "other-project/tasks.json", secondary_pressure
assert secondary_overview["active"] is True, secondary_overview
assert secondary_overview["source"] == "task_registry_pressure", secondary_overview
assert secondary_overview["kind"] == "task_registry_pressure_contributor", secondary_overview
assert secondary_overview["title"] == "Registry pressure contributor", secondary_overview
assert secondary_overview["summary"] == secondary_pressure["summary"], (secondary_overview, secondary_pressure)
assert secondary_overview["detail"] == "other-project/tasks.json", secondary_overview
PY

echo "dashboard project summaries self-improve test passed"
