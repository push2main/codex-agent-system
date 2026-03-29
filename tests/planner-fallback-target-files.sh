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
      "id": "task-self-improve-timeout",
      "title": "Reduce timeout rate",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-28T02:17:16Z",
      "updated_at": "2026-03-28T02:17:16Z",
      "task_intent": {
        "source": "self-improve",
        "objective": "Reduce timeout rate",
        "project": "codex-agent-system",
        "category": "performance",
        "context_hint": "Keep the fix scoped to the existing timeout path."
      },
      "target_files": [
        "agents/planner.sh",
        "agents/orchestrator.sh",
        "scripts/queue-worker.sh"
      ]
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
bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "Reduce timeout rate" "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  (.data.steps | length) == 3 and
  (.data.steps[0] | contains("Inspect only `agents/planner.sh`, `agents/orchestrator.sh`, `scripts/queue-worker.sh`")) and
  (.data.steps[1] | contains("In `agents/planner.sh`, `agents/orchestrator.sh`, `scripts/queue-worker.sh`, implement the smallest safe change for: Reduce timeout rate.")) and
  (.data.steps[1] | contains("Focus on Keep the fix scoped to the existing timeout path."))
' "$OUTPUT_FILE" >/dev/null

echo "planner fallback target-files test passed"
