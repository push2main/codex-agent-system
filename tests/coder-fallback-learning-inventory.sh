#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"
PLAN_FILE="$TMP_DIR/plan.json"
STEP_FILE="$TMP_DIR/step.json"
MEMORY_FILE="$TMP_DIR/memory.txt"
OUTPUT_FILE="$TMP_DIR/coder.json"

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
  "$TEST_ROOT/projects" \
  "$PROJECT_DIR"

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

cat >"$PLAN_FILE" <<'JSON'
{"status":"success","message":"ok","data":{"steps":["Inspect the current project files and choose the smallest safe implementation.","Implement the requested change with minimal modifications.","Run a lightweight verification relevant to the task and confirm the outcome."]}}
JSON

cat >"$STEP_FILE" <<'JSON'
{"index":2,"text":"Implement the requested change with minimal modifications."}
JSON

cat >"$MEMORY_FILE" <<'EOF'
# Memory
EOF

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  bash "$TEST_ROOT/agents/coder.sh" \
    "$PROJECT_DIR" \
    "Inventory current state for Reconcile registry running state against live queue leases before planning new work" \
    "$STEP_FILE" \
    "$PLAN_FILE" \
    "$MEMORY_FILE" \
    "" \
    "$OUTPUT_FILE" >/dev/null
)

jq -e '
  .status == "fail" and
  .message == "Fallback implementation requires bounded task-specific execution." and
  .data.changed == false and
  (.data.files | length) == 0 and
  .data.step == "Inspect only the files and surfaces named in the failed step, then write one compact inventory artifact at codex-memory/strategy-inventory-reconcile-registry-running-state-against.md that records the exact current hooks, fields, selectors, or write paths that matter for the next follow-up. Do not implement code changes in the same run." and
  (.data.checks | index("Preferred verification command: test -s codex-memory/strategy-inventory-reconcile-registry-running-state-against.md"))
' "$OUTPUT_FILE" >/dev/null

echo "coder fallback learning inventory test passed"
