#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
MOCK_BIN="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT" "$MOCK_BIN"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-memory" "$TEST_ROOT/projects/codex-agent-system"

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
        "context_hint": "Derived from saturated experiment: Align persisted first-pass success metrics"
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

cat >"$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$output_file" ] || exit 2
cat >"$output_file" <<'JSON'
{
  "status": "success",
  "message": "mock generic provider plan",
  "data": {
    "steps": [
      "Inspect the current project files and choose the smallest safe implementation for: Fix first-pass metrics path",
      "Implement the requested change with minimal modifications.",
      "Run a lightweight verification relevant to the task and confirm the outcome."
    ]
  }
}
JSON
EOF

chmod +x "$MOCK_BIN/codex"

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

(
  cd "$TEST_ROOT"
  PATH="$MOCK_BIN:$PATH" \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "Fix first-pass metrics path" "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"
)

jq -e '
  .status == "success" and
  .message == "mock generic provider plan" and
  (.data.steps | length) == 4 and
  (.data.steps[1] | contains("`tests/system-smoke.sh`")) and
  (.data.steps[1] | contains("failing or currently missing regression test for: Fix first-pass metrics path.")) and
  (.data.steps[2] | contains("implement the smallest safe change for: Fix first-pass metrics path.")) and
  (.data.steps[2] | contains("Focus on Derived from saturated experiment: Align persisted first-pass success metrics.")) and
  .data.steps[3] == "Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

echo "planner generic step repair test passed"
