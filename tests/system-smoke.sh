#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
DASHBOARD_PID=""
QUEUES_BACKUP_DIR="$TMP_DIR/queues-backup"
TASKS_BACKUP_FILE="$TMP_DIR/tasks.json.backup"
STATUS_BACKUP_FILE="$TMP_DIR/status.txt.backup"
SYSTEM_LOG_BACKUP_FILE="$TMP_DIR/system.log.backup"
METRICS_BACKUP_FILE="$TMP_DIR/metrics.json.backup"

cleanup() {
  if [ -n "$DASHBOARD_PID" ]; then
    kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
    wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
  fi
  if [ -f "$TASKS_BACKUP_FILE" ]; then
    cp "$TASKS_BACKUP_FILE" "$ROOT_DIR/codex-memory/tasks.json"
  fi
  if [ -f "$STATUS_BACKUP_FILE" ]; then
    cp "$STATUS_BACKUP_FILE" "$ROOT_DIR/status.txt"
  else
    rm -f "$ROOT_DIR/status.txt"
  fi
  if [ -f "$SYSTEM_LOG_BACKUP_FILE" ]; then
    mkdir -p "$ROOT_DIR/codex-logs"
    cp "$SYSTEM_LOG_BACKUP_FILE" "$ROOT_DIR/codex-logs/system.log"
  else
    rm -f "$ROOT_DIR/codex-logs/system.log"
  fi
  if [ -f "$METRICS_BACKUP_FILE" ]; then
    mkdir -p "$ROOT_DIR/codex-learning"
    cp "$METRICS_BACKUP_FILE" "$ROOT_DIR/codex-learning/metrics.json"
  else
    rm -f "$ROOT_DIR/codex-learning/metrics.json"
  fi
  rm -rf "$ROOT_DIR/queues"
  mkdir -p "$ROOT_DIR/queues"
  if [ -d "$QUEUES_BACKUP_DIR" ]; then
    cp -R "$QUEUES_BACKUP_DIR/." "$ROOT_DIR/queues" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

PROJECT_DIR="$TMP_DIR/project"
RUN_DIR="$TMP_DIR/run"
PLAN_FILE="$TMP_DIR/plan.json"
STEP_FILE="$TMP_DIR/step.json"
MEMORY_FILE="$TMP_DIR/memory.txt"
CODER_FILE="$TMP_DIR/coder.json"
REVIEWER_FILE="$TMP_DIR/reviewer.json"
EVALUATOR_FILE="$TMP_DIR/evaluator.json"
LEARNER_FILE="$TMP_DIR/learner.json"
SAFETY_FILE="$TMP_DIR/safety.json"
PROMPT_RULES_FILE="$TMP_DIR/prompt-rules.md"
RULES_FILE="$TMP_DIR/rules.md"
DASHBOARD_TEST_PORT="${DASHBOARD_TEST_PORT:-3210}"

mkdir -p "$PROJECT_DIR" "$RUN_DIR"
printf '# Context\n\n- deterministic smoke test\n' >"$MEMORY_FILE"

cp "$ROOT_DIR/codex-memory/tasks.json" "$TASKS_BACKUP_FILE"
if [ -f "$ROOT_DIR/status.txt" ]; then
  cp "$ROOT_DIR/status.txt" "$STATUS_BACKUP_FILE"
fi
if [ -f "$ROOT_DIR/codex-logs/system.log" ]; then
  cp "$ROOT_DIR/codex-logs/system.log" "$SYSTEM_LOG_BACKUP_FILE"
fi
if [ -f "$ROOT_DIR/codex-learning/metrics.json" ]; then
  cp "$ROOT_DIR/codex-learning/metrics.json" "$METRICS_BACKUP_FILE"
fi
mkdir -p "$QUEUES_BACKUP_DIR"
if [ -d "$ROOT_DIR/queues" ]; then
  cp -R "$ROOT_DIR/queues/." "$QUEUES_BACKUP_DIR" 2>/dev/null || true
fi
rm -rf "$ROOT_DIR/queues"
mkdir -p "$ROOT_DIR/queues"
rm -f "$ROOT_DIR/status.txt"
cat >"$ROOT_DIR/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-smoke-pending-shell",
      "title": "create hello world script in shell",
      "impact": 6,
      "effort": 2,
      "confidence": 0.9,
      "category": "stability",
      "project": "registry-smoke",
      "reason": "Smoke test fixture for dashboard approval flow.",
      "score": 4.05,
      "status": "pending_approval",
      "created_at": "2026-03-22T15:00:00Z",
      "updated_at": "2026-03-22T15:00:00Z"
    },
    {
      "id": "task-smoke-completed-shell",
      "title": "surface execution details on the task board",
      "impact": 5,
      "effort": 2,
      "confidence": 0.84,
      "category": "ui",
      "project": "registry-smoke",
      "reason": "Smoke test fixture for execution history rendering.",
      "score": 3.2,
      "status": "completed",
      "created_at": "2026-03-22T14:40:00Z",
      "updated_at": "2026-03-22T14:50:00Z",
      "approved_at": "2026-03-22T14:42:00Z",
      "completed_at": "2026-03-22T14:50:00Z",
      "execution": {
        "state": "completed",
        "attempt": 2,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "2026-03-22T14:50:00Z",
        "will_retry": false
      },
      "history": [
        {
          "at": "2026-03-22T14:42:00Z",
          "action": "approve",
          "from_status": "pending_approval",
          "to_status": "approved",
          "project": "registry-smoke",
          "queue_task": "surface execution details on the task board",
          "note": "Task was enqueued after approval."
        },
        {
          "at": "2026-03-22T14:50:00Z",
          "action": "execute_success",
          "from_status": "running",
          "to_status": "completed",
          "project": "registry-smoke",
          "queue_task": "surface execution details on the task board",
          "note": "Queue execution completed successfully."
        }
      ]
    }
  ]
}
EOF

bash -n "$ROOT_DIR"/agents/*.sh "$ROOT_DIR"/scripts/*.sh
node --check "$ROOT_DIR/codex-dashboard/server.js"
bash "$ROOT_DIR/tests/codex-runtime-auth-bootstrap.sh"
bash "$ROOT_DIR/tests/codex-exec-auth-cooldown.sh"
bash "$ROOT_DIR/tests/queue-auth-pause.sh"
bash "$ROOT_DIR/tests/project-state.sh"
bash "$ROOT_DIR/tests/codex-exec-logging.sh"
bash "$ROOT_DIR/tests/recovery-log-sync.sh"

jq -e '
  (.tasks | type == "array") and
  all(.tasks[]; (.id | type == "string") and (.title | type == "string") and (.score | type == "number") and (.status | type == "string") and (.created_at | type == "string"))
' "$ROOT_DIR/codex-memory/tasks.json" >/dev/null

jq -e '
  (.rules | type == "array") and
  all(.rules[]; (.category | type == "string") and (.rule | type == "string"))
' "$ROOT_DIR/codex-memory/knowledge.json" >/dev/null

jq -e '
  (.categories | type == "object") and
  (.categories.stability.weight | type == "number") and
  (.categories.ui.weight | type == "number") and
  (.categories.performance.weight | type == "number") and
  (.categories.code_quality.weight | type == "number")
' "$ROOT_DIR/codex-memory/priority.json" >/dev/null

jq -e '
  (.analysis_runs | type == "number") and
  (.pending_approval_tasks | type == "number") and
  (.approved_tasks | type == "number") and
  (.task_registry_total | type == "number")
' "$ROOT_DIR/codex-learning/metrics.json" >/dev/null

DASHBOARD_PORT="$DASHBOARD_TEST_PORT" node "$ROOT_DIR/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

export DASHBOARD_TEST_PORT
export ROOT_DIR
python3 - <<'PY'
import json
import os
import time
import urllib.request

base_url = f"http://127.0.0.1:{os.environ['DASHBOARD_TEST_PORT']}"

for _ in range(20):
    try:
        with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
            payload = json.load(response)
        assert isinstance(payload.get("tasks"), list)
        assert isinstance(payload.get("summary"), dict)
        assert "nextAction" in payload["summary"]
        assert payload["tasks"][0]["id"]
        assert "topCategory" in payload["summary"]
        break
    except Exception:
        time.sleep(0.25)
else:
    raise SystemExit("dashboard task registry endpoint did not become ready")

with urllib.request.urlopen(f"{base_url}/", timeout=1) as response:
    html = response.read().decode("utf-8")

assert "Recent execution" in html
assert "Recent activity" in html

completed_task = next(task for task in payload["tasks"] if task["id"] == "task-smoke-completed-shell")
assert completed_task["execution"]["result"] == "SUCCESS"
assert completed_task["last_history_entry"]["action"] == "execute_success"
assert len(completed_task["history_preview"]) == 2

log_path = os.path.join(os.environ["ROOT_DIR"], "codex-logs", "system.log")
with open(log_path, "a", encoding="utf-8") as handle:
    handle.write("raw dashboard noise that should be filtered\n")

with urllib.request.urlopen(f"{base_url}/api/logs?limit=200", timeout=1) as response:
    logs_payload = json.load(response)

assert "raw dashboard noise that should be filtered" not in logs_payload["logs"]
assert "[dashboard] INFO:" in logs_payload["logs"]

with urllib.request.urlopen(f"{base_url}/api/metrics", timeout=1) as response:
    metrics = json.load(response)

assert "pendingApproval" in metrics
assert "approved" in metrics
assert "taskRegistryTotal" in metrics
assert "nextAction" in metrics

pending_task = next(task for task in payload["tasks"] if task["status"] == "pending_approval")
update_request = urllib.request.Request(
    f"{base_url}/api/task-registry/update",
    data=json.dumps(
        {
            "id": pending_task["id"],
            "project": "registry-smoke-updated",
            "title": "create hello world script for registry smoke",
        }
    ).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(update_request, timeout=2) as response:
    updated = json.load(response)

assert updated["ok"] is True
assert updated["task"]["project"] == "registry-smoke-updated"
assert updated["task"]["title"] == "create hello world script for registry smoke"

request = urllib.request.Request(
    f"{base_url}/api/task-registry/action",
    data=json.dumps({"id": pending_task["id"], "action": "approve"}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(request, timeout=2) as response:
    transition = json.load(response)

assert transition["ok"] is True
assert transition["task"]["status"] == "approved"
assert transition["task"]["project"] == "registry-smoke-updated"
assert transition["task"]["queue_handoff"]["task"] == "create hello world script for registry smoke"
assert any(entry["action"] == "edit" for entry in transition["task"]["history"])

with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
    refreshed = json.load(response)

approved = [task for task in refreshed["tasks"] if task["status"] == "approved"]
assert approved
assert approved[0]["history"]
assert approved[0]["queue_handoff"]["status"] in {"queued", "already_queued"}

with urllib.request.urlopen(f"{base_url}/api/queue", timeout=1) as response:
    queue = json.load(response)

assert any(
    entry["project"] == approved[0]["project"] and entry["task"] == "create hello world script for registry smoke"
    for entry in queue["tasks"]
)

with open(os.path.join(os.environ["ROOT_DIR"], "codex-learning", "metrics.json"), "r", encoding="utf-8") as handle:
    persisted_metrics = json.load(handle)

assert persisted_metrics["analysis_runs"] == 2
assert persisted_metrics["task_registry_total"] == 2
assert persisted_metrics["pending_approval_tasks"] == 0
assert persisted_metrics["approved_tasks"] == 1
PY

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/planner.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "$PLAN_FILE" \
  "$MEMORY_FILE" \
  >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  (.message | type == "string") and
  (.data | type == "object") and
  (.data.steps | type == "array") and
  (.data.steps | length) >= 2
' "$PLAN_FILE" >/dev/null

jq -cn \
  --argjson index 2 \
  --arg text "$(jq -r '.data.steps[1]' "$PLAN_FILE")" \
  '{index:$index,text:$text}' >"$STEP_FILE"

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/coder.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "$STEP_FILE" \
  "$PLAN_FILE" \
  "$MEMORY_FILE" \
  "" \
  "$CODER_FILE" \
  >"$TMP_DIR/coder.stdout"

jq -e '
  .status == "success" and
  (.data | type == "object") and
  (.data.changed == true) and
  (.data.files | type == "array")
' "$CODER_FILE" >/dev/null

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/reviewer.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "$STEP_FILE" \
  "$PLAN_FILE" \
  "$CODER_FILE" \
  "$REVIEWER_FILE" \
  >"$TMP_DIR/reviewer.stdout"

jq -e '
  .status == "approved" and
  (.data | type == "object") and
  (.data.findings | type == "array")
' "$REVIEWER_FILE" >/dev/null

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/evaluator.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "$STEP_FILE" \
  "$PLAN_FILE" \
  "$REVIEWER_FILE" \
  "$EVALUATOR_FILE" \
  >"$TMP_DIR/evaluator.stdout"

jq -e '
  .status == "success" and
  (.data | type == "object") and
  (.data.score | type == "number")
' "$EVALUATOR_FILE" >/dev/null

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/learner.sh" \
  "$PROJECT_DIR" \
  "create hello world script in shell" \
  "SUCCESS" \
  "$RUN_DIR" \
  "$PROMPT_RULES_FILE" \
  "$LEARNER_FILE" \
  >"$TMP_DIR/learner.stdout"

jq -e '
  .status == "success" and
  (.data | type == "object") and
  (.data.rules | type == "array") and
  (.data.rules | length) >= 1
' "$LEARNER_FILE" >/dev/null
grep -q '^- ' "$PROMPT_RULES_FILE"

CODEX_DISABLE=1 bash "$ROOT_DIR/agents/safety.sh" \
  "$PROMPT_RULES_FILE" \
  "$RULES_FILE" \
  "$SAFETY_FILE" \
  >"$TMP_DIR/safety.stdout"

jq -e '
  .status == "success" and
  (.data | type == "object") and
  (.data.rules | type == "array") and
  (.data.rules | length) >= 1
' "$SAFETY_FILE" >/dev/null
grep -q '^- ' "$RULES_FILE"

echo "smoke test passed"
