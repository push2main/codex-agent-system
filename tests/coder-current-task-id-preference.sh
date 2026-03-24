#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"
PLAN_FILE="$TMP_DIR/plan.json"
STEP_FILE="$TMP_DIR/step.json"
MEMORY_FILE="$TMP_DIR/memory.txt"
OUTPUT_FILE="$TMP_DIR/coder.json"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-timeout-current",
      "title": "Tighten late timeout reconciliation for claimed queue tasks",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-24T11:21:04Z",
      "updated_at": "2026-03-24T11:21:04Z",
      "task_intent": {
        "objective": "Tighten late timeout reconciliation for claimed queue tasks",
        "context_hint": "Focus on the bounded late-outcome reconciliation path for claimed tasks.",
        "constraints": [
          "Touch only timeout reconciliation or its deterministic observability path.",
          "Do not change queue scheduling, retry limits, or strategy task generation."
        ],
        "affected_files": [
          "scripts/lib.sh",
          "tests/queue-worker-timeout-success-reconciliation.sh"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/queue-worker-timeout-success-reconciliation.sh && bash tests/queue-worker-timeout-classification.sh"
      }
    },
    {
      "id": "task-timeout-old-failure",
      "title": "Tighten late timeout reconciliation for claimed queue tasks",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:05:00Z",
      "failure_context": {
        "failed_step": "implement the smallest safe change for: Reconcile registry running state against live queue leases before planning new work. Focus on Runtime state mismatch anomaly."
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
      }
    }
  ]
}
EOF

cat >"$PLAN_FILE" <<'JSON'
{"status":"success","message":"ok","data":{"steps":["Inspect the current project files and choose the smallest safe implementation.","Implement the requested change with minimal modifications.","Run a lightweight verification relevant to the task and confirm the outcome."]}}
JSON

cat >"$STEP_FILE" <<'JSON'
{"index":2,"text":"Implement the requested change with minimal modifications."}
JSON

cat >"$MEMORY_FILE" <<'EOF'
# Memory
EOF

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  TASK_ID="task-timeout-current" \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  bash "$TEST_ROOT/agents/coder.sh" \
    "$PROJECT_DIR" \
    "Tighten late timeout reconciliation for claimed queue tasks" \
    "$STEP_FILE" \
    "$PLAN_FILE" \
    "$MEMORY_FILE" \
    "" \
    "$OUTPUT_FILE" >/dev/null
)

jq -e '
  .status == "fail" and
  .message == "Fallback implementation requires bounded task-specific execution." and
  .data.changed == false and
  (.data.files | length) == 0 and
  (.data.step | contains("In `scripts/lib.sh`, `tests/queue-worker-timeout-success-reconciliation.sh`, implement the smallest safe change for: Tighten late timeout reconciliation for claimed queue tasks.")) and
  (.data.step | contains("Focus on Focus on the bounded late-outcome reconciliation path for claimed tasks.")) and
  (.data.step | contains("Touch only timeout reconciliation or its deterministic observability path; Do not change queue scheduling, retry limits, or strategy task generation.")) and
  (.data.checks | index("Preferred verification command: bash tests/queue-worker-timeout-success-reconciliation.sh && bash tests/queue-worker-timeout-classification.sh"))
' "$OUTPUT_FILE" >/dev/null

echo "coder current task id preference test passed"
