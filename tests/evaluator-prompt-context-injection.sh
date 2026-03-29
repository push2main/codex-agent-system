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
MOCK_BIN="$TMP_DIR/bin"
CAPTURED_PROMPT_FILE="$TMP_DIR/evaluator-prompt.txt"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT" "$PROJECT_DIR" "$MOCK_BIN"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-memory"

cat >"$TEST_ROOT/codex-memory/index.md" <<'EOF'
# Memory Index

- Keep evaluator prompts scoped to approved runtime behavior.
EOF

cat >"$PROJECT_DIR/memory.md" <<'EOF'
# Project Memory

- Prefer evaluation that checks the approved scope instead of broadening the task.
- Reuse the approved task shape before accepting a retry or success decision.
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-current-first-pass-eval",
      "title": "Fix first-pass metrics path",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-29T11:00:00Z",
      "updated_at": "2026-03-29T11:04:00Z",
      "task_intent": {
        "objective": "Fix first-pass metrics path",
        "context_hint": "Evaluate only the persisted first-pass metrics logic and its focused regression test.",
        "constraints": [
          "Do not broaden into unrelated metrics cleanup."
        ],
        "success_signals": [
          "The evaluation remains scoped to the approved first-pass metrics path."
        ],
        "affected_files": [
          "scripts/lib.sh",
          "tests/system-smoke.sh"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
      }
    }
  ]
}
EOF

cat >"$PLAN_FILE" <<'JSON'
{"status":"success","message":"ok","data":{"steps":["Inspect `scripts/lib.sh` and confirm the current first-pass metrics path.","In `scripts/lib.sh`, fix first-pass metrics path and update the focused regression test.","Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome."]}}
JSON

cat >"$STEP_FILE" <<'JSON'
{"index":2,"text":"In `scripts/lib.sh`, fix first-pass metrics path and update the focused regression test."}
JSON

cat >"$REVIEW_FILE" <<'JSON'
{
  "status": "approved",
  "message": "mock review ok",
  "data": {
    "step": "In `scripts/lib.sh`, fix first-pass metrics path and update the focused regression test.",
    "index": 2,
    "kind": "implement",
    "findings": []
  }
}
JSON

cat >"$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file=""
prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      prompt="$1"
      shift
      ;;
  esac
done
[ -n "$output_file" ] || exit 2
[ -n "${CAPTURED_PROMPT_FILE:-}" ] || exit 3
printf '%s' "$prompt" >"$CAPTURED_PROMPT_FILE"
cat >"$output_file" <<'JSON'
{
  "status": "success",
  "message": "mock evaluation ok",
  "data": {
    "step": "In `scripts/lib.sh`, fix first-pass metrics path and update the focused regression test.",
    "index": 2,
    "kind": "implement",
    "score": 8,
    "reason": "Review approved the bounded change and no blocking issue remains."
  }
}
JSON
EOF
chmod +x "$MOCK_BIN/codex"

(
  cd "$TEST_ROOT"
  PATH="$MOCK_BIN:$PATH" \
  CAPTURED_PROMPT_FILE="$CAPTURED_PROMPT_FILE" \
  TASK_ID="task-current-first-pass-eval" \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/evaluator.sh" \
    "$PROJECT_DIR" \
    "Fix first-pass metrics path" \
    "$STEP_FILE" \
    "$PLAN_FILE" \
    "$REVIEW_FILE" \
    "$OUTPUT_FILE" >/dev/null
)

grep -Fq 'PROJECT MEMORY:' "$CAPTURED_PROMPT_FILE"
grep -Fq 'Prefer evaluation that checks the approved scope instead of broadening the task.' "$CAPTURED_PROMPT_FILE"
grep -Fq 'CURRENT TASK SHAPE:' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Objective: Fix first-pass metrics path' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Focus: Evaluate only the persisted first-pass metrics logic and its focused regression test.' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Affected files: `scripts/lib.sh`, `tests/system-smoke.sh`' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Verification command: `bash tests/system-smoke.sh`' "$CAPTURED_PROMPT_FILE"

jq -e '
  .status == "success" and
  .message == "mock evaluation ok" and
  .data.score == 8 and
  .data.kind == "implement"
' "$OUTPUT_FILE" >/dev/null

echo "evaluator prompt context injection test passed"
