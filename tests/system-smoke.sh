#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
DASHBOARD_PID=""
TEST_ROOT="$TMP_DIR/dashboard-fixture"
TEST_PROJECTS_DIR="$TEST_ROOT/projects"
TEST_QUEUES_DIR="$TEST_ROOT/queues"
TEST_MEMORY_DIR="$TEST_ROOT/codex-memory"
TEST_LOGS_DIR="$TEST_ROOT/codex-logs"
TEST_LEARNING_DIR="$TEST_ROOT/codex-learning"
TEST_TASKS_FILE="$TEST_MEMORY_DIR/tasks.json"
TEST_STATUS_FILE="$TEST_ROOT/status.txt"
TEST_SYSTEM_LOG_FILE="$TEST_LOGS_DIR/system.log"
TEST_METRICS_FILE="$TEST_LEARNING_DIR/metrics.json"
TEST_PRIORITY_FILE="$TEST_MEMORY_DIR/priority.json"
TEST_TASK_LOG_FILE="$TEST_MEMORY_DIR/tasks.log"
TEST_SETTINGS_FILE="$TEST_MEMORY_DIR/dashboard-settings.json"

cleanup() {
  if [ -n "$DASHBOARD_PID" ]; then
    kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
    wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
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

mkdir -p "$PROJECT_DIR" "$RUN_DIR" "$TEST_PROJECTS_DIR" "$TEST_QUEUES_DIR" "$TEST_MEMORY_DIR" "$TEST_LOGS_DIR" "$TEST_LEARNING_DIR"
printf '# Context\n\n- deterministic smoke test\n' >"$MEMORY_FILE"
cat >"$TEST_TASKS_FILE" <<'EOF'
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
      "task_intent": {
        "source": "dashboard_backlog",
        "objective": "create hello world script in shell",
        "project": "registry-smoke",
        "category": "stability",
        "context_hint": "Keep the smoke fixture deterministic.",
        "constraints": [
          "Return JSON only",
          "Keep changes minimal"
        ],
        "success_signals": [
          "Queue handoff keeps intent metadata"
        ],
        "affected_files": [
          "tests/system-smoke.sh"
        ]
      },
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

cat >"$TEST_PRIORITY_FILE" <<'EOF'
{
  "categories": {
    "stability": {
      "weight": 1.8,
      "success_rate": 0.76
    },
    "ui": {
      "weight": 1.35,
      "success_rate": 0.81
    },
    "performance": {
      "weight": 1.1,
      "success_rate": 0.7
    },
    "code_quality": {
      "weight": 1.05,
      "success_rate": 0.79
    }
  }
}
EOF

: >"$TEST_TASK_LOG_FILE"
: >"$TEST_SYSTEM_LOG_FILE"
cat >"$TEST_METRICS_FILE" <<'EOF'
{
  "total_tasks": 0,
  "success_rate": 0,
  "analysis_runs": 0,
  "pending_approval_tasks": 0,
  "approved_tasks": 0,
  "task_registry_total": 0,
  "last_task_score": 0,
  "manual_recovery_records": 0,
  "low_first_pass_success_detected": false,
  "first_pass_success_rate": 0,
  "first_pass_success_count": 0,
  "multi_attempt_resolved_count": 0
}
EOF

cat >"$TEST_SETTINGS_FILE" <<'EOF'
{
  "approval_mode": "manual",
  "updated_at": "2026-03-22T15:00:00Z"
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
bash "$ROOT_DIR/tests/task-registry-create.sh"
bash "$ROOT_DIR/tests/task-registry-approved-handoff.sh"
bash "$ROOT_DIR/tests/task-registry-lifecycle.sh"
bash "$ROOT_DIR/tests/task-context-learning.sh"
bash "$ROOT_DIR/tests/dashboard-auth-health.sh"
bash "$ROOT_DIR/tests/strategy-task-generation.sh"
bash "$ROOT_DIR/tests/strategy-bounded-child.sh"
bash "$ROOT_DIR/tests/strategy-learning-guard-seeding.sh"
bash "$ROOT_DIR/tests/running-lease-reconciliation.sh"
bash "$ROOT_DIR/tests/provider-routing.sh"
bash "$ROOT_DIR/tests/provider-stats-bootstrap.sh"
bash "$ROOT_DIR/tests/provider-learning.sh"
bash "$ROOT_DIR/tests/queue-parallel-lanes.sh"

jq -e '
  (.tasks | type == "array") and
  all(.tasks[]; (.id | type == "string") and (.title | type == "string") and (.score | type == "number") and (.status | type == "string") and (.created_at | type == "string"))
' "$TEST_TASKS_FILE" >/dev/null

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
' "$TEST_PRIORITY_FILE" >/dev/null

jq -e '
  (.analysis_runs | type == "number") and
  (.pending_approval_tasks | type == "number") and
  (.approved_tasks | type == "number") and
  (.task_registry_total | type == "number")
' "$TEST_METRICS_FILE" >/dev/null

DASHBOARD_PORT="$DASHBOARD_TEST_PORT" \
DASHBOARD_PROJECTS_DIR="$TEST_PROJECTS_DIR" \
DASHBOARD_QUEUES_DIR="$TEST_QUEUES_DIR" \
DASHBOARD_SYSTEM_LOG_FILE="$TEST_SYSTEM_LOG_FILE" \
DASHBOARD_METRICS_FILE="$TEST_METRICS_FILE" \
DASHBOARD_PRIORITY_FILE="$TEST_PRIORITY_FILE" \
DASHBOARD_TASK_LOG_FILE="$TEST_TASK_LOG_FILE" \
DASHBOARD_TASK_REGISTRY_FILE="$TEST_TASKS_FILE" \
DASHBOARD_SETTINGS_FILE="$TEST_SETTINGS_FILE" \
DASHBOARD_STATUS_FILE="$TEST_STATUS_FILE" \
node "$ROOT_DIR/codex-dashboard/server.js" >"$TMP_DIR/dashboard.stdout" 2>&1 &
DASHBOARD_PID=$!

export DASHBOARD_TEST_PORT
export ROOT_DIR
export TEST_SYSTEM_LOG_FILE
export TEST_METRICS_FILE
export TEST_TASKS_FILE
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

log_path = os.environ["TEST_SYSTEM_LOG_FILE"]
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
assert "timeoutFailure" in metrics
assert "timeoutFailureRate" in metrics
assert metrics["lowFirstPassSuccess"]["detected"] is True
assert metrics["lowFirstPassSuccess"]["first_pass_success_count"] == 0
assert metrics["lowFirstPassSuccess"]["multi_attempt_resolved_count"] == 1

prompt_text = "Refine the mobile dashboard task cards for iPhone widths."

intake_request = urllib.request.Request(
    f"{base_url}/api/task-registry/intake",
    data=json.dumps({"project": "registry-smoke", "category": "ui", "prompt": prompt_text}).encode("utf-8"),
    headers={"Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(intake_request, timeout=2) as response:
    intake = json.load(response)

assert intake["ok"] is True
assert intake["created_count"] == 1
assert intake["message"] == "Derived 1 task for registry-smoke."
assert intake["skipped"] == []
assert isinstance(intake["tasks"], list)
assert len(intake["tasks"]) == 1

derived_task = intake["tasks"][0]
derived_title = "Refine the mobile dashboard task cards for iPhone widths"
assert derived_task["title"] == derived_title
assert derived_task["status"] == "pending_approval"
assert derived_task["project"] == "registry-smoke"
assert derived_task["category"] == "ui"
assert isinstance(derived_task["id"], str) and derived_task["id"]
assert isinstance(derived_task["task_intent"], dict)
assert derived_task["task_intent"]["source"] == "dashboard_prompt_intake"
assert derived_task["task_intent"]["objective"] == derived_title
assert derived_task["task_intent"]["project"] == "registry-smoke"
assert derived_task["task_intent"]["category"] == "ui"

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
assert transition["task"]["execution_provider"] == "codex"
assert transition["task"]["queue_handoff"]["task"] == "create hello world script for registry smoke"
assert transition["task"]["queue_handoff"]["provider"] == "codex"
assert transition["task"]["queue_handoff"]["task_intent"]["source"] == "dashboard_backlog"
assert transition["task"]["queue_handoff"]["task_intent"]["objective"] == "create hello world script for registry smoke"
assert transition["task"]["queue_handoff"]["task_intent"]["project"] == "registry-smoke-updated"
assert transition["task"]["queue_handoff"]["task_intent"]["category"] == "stability"
assert transition["task"]["queue_handoff"]["task_intent"]["constraints"] == ["Return JSON only", "Keep changes minimal"]
assert transition["task"]["queue_handoff"]["task_intent"]["success_signals"] == ["Queue handoff keeps intent metadata"]
with urllib.request.urlopen(f"{base_url}/api/task-registry", timeout=1) as response:
    refreshed = json.load(response)

approved = [task for task in refreshed["tasks"] if task["status"] == "approved"]
assert approved
approved_task = next(task for task in approved if task["id"] == pending_task["id"])
assert approved_task["queue_handoff"]["status"] in {"queued", "already_queued"}

with urllib.request.urlopen(f"{base_url}/api/queue", timeout=1) as response:
    queue = json.load(response)

assert any(
    entry["project"] == approved_task["project"] and entry["task"] == "create hello world script for registry smoke"
    for entry in queue["tasks"]
)

with open(os.environ["TEST_METRICS_FILE"], "r", encoding="utf-8") as handle:
    persisted_metrics = json.load(handle)

with open(os.environ["TEST_TASKS_FILE"], "r", encoding="utf-8") as handle:
    persisted_registry = json.load(handle)

persisted_task = next(task for task in persisted_registry["tasks"] if task["id"] == pending_task["id"])
assert persisted_task["status"] == "approved"
assert persisted_task["queue_handoff"]["task"] == "create hello world script for registry smoke"
assert persisted_task["queue_handoff"]["task_intent"]["source"] == "dashboard_backlog"
assert persisted_task["queue_handoff"]["task_intent"]["objective"] == "create hello world script for registry smoke"
assert persisted_task["queue_handoff"]["task_intent"]["project"] == "registry-smoke-updated"
assert persisted_task["queue_handoff"]["task_intent"]["category"] == "stability"
assert persisted_task["queue_handoff"]["task_intent"]["context_hint"] == "Keep the smoke fixture deterministic."
assert persisted_task["queue_handoff"]["task_intent"]["constraints"] == ["Return JSON only", "Keep changes minimal"]
assert persisted_task["queue_handoff"]["task_intent"]["success_signals"] == ["Queue handoff keeps intent metadata"]
expected_total = len([task for task in persisted_registry["tasks"] if isinstance(task, dict)])
expected_pending = len([task for task in persisted_registry["tasks"] if isinstance(task, dict) and task.get("status") == "pending_approval"])
expected_approved = len([task for task in persisted_registry["tasks"] if isinstance(task, dict) and task.get("status") == "approved"])
assert persisted_metrics["analysis_runs"] == expected_total
assert persisted_metrics["task_registry_total"] == expected_total
assert persisted_metrics["pending_approval_tasks"] == expected_pending
assert persisted_metrics["approved_tasks"] == expected_approved
assert persisted_metrics["timeout_failure_records"] == 0
assert persisted_metrics["timeout_failure_rate"] == 0
assert persisted_metrics["low_first_pass_success_detected"] is True
assert persisted_metrics["first_pass_success_count"] == 0
assert persisted_metrics["multi_attempt_resolved_count"] == 1
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
