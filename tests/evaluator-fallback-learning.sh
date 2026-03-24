#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"
PLAN_FILE="$TMP_DIR/plan.json"
STEP_FILE="$TMP_DIR/step.json"
REVIEW_FILE="$TMP_DIR/review.json"
OUTPUT_FILE="$TMP_DIR/evaluator.json"
BOUNDED_STEP='Inspect `scripts/lib.sh` and patch only the persisted metrics filter without changing metric keys.'

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
  "$PROJECT_DIR"

cat >"$PLAN_FILE" <<'JSON'
{"status":"success","message":"ok","data":{"steps":["Inspect the current project files and choose the smallest safe implementation.","Implement the requested change with minimal modifications.","Run a lightweight verification relevant to the task and confirm the outcome."]}}
JSON

cat >"$STEP_FILE" <<'JSON'
{"index":2,"text":"Implement the requested change with minimal modifications."}
JSON

cat >"$REVIEW_FILE" <<JSON
{
  "status": "retry",
  "message": "Coder reported bounded retry guidance; retry required.",
  "data": {
    "step": $(
      printf '%s' "$BOUNDED_STEP" | jq -R .
    ),
    "index": 2,
    "kind": "implement",
    "findings": [
      "Retry the bounded step: $BOUNDED_STEP",
      "Use the preferred verification command: bash tests/system-smoke.sh"
    ]
  }
}
JSON

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  bash "$TEST_ROOT/agents/evaluator.sh" \
    "$PROJECT_DIR" \
    "Fix first-pass metrics path" \
    "$STEP_FILE" \
    "$PLAN_FILE" \
    "$REVIEW_FILE" \
    "$OUTPUT_FILE" >/dev/null
)

jq -e --arg step "$BOUNDED_STEP" '
  .status == "fail" and
  .message == "Step evaluation failed." and
  .data.step == $step and
  .data.score == 3 and
  .data.reason == ("Review requested another attempt for the bounded step: " + $step + " Use the preferred verification command: bash tests/system-smoke.sh")
' "$OUTPUT_FILE" >/dev/null

echo "evaluator fallback learning test passed"
