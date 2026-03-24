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
  local port=4700
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
mkdir -p "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-memory" "$TEST_ROOT/projects" "$TEST_ROOT/queues"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-008-persist-structured-failure-context-for-s",
      "title": "Persist structured failure context for strategy follow-ups",
      "impact": 6,
      "effort": 3,
      "confidence": 0.76,
      "category": "stability",
      "project": "codex-agent-system",
      "reason": "Fixture failed earlier and should be retryable from the dashboard.",
      "score": 2.89,
      "status": "failed",
      "created_at": "2026-03-23T03:36:10Z",
      "updated_at": "2026-03-23T03:44:11Z",
      "failed_at": "2026-03-23T03:44:11Z",
      "execution_provider": "codex",
      "provider_selection": {
        "selected": "codex",
        "source": "strategy_default",
        "reason": "Strategy defaults enterprise follow-up tasks to codex unless a task pins a different provider."
      },
      "task_intent": {
        "source": "strategy_followup",
        "objective": "Persist structured failure context for strategy follow-ups",
        "project": "codex-agent-system",
        "category": "stability",
        "context_hint": "Retry the bounded failure-context work without changing unrelated paths.",
        "constraints": ["Return JSON only", "Keep changes minimal"],
        "success_signals": ["Failure context stays deterministic after retry"],
        "affected_files": ["agents/orchestrator.sh", "scripts/lib.sh"]
      },
      "task_shape": {
        "approval_ready": true,
        "manual_review_required": false,
        "verification_command": "bash tests/system-smoke.sh",
        "reasons": []
      },
      "queue_handoff": {
        "at": "2026-03-23T03:36:10Z",
        "project": "codex-agent-system",
        "task": "Persist structured failure context for strategy follow-ups",
        "status": "queued",
        "provider": "codex"
      },
      "execution": {
        "state": "failed",
        "attempt": 2,
        "max_retries": 2,
        "provider": "codex",
        "result": "FAILURE",
        "updated_at": "2026-03-23T03:44:11Z"
      },
      "history": [
        {
          "at": "2026-03-23T03:44:11Z",
          "action": "execute_failure",
          "from_status": "running",
          "to_status": "failed",
          "project": "codex-agent-system",
          "queue_task": "Persist structured failure context for strategy follow-ups",
          "note": "Queue execution failed after exhausting retries."
        }
      ]
    }
  ]
}
EOF

cat >"$TEST_ROOT/status.txt" <<'EOF'
state=idle
project=
task=
last_result=NONE
note=Dashboard test fixture
updated_at=2026-03-24T12:00:00Z
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-logs/system.log"
cat >"$TEST_ROOT/codex-memory/dashboard-settings.json" <<'EOF'
{"approval_mode":"manual","updated_at":"2026-03-24T12:00:00Z"}
EOF

DASHBOARD_PORT="$(find_free_port)"
DASHBOARD_PORT="$DASHBOARD_PORT" node "$TEST_ROOT/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

python3 - "$DASHBOARD_PORT" "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
import time
import urllib.request

port = sys.argv[1]
tasks_path = sys.argv[2]
base_url = f"http://127.0.0.1:{port}"

for _ in range(30):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            registry = json.load(response)
        break
    except Exception:
        time.sleep(0.2)
else:
    raise SystemExit("dashboard retry endpoint did not become ready")

task = next(task for task in registry["tasks"] if task["id"] == "task-008-persist-structured-failure-context-for-s")
assert task["status"] == "failed"

request = urllib.request.Request(
    f"{base_url}/api/task-registry/action",
    data=json.dumps({"id": task["id"], "action": "retry"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    payload = json.load(response)

assert payload["ok"] is True
assert payload["message"] in {"Failed task retried and queued.", "Failed task retried and recognized as already queued."}
assert payload["task"]["status"] == "approved"
assert payload["task"]["queue_handoff"]["task"] == "Persist structured failure context for strategy follow-ups"
assert payload["task"]["queue_handoff"]["provider"] == "codex"
assert payload["task"]["task_intent"]["source"] == "strategy_followup"
assert payload["task"]["task_shape"]["verification_command"] == "bash tests/system-smoke.sh"
assert payload["task"].get("failed_at") in {None, ""}
assert payload["task"].get("execution") in {None}
assert payload["task"]["history"][-1]["action"] == "retry"
assert payload["task"]["history"][-1]["from_status"] == "failed"
assert payload["task"]["history"][-1]["to_status"] == "approved"

with open(tasks_path, "r", encoding="utf-8") as handle:
    persisted = json.load(handle)

persisted_task = next(task for task in persisted["tasks"] if task["id"] == "task-008-persist-structured-failure-context-for-s")
assert persisted_task["status"] == "approved"
assert persisted_task["history"][-1]["action"] == "retry"
assert "Failed task was retried" in persisted_task["history"][-1]["note"]
assert "execution" not in persisted_task
assert "failed_at" not in persisted_task
PY

grep -q 'data-task-action="retry"' "$TEST_ROOT/codex-dashboard/index.html"
grep -q 'Retry Failed Task' "$TEST_ROOT/codex-dashboard/index.html"

echo "failed task retry action test passed"
