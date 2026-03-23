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
  local port=4810
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
      "id": "task-077-readiness-metric-cards",
      "title": "In `codex-dashboard/index.html`, extend `renderTaskSummary()` to append metric cards for the three readiness domains using the existing `[label, value]` pattern.",
      "category": "stability",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "project": "codex-agent-system",
      "reason": "Task task-057 failed while still spanning too much scope.",
      "experiment": "Execute only this bounded child step next: In `codex-dashboard/index.html`, extend `renderTaskSummary()` to append metric cards for the three readiness domains using the existing `[label, value]` pattern. Do not implement later plan steps from the parent task in the same run.",
      "strategy_template": "bounded_failed_step_child",
      "status": "pending_approval",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:00:00Z"
    },
    {
      "id": "task-074-external-signal-review",
      "title": "Review external signal: OpenAI Python releases - v2.29.0",
      "category": "code_quality",
      "impact": 7,
      "effort": 3,
      "confidence": 0.76,
      "project": "codex-agent-system",
      "reason": "External research surfaced a bounded release signal.",
      "strategy_template": "external_signal_review",
      "status": "pending_approval",
      "created_at": "2026-03-23T08:01:00Z",
      "updated_at": "2026-03-23T08:01:00Z"
    },
    {
      "id": "task-078-enterprise-mobile-console",
      "title": "Tighten the mobile dashboard into an enterprise control surface",
      "category": "ui",
      "impact": 8,
      "effort": 3,
      "confidence": 0.82,
      "project": "codex-agent-system",
      "reason": "Enterprise readiness still depends on a mobile dashboard that feels trustworthy on iPhone and iPad under active operations.",
      "strategy_template": "enterprise_mobile_console",
      "status": "pending_approval",
      "created_at": "2026-03-23T08:02:00Z",
      "updated_at": "2026-03-23T08:02:00Z"
    },
    {
      "id": "task-079-retry-health-followup",
      "title": "Patch only `codex-dashboard/server.js` so both booleans are derived deterministically from persisted task records, flowed through the current metrics and strategy health decision path, and explicitly force the board unhealthy whenever either signal is true",
      "category": "learning",
      "impact": 8,
      "effort": 2,
      "confidence": 0.86,
      "project": "codex-agent-system",
      "reason": "Task task-055 failed while still spanning too much scope.",
      "source_task_id": "strategy::retry-churn",
      "source_task_title": "Detect retry churn and queue starvation before strategy declares the board healthy",
      "root_source_task_id": "strategy::retry-churn",
      "original_failed_root_id": "strategy::retry-churn",
      "strategy_template": "bounded_failed_step_child",
      "status": "pending_approval",
      "created_at": "2026-03-23T08:03:00Z",
      "updated_at": "2026-03-23T08:03:00Z"
    },
    {
      "id": "task-080-first-pass-followup",
      "title": "Inspect only `scripts/lib.sh` and mirror the exact same successful-completed-task filter, first-pass rule, rate calculation, and threshold for the persisted metrics path",
      "category": "learning",
      "impact": 8,
      "effort": 2,
      "confidence": 0.86,
      "project": "codex-agent-system",
      "reason": "Task task-053 failed while still spanning too much scope.",
      "source_task_id": "strategy::first-pass-success",
      "source_task_title": "Detect low first-pass success before repeated retries dominate the board",
      "root_source_task_id": "strategy::first-pass-success",
      "original_failed_root_id": "strategy::first-pass-success",
      "strategy_template": "bounded_failed_step_child",
      "status": "pending_approval",
      "created_at": "2026-03-23T08:04:00Z",
      "updated_at": "2026-03-23T08:04:00Z"
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$TEST_ROOT" <<'PY'
import json
import os
import sys
import time
import urllib.request

port = sys.argv[1]
root = sys.argv[2]
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

tasks = {task["id"]: task for task in payload["tasks"]}
child = tasks["task-077-readiness-metric-cards"]
review = tasks["task-074-external-signal-review"]
enterprise = tasks["task-078-enterprise-mobile-console"]
retry_health = tasks["task-079-retry-health-followup"]
first_pass = tasks["task-080-first-pass-followup"]

assert child["title"] == "Add readiness metric cards to the task summary"
assert child["task_shape"]["approval_ready"] is True
assert child["task_intent"]["source"] == "strategy_followup"

assert review["title"] == "Check OpenAI Python releases - v2.29.0 impact on codex-agent-system"
assert review["task_shape"]["approval_ready"] is True
assert review["task_intent"]["source"] == "strategy_external_signal"

assert enterprise["title"] == "Tighten the mobile dashboard into an enterprise control surface"
assert enterprise["task_shape"]["approval_ready"] is True
assert enterprise["task_intent"]["source"] == "strategy_seed"
assert enterprise["task_intent"]["objective"] == enterprise["title"]

assert retry_health["title"] == "Make board health detect retry churn and queue starvation"
assert retry_health["task_shape"]["approval_ready"] is True
assert retry_health["task_intent"]["source"] == "strategy_followup"

assert first_pass["title"] == "Align persisted first-pass success metrics"
assert first_pass["task_shape"]["approval_ready"] is True
assert first_pass["task_intent"]["source"] == "strategy_followup"

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
    second_payload = json.load(response)

second_tasks = {task["id"]: task for task in second_payload["tasks"]}
assert second_tasks["task-077-readiness-metric-cards"]["title"] == "Add readiness metric cards to the task summary"
assert (
    second_tasks["task-074-external-signal-review"]["title"]
    == "Check OpenAI Python releases - v2.29.0 impact on codex-agent-system"
)
assert second_tasks["task-078-enterprise-mobile-console"]["task_intent"]["source"] == "strategy_seed"
assert second_tasks["task-079-retry-health-followup"]["title"] == "Make board health detect retry churn and queue starvation"
assert second_tasks["task-080-first-pass-followup"]["title"] == "Align persisted first-pass success metrics"

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

persisted_tasks = {task["id"]: task for task in persisted["tasks"]}
assert persisted_tasks["task-077-readiness-metric-cards"]["title"] == "Add readiness metric cards to the task summary"
assert persisted_tasks["task-074-external-signal-review"]["title"] == "Check OpenAI Python releases - v2.29.0 impact on codex-agent-system"
assert (
    persisted_tasks["task-078-enterprise-mobile-console"]["task_intent"]["source"] == "strategy_seed"
)
assert (
    persisted_tasks["task-078-enterprise-mobile-console"]["task_intent"]["objective"]
    == "Tighten the mobile dashboard into an enterprise control surface"
)
assert persisted_tasks["task-079-retry-health-followup"]["title"] == "Make board health detect retry churn and queue starvation"
assert persisted_tasks["task-080-first-pass-followup"]["title"] == "Align persisted first-pass success metrics"
assert persisted_tasks["task-077-readiness-metric-cards"]["history"][-1]["action"] == "auto_repair"
assert persisted_tasks["task-074-external-signal-review"]["history"][-1]["action"] == "auto_repair"
assert persisted_tasks["task-079-retry-health-followup"]["history"][-1]["action"] == "auto_repair"
assert persisted_tasks["task-080-first-pass-followup"]["history"][-1]["action"] == "auto_repair"
assert len(persisted_tasks["task-077-readiness-metric-cards"]["history"]) == 1
assert len(persisted_tasks["task-074-external-signal-review"]["history"]) == 1
assert len(persisted_tasks["task-079-retry-health-followup"]["history"]) == 1
assert len(persisted_tasks["task-080-first-pass-followup"]["history"]) == 1
assert persisted_tasks["task-078-enterprise-mobile-console"].get("history") in (None, [])
PY

echo "pending approval auto repair test passed"
