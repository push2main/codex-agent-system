#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-current",
      "title": "Tighten late timeout reconciliation for claimed queue tasks",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-24T19:00:00Z",
      "original_failed_root_id": "task-root-timeout",
      "strategy_template": "runtime_restart_needed_state",
      "task_intent": {
        "objective": "Tighten late timeout reconciliation for claimed queue tasks"
      }
    },
    {
      "id": "task-root-sibling",
      "title": "Persist restart-needed runtime state when helper scripts change",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-24T18:00:00Z",
      "original_failed_root_id": "task-root-timeout",
      "strategy_template": "runtime_restart_needed_state",
      "task_intent": {
        "objective": "Tighten late timeout reconciliation for claimed queue tasks"
      },
      "failure_context": {
        "failed_step": "Patch only the claimed-task timeout reconciliation path in scripts/lib.sh."
      }
    },
    {
      "id": "task-unrelated-token-match",
      "title": "Tighten timeout queue task status reconciliation visibility",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-24T18:30:00Z",
      "original_failed_root_id": "task-root-other",
      "strategy_template": "structured_failure_context",
      "failure_context": {
        "failed_step": "Inspect queue task timeout reconciliation visibility and broader status rendering."
      }
    }
  ]
}
EOF

CONTEXT_JSON="$(
  cd "$TEST_ROOT"
  bash -lc 'source scripts/lib.sh; build_similar_task_context "Tighten late timeout reconciliation for claimed queue tasks" "codex-agent-system" "task-current"'
)"

python3 - <<'PY' "$CONTEXT_JSON"
import json
import sys

payload = json.loads(sys.argv[1])
assert payload[0]["id"] == "task-current"
assert payload[1]["id"] == "task-root-sibling"
assert payload[2]["id"] == "task-unrelated-token-match"
PY

echo "similar task root preference test passed"
