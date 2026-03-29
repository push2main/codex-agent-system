#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"
PLAN_FILE="$TMP_DIR/plan.json"
STEP_FILE="$TMP_DIR/step.json"
OUTPUT_FILE="$TMP_DIR/coder.json"
MOCK_BIN="$TMP_DIR/bin"
CAPTURED_PROMPT_FILE="$TMP_DIR/coder-prompt.txt"

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

- Preserve dashboard queue semantics while improving operator visibility.
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-current-dashboard-ownership",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-29T10:00:00Z",
      "updated_at": "2026-03-29T10:04:00Z",
      "task_intent": {
        "objective": "Make active worker ownership and progress explicit in the dashboard",
        "context_hint": "Surface one additional deterministic live-work ownership signal without changing queue semantics.",
        "constraints": [
          "Keep the change scoped to the dashboard read path.",
          "Do not change queue execution behavior."
        ],
        "success_signals": [
          "The live work strip shows one extra ownership signal deterministically."
        ],
        "affected_files": [
          "codex-dashboard/server.js",
          "codex-dashboard/index.html"
        ]
      },
      "task_shape": {
        "editable_files": [
          "codex-dashboard/server.js"
        ],
        "frozen_files": [
          "codex-dashboard/index.html"
        ],
        "verification_command": "bash tests/system-smoke.sh"
      },
      "execution_brief": {
        "editable_files": [
          "codex-dashboard/server.js"
        ],
        "frozen_files": [
          "codex-dashboard/index.html"
        ],
        "frozen_verify_command": "bash tests/system-smoke.sh"
      }
    }
  ]
}
EOF

cat >"$PLAN_FILE" <<'JSON'
{"status":"success","message":"ok","data":{"steps":["Inspect the current dashboard files and identify the live work ownership path.","Update the bounded dashboard ownership indicator without changing queue execution semantics.","Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome."]}}
JSON

cat >"$STEP_FILE" <<'JSON'
{"index":1,"text":"Inspect the current dashboard files and identify the live work ownership path."}
JSON

cat >"$PROJECT_DIR/memory.md" <<'EOF'
# Project Memory

- Preserve dashboard queue semantics while improving operator visibility.
- Prefer existing dashboard read-path helpers over introducing a parallel live-work state path.
EOF

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
  "message": "mock coder inspection",
  "data": {
    "step": "Inspect the current dashboard files and identify the live work ownership path.",
    "index": 1,
    "kind": "inspect",
    "summary": "Reviewed the current dashboard ownership path.",
    "files": ["codex-dashboard/server.js"],
    "checks": ["reviewed current dashboard ownership flow"],
    "changed": false
  }
}
JSON
EOF

chmod +x "$MOCK_BIN/codex"

(
  cd "$TEST_ROOT"
  PATH="$MOCK_BIN:$PATH" \
  CAPTURED_PROMPT_FILE="$CAPTURED_PROMPT_FILE" \
  TASK_ID="task-current-dashboard-ownership" \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/coder.sh" \
    "$PROJECT_DIR" \
    "Make active worker ownership and progress explicit in the dashboard" \
    "$STEP_FILE" \
    "$PLAN_FILE" \
    "" \
    "" \
    "$OUTPUT_FILE" >/dev/null
)

grep -Fq 'PROJECT MEMORY:' "$CAPTURED_PROMPT_FILE"
grep -Fq 'Preserve dashboard queue semantics while improving operator visibility.' "$CAPTURED_PROMPT_FILE"
grep -Fq 'CURRENT TASK SHAPE:' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Objective: Make active worker ownership and progress explicit in the dashboard' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Focus: Surface one additional deterministic live-work ownership signal without changing queue semantics.' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Editable files: `codex-dashboard/server.js`' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Affected files: `codex-dashboard/server.js`, `codex-dashboard/index.html`' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Frozen files: `codex-dashboard/index.html`' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Frozen verification command: `bash tests/system-smoke.sh`' "$CAPTURED_PROMPT_FILE"
grep -Fq 'do not edit outside those files' "$CAPTURED_PROMPT_FILE"

jq -e '
  .status == "success" and
  .message == "mock coder inspection" and
  .data.kind == "inspect" and
  .data.changed == false
' "$OUTPUT_FILE" >/dev/null

echo "coder prompt context injection test passed"
