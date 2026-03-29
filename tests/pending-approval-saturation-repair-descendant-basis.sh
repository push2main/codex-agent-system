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
  local port=5080
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
      "title": "Replace Detect low first-pass success before repeated retries dominate the board with a different bounded experiment",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "pending_approval",
      "strategy_template": "strategy_saturation_rescue",
      "task_intent": {
        "source": "strategy_saturation",
        "objective": "Replace Detect low first-pass success before repeated retries dominate the board with a different bounded experiment",
        "project": "codex-agent-system",
        "category": "learning",
        "context_hint": "Replace saturated experiment: Detect low first-pass success before repeated retries dominate the board"
      },
      "task_shape": {
        "approval_ready": true,
        "requires_split": false,
        "reasons": [],
        "manual_review_required": false,
        "risk_profile": "standard",
        "risk_flags": [],
        "verification_command": "",
        "updated_at": "2026-03-24T19:41:01Z"
      },
      "saturation_recovery": {
        "kind": "replace_saturated_experiment",
        "replaces_task_id": "task-root-first-pass",
        "replaces_title": "Detect low first-pass success before repeated retries dominate the board",
        "replaces_strategy_template": "first_pass_success_guard",
        "replaces_category": "learning"
      },
      "created_at": "2026-03-24T19:41:00Z",
      "updated_at": "2026-03-24T19:41:01Z",
      "history": [
        {
          "at": "2026-03-24T19:41:00Z",
          "action": "create",
          "from_status": "",
          "to_status": "pending_approval",
          "project": "codex-agent-system",
          "queue_task": "Fix first-pass metrics path",
          "note": "Task was added from strategy saturation recovery after all enterprise templates hit the saturation guard."
        }
      ]
    },
    {
      "id": "task-root-first-pass",
      "title": "Detect low first-pass success before repeated retries dominate the board",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "failed",
      "strategy_template": "first_pass_success_guard",
      "source_task_id": "strategy::first-pass-success",
      "root_source_task_id": "strategy::first-pass-success",
      "original_failed_root_id": "strategy::first-pass-success",
      "created_at": "2026-03-24T18:40:00Z",
      "updated_at": "2026-03-24T18:40:46Z",
      "failed_at": "2026-03-24T18:40:46Z"
    },
    {
      "id": "task-child-first-pass",
      "title": "Align persisted first-pass success metrics",
      "project": "codex-agent-system",
      "category": "learning",
      "status": "failed",
      "strategy_template": "bounded_failed_step_child",
      "source_task_id": "strategy::first-pass-success",
      "root_source_task_id": "strategy::first-pass-success",
      "original_failed_root_id": "strategy::first-pass-success",
      "failure_context": {
        "failed_step": "Run `bash tests/system-smoke.sh` as the single deterministic verification command and treat exit code `0` as success; if it fails, limit the follow-up fix strictly to the first-pass metrics path surfaced by that command."
      },
      "created_at": "2026-03-24T18:38:00Z",
      "updated_at": "2026-03-24T18:38:30Z",
      "failed_at": "2026-03-24T18:38:30Z"
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
            registry = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard descendant saturation repair endpoint did not become ready")

task = {item["id"]: item for item in registry["tasks"]}["task-saturation-recovery"]
assert task["title"] == "Fix first-pass metrics path"
assert task["execution_task"] == "Fix first-pass metrics path"
assert task["task_intent"] == {
    "source": "strategy_saturation",
    "objective": "Fix first-pass metrics path",
    "project": "codex-agent-system",
    "category": "learning",
    "context_hint": "Replace saturated experiment: Align persisted first-pass success metrics",
    "constraints": [],
    "success_signals": [],
    "affected_files": [],
}
assert task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert task["last_history_entry"]["action"] == "auto_repair"

with open(os.path.join(root, "codex-memory", "tasks.json"), "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

persisted_task = {item["id"]: item for item in persisted["tasks"]}["task-saturation-recovery"]
assert persisted_task["title"] == "Fix first-pass metrics path"
assert persisted_task["execution_task"] == "Fix first-pass metrics path"
assert persisted_task["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
PY

echo "pending approval saturation repair descendant basis test passed"
