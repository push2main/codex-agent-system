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
      "id": "task-fallback-test-first",
      "title": "Fix first-pass metrics path",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:05:00Z",
      "task_intent": {
        "objective": "Fix first-pass metrics path",
        "context_hint": "Keep the persisted first-pass success metrics aligned with the dashboard rule.",
        "affected_files": [
          "scripts/lib.sh"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
      }
    }
  ]
}
EOF

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

CODEX_DISABLE=1 \
CLAUDE_DISABLE=1 \
TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
ROOT_DIR="$TEST_ROOT" \
bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "Fix first-pass metrics path" "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  (.data.steps | length) == 4 and
  (.data.steps[0] | contains("Fix first-pass metrics path")) and
  (.data.steps[1] | contains("`tests/system-smoke.sh`")) and
  (.data.steps[1] | contains("failing or currently missing regression test for: Fix first-pass metrics path.")) and
  (.data.steps[2] | contains("implement the smallest safe change for: Fix first-pass metrics path.")) and
  (.data.steps[2] | contains("Keep the persisted first-pass success metrics aligned with the dashboard rule.")) and
  .data.steps[3] == "Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

echo "planner test-first fallback test passed"
