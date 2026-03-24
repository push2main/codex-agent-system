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
      "id": "task-091-fix-first-pass-metrics-path",
      "title": "Fix first-pass metrics path",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-24T07:10:00Z",
      "updated_at": "2026-03-24T07:12:56Z",
      "task_intent": {
        "objective": "Fix first-pass metrics path",
        "context_hint": "Align the persisted first-pass metrics fields only."
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
      },
      "failure_context": {
        "failed_step": "Implement the requested change with minimal modifications."
      }
    },
    {
      "id": "task-080-align-persisted-first-pass-success-metrics",
      "title": "Align persisted first-pass success metrics",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-23T14:33:00Z",
      "updated_at": "2026-03-23T14:44:56Z",
      "failure_context": {
        "failed_step": "Inspect `codex-dashboard/server.js` and `scripts/lib.sh` together, confirm the exact first-pass success filter/rule/threshold already used in the dashboard path, then patch only the persisted metrics logic in `scripts/lib.sh` so `first_pass_success_count`, `multi_attempt_resolved_count`, `first_pass_success_rate`, and `low_first_pass_success_detected` use the same successful-completed-task filter, `attempt <= 1` rule, one explicit threshold, and a non-zero-sample guard without changing keys or storage format."
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
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  bash "$TEST_ROOT/agents/coder.sh" \
    "$PROJECT_DIR" \
    "Fix first-pass metrics path" \
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
  .data.step == "Inspect `codex-dashboard/server.js` and `scripts/lib.sh` together, confirm the exact first-pass success filter/rule/threshold already used in the dashboard path, then patch only the persisted metrics logic in `scripts/lib.sh` so `first_pass_success_count`, `multi_attempt_resolved_count`, `first_pass_success_rate`, and `low_first_pass_success_detected` use the same successful-completed-task filter, `attempt <= 1` rule, one explicit threshold, and a non-zero-sample guard without changing keys or storage format." and
  (.data.checks | index("Preferred verification command: bash tests/system-smoke.sh"))
' "$OUTPUT_FILE" >/dev/null

echo "coder fallback learning test passed"
