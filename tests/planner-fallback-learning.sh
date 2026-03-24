#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-memory" "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-previous-failed-metrics-fix",
      "title": "Fix first-pass metrics path",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-24T06:00:00Z",
      "updated_at": "2026-03-24T07:12:56Z",
      "task_intent": {
        "objective": "Fix first-pass metrics path"
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
      },
      "failure_context": {
        "failed_step": "Inspect only `scripts/lib.sh` and mirror the exact same successful-completed-task filter, first-pass rule, rate calculation, and threshold for the persisted metrics path without adding fields, renaming keys, or changing storage format."
      }
    }
  ]
}
EOF

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

CODEX_DISABLE=1 \
TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
ROOT_DIR="$TEST_ROOT" \
bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "Fix first-pass metrics path" "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  (.data.steps | length) == 3 and
  .data.steps[1] == "Inspect only `scripts/lib.sh` and mirror the exact same successful-completed-task filter, first-pass rule, rate calculation, and threshold for the persisted metrics path without adding fields, renaming keys, or changing storage format." and
  .data.steps[2] == "Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

echo "planner fallback learning test passed"
