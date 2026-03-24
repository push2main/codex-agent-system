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
      "id": "task-inventory-runtime-state",
      "title": "Inventory current state for Reconcile registry running state against live queue leases before planning new work",
      "project": "codex-agent-system",
      "status": "approved",
      "strategy_template": "bounded_learning_inventory",
      "experiment": "Inspect only the files and surfaces named in the failed step, then write one compact inventory artifact at codex-memory/strategy-inventory-reconcile-registry-running-state-against.md that records the exact current hooks, fields, selectors, or write paths that matter for the next follow-up. Do not implement code changes in the same run.",
      "created_at": "2026-03-24T18:47:18Z",
      "updated_at": "2026-03-24T18:47:18Z"
    }
  ]
}
EOF

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

CODEX_DISABLE=1 \
TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
ROOT_DIR="$TEST_ROOT" \
bash "$TEST_ROOT/agents/planner.sh" \
  "$PROJECT_DIR" \
  "Inventory current state for Reconcile registry running state against live queue leases before planning new work" \
  "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  (.data.steps | length) == 3 and
  .data.steps[1] == "Inspect only the files and surfaces named in the failed step, then write one compact inventory artifact at codex-memory/strategy-inventory-reconcile-registry-running-state-against.md that records the exact current hooks, fields, selectors, or write paths that matter for the next follow-up. Do not implement code changes in the same run." and
  .data.steps[2] == "Run `test -s codex-memory/strategy-inventory-reconcile-registry-running-state-against.md` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

echo "planner fallback learning inventory test passed"
