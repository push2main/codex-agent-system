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
      "id": "task-learning-inventory-current",
      "title": "Inventory current decision path for recover stale pipeline",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-28T07:00:00Z",
      "updated_at": "2026-03-28T07:01:00Z",
      "strategy_template": "bounded_learning_inventory",
      "experiment": "Inspect the current code path most directly related to recover stale pipeline, starting with scripts/multi-queue.sh, then write one compact inventory artifact at codex-memory/self-improve-inventory-recover-stale-pipeline.md. Expected: identify one existing file and one concrete edit location before making changes. Record secondary files, functions, metrics, or gates only when they directly feed that primary edit site. Do not implement code changes in the same run.",
      "task_intent": {
        "objective": "Inventory current decision path for recover stale pipeline",
        "context_hint": "Direct retries are paused while the live weakness signal is still active.",
        "affected_files": [
          "scripts/multi-queue.sh"
        ]
      }
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"

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
  TASK_ID="task-learning-inventory-current" \
  bash "$TEST_ROOT/agents/planner.sh" \
    "$PROJECT_DIR" \
    "Inventory current decision path for recover stale pipeline" \
    "$OUTPUT_FILE" >/dev/null
)

if [ -e "$MARKER_FILE" ]; then
  echo "planner should have skipped provider execution for bounded learning inventory tasks" >&2
  exit 1
fi

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  .data.fallback.trigger == "bounded_learning_inventory" and
  ((.data.fallback.reason // "") | contains("inventory-only follow-up")) and
  ((.data.steps | join(" ")) | contains("scripts/multi-queue.sh")) and
  ((.data.steps | join(" ")) | contains("self-improve-inventory-recover-stale-pipeline.md")) and
  .data.steps[-1] == "Run `test -s codex-memory/self-improve-inventory-recover-stale-pipeline.md` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

grep -Fq 'bounded inventory-only follow-up' "$TEST_ROOT/codex-logs/system.log"

echo "planner bounded learning inventory fallback test passed"
