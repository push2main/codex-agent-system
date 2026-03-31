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
      "id": "task-self-improve-inventory",
      "title": "[self-improve:critical] Inventory current decision path for improve first-pass success rate -- Direct retries for improve first-pass success rate are currently paused by saturated_family_cooldown while the live weakness signal is still active. Reuse the bounded inventory pattern to capture the exact files, functions, and decision points before another implementation retry. (files: agents/planner.sh)",
      "project": "codex-agent-system",
      "status": "approved",
      "strategy_template": "bounded_learning_inventory",
      "experiment": "Inspect the current code path most directly related to improve first-pass success rate, starting with agents/planner.sh, then write one compact inventory artifact at codex-memory/self-improve-inventory-improve-first-pass-success-rate.md. Expected: identify one existing file and one concrete edit location before making changes. Record secondary files, functions, metrics, or gates only when they directly feed that primary edit site. Do not implement code changes in the same run.",
      "created_at": "2026-03-28T06:45:00Z",
      "updated_at": "2026-03-28T06:45:00Z"
    }
  ]
}
EOF

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"
TASK_TEXT="[self-improve:critical] Inventory current decision path for improve first-pass success rate -- Direct retries for improve first-pass success rate are currently paused by saturated_family_cooldown while the live weakness signal is still active. Reuse the bounded inventory pattern to capture the exact files, functions, and decision points before another implementation retry. (files: agents/planner.sh)"

CODEX_DISABLE=1 \
TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
ROOT_DIR="$TEST_ROOT" \
bash "$TEST_ROOT/agents/planner.sh" \
  "$PROJECT_DIR" \
  "$TASK_TEXT" \
  "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  (.data.steps | length) == 3 and
  (.data.steps[0] | contains("Inspect only `agents/planner.sh`")) and
  (.data.steps[0] | contains("Do not modify any file in this step")) and
  (.data.steps[0] | contains("codex-memory/self-improve-inventory-improve-first-pass-success-rate.md") | not) and
  .data.steps[2] == "Run `test -s codex-memory/self-improve-inventory-improve-first-pass-success-rate.md` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

echo "planner self-improve inventory artifact filter test passed"
