#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"
OUTPUT_FILE="$TMP_DIR/plan.json"
MARKER_FILE="$TMP_DIR/provider-invoked"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/bin" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-followup-current",
      "title": "Inventory current state for Reconcile registry running state against live queue leases before planning new work",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-25T10:10:00Z",
      "updated_at": "2026-03-25T10:11:00Z",
      "original_failed_root_id": "task-root-timeout",
      "strategy_template": "structured_failure_context",
      "task_intent": {
        "objective": "Reconcile registry running state against live queue leases before planning new work",
        "context_hint": "Keep the fix limited to the claimed-task reconciliation path.",
        "constraints": [
          "Touch at most 2 files.",
          "Preserve lease handling for unrelated queue states."
        ],
        "affected_files": [
          "scripts/lib.sh",
          "scripts/queue-worker.sh"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/task-id-lease-release.sh"
      }
    },
    {
      "id": "task-root-sibling",
      "title": "Reconcile registry running state against live queue leases before planning new work",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-25T09:40:00Z",
      "updated_at": "2026-03-25T10:00:00Z",
      "original_failed_root_id": "task-root-timeout",
      "strategy_template": "structured_failure_context",
      "task_intent": {
        "objective": "Reconcile registry running state against live queue leases before planning new work"
      },
      "failure_context": {
        "failed_step": "Patch only the claimed-task lease reconciliation branch in scripts/lib.sh."
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T10:05:00Z","project":"codex-agent-system","task":"Reconcile registry running state against live queue leases before planning new work","result":"FAILURE","failure_kind":"timeout","total_step_attempts":0,"failed_step":"zero-step timeout after 420s -- planner consumed full budget before step execution","task_id":"task-root-sibling"}
EOF

cat >"$TEST_ROOT/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'invoked\n' >>"${PLANNER_PROVIDER_MARKER:?}"
output_file=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ] && [ "$#" -ge 2 ]; then
    output_file="$2"
    shift 2
    continue
  fi
  shift
done
if [ -n "$output_file" ]; then
  cat >"$output_file" <<'JSON'
{"status":"success","message":"provider should not run","data":{"steps":["Step 1: provider path.","Step 2 (verify): Run `true` and confirm success."]}}
JSON
fi
EOF
chmod +x "$TEST_ROOT/bin/codex"

(
  cd "$TEST_ROOT"
  PATH="$TEST_ROOT/bin:$PATH" \
  CLAUDE_DISABLE=1 \
  PLANNER_PROVIDER_MARKER="$MARKER_FILE" \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  TASK_LOG="$TEST_ROOT/codex-memory/tasks.log" \
  ROOT_DIR="$TEST_ROOT" \
  TASK_ID="task-followup-current" \
  bash "$TEST_ROOT/agents/planner.sh" \
    "$PROJECT_DIR" \
    "Inventory current state for Reconcile registry running state against live queue leases before planning new work" \
    "$OUTPUT_FILE" >/dev/null
)

if [ -e "$MARKER_FILE" ]; then
  echo "planner should have skipped provider execution after a same-root unresolved zero-step timeout" >&2
  exit 1
fi

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  .data.fallback.trigger == "unresolved_zero_step_timeout" and
  .data.fallback.match_type == "lineage" and
  .data.fallback.matched_title == "Reconcile registry running state against live queue leases before planning new work" and
  ((.data.fallback.reason // "") | contains("planner consumed full budget before step execution")) and
  ((.data.steps | join(" ")) | contains("scripts/lib.sh")) and
  ((.data.steps | join(" ")) | contains("claimed-task reconciliation path")) and
  ((.data.steps | join(" ")) | contains("Touch at most 2 files")) and
  .data.steps[-1] == "Run `bash tests/task-id-lease-release.sh` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

grep -Fq 'same-root or same-objective lineage already has an unresolved zero-step timeout' "$TEST_ROOT/codex-logs/system.log"

echo "planner zero-step timeout root fallback test passed"
