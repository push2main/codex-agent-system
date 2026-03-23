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
mkdir -p "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-memory" "$TEST_ROOT/projects/step-bounds"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-small-ui",
      "title": "small ui task",
      "project": "step-bounds",
      "category": "ui",
      "effort": 2,
      "status": "approved",
      "created_at": "2026-03-23T09:00:00Z",
      "updated_at": "2026-03-23T09:00:00Z"
    }
  ]
}
EOF

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/step-bounds"

CODEX_DISABLE=1 \
TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
ROOT_DIR="$TEST_ROOT" \
bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "small ui task" "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  (.data.steps | length) >= 2 and
  (.data.steps | length) <= 3
' "$OUTPUT_FILE" >/dev/null

echo "planner step bounds test passed"
