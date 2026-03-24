#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"
PLAN_FILE="$TMP_DIR/plan.json"
STEP_FILE="$TMP_DIR/step.json"
MEMORY_FILE="$TMP_DIR/memory.txt"
FEEDBACK_FILE="$TMP_DIR/feedback.json"
OUTPUT_FILE="$TMP_DIR/coder.json"
FEEDBACK_STEP='Inspect `agents/coder.sh` and patch only the fallback guidance selection so same-run retry feedback wins over weaker historical matches.'
HISTORICAL_STEP='Inspect `scripts/lib.sh` and make a broader metrics-path adjustment.'

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
      "id": "task-093-generic-retry",
      "title": "Carry bounded retry feedback into coder fallback",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-24T11:00:00Z",
      "updated_at": "2026-03-24T11:02:00Z",
      "failure_context": {
        "failed_step": "Inspect `scripts/lib.sh` and make a broader metrics-path adjustment."
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

cat >"$FEEDBACK_FILE" <<JSON
{
  "coder": {
    "status": "fail",
    "message": "Fallback implementation requires bounded task-specific execution.",
    "data": {
      "step": "Implement the requested change with minimal modifications.",
      "checks": []
    }
  },
  "review": {
    "status": "retry",
    "message": "Coder reported bounded retry guidance; retry required.",
    "data": {
      "step": $(
        printf '%s' "$FEEDBACK_STEP" | jq -R .
      ),
      "findings": [
        "Retry the bounded step: $FEEDBACK_STEP",
        "Use the preferred verification command: bash tests/coder-feedback-learning.sh"
      ]
    }
  },
  "evaluation": {
    "status": "fail",
    "message": "Step evaluation failed.",
    "data": {
      "step": $(
        printf '%s' "$FEEDBACK_STEP" | jq -R .
      ),
      "score": 3,
      "reason": "Review requested another attempt for the bounded step: $FEEDBACK_STEP Use the preferred verification command: bash tests/coder-feedback-learning.sh"
    }
  }
}
JSON

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  bash "$TEST_ROOT/agents/coder.sh" \
    "$PROJECT_DIR" \
    "Carry bounded retry feedback into coder fallback" \
    "$STEP_FILE" \
    "$PLAN_FILE" \
    "$MEMORY_FILE" \
    "$FEEDBACK_FILE" \
    "$OUTPUT_FILE" >/dev/null
)

jq -e --arg step "$FEEDBACK_STEP" --arg historical "$HISTORICAL_STEP" '
  .status == "fail" and
  .message == "Fallback implementation requires bounded task-specific execution." and
  .data.changed == false and
  .data.step == $step and
  .data.step != $historical and
  (.data.checks | index("Preferred verification command: bash tests/coder-feedback-learning.sh"))
' "$OUTPUT_FILE" >/dev/null

echo "coder feedback learning test passed"
