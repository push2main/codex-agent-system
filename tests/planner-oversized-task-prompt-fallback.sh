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
  "tasks": []
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

TASK_TEXT='[self-improve:low] Drain approval backlog -- 12 active approvals are waiting (12 approved). Review pending approvals, pause strategy generation if needed, and increase queue throughput once items are approved. (files: scripts/multi-queue.sh)'

(
  cd "$TEST_ROOT"
  PATH="$TEST_ROOT/bin:$PATH" \
  CLAUDE_DISABLE=1 \
  PLANNER_PROVIDER_MARKER="$MARKER_FILE" \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  TASK_LOG="$TEST_ROOT/codex-memory/tasks.log" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/planner.sh" \
    "$PROJECT_DIR" \
    "$TASK_TEXT" \
    "$OUTPUT_FILE" >/dev/null
)

if [ -e "$MARKER_FILE" ]; then
  echo "planner should have skipped provider execution for an oversized multi-clause task prompt" >&2
  exit 1
fi

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  .data.fallback.trigger == "oversized_task_prompt" and
  ((.data.fallback.reason // "") | contains("task prompt has")) and
  ((.data.steps | join(" ")) | contains("scripts/multi-queue.sh")) and
  (.data.steps | length) == 3
' "$OUTPUT_FILE" >/dev/null

grep -Fq 'task prompt is oversized for provider planning' "$TEST_ROOT/codex-logs/system.log"

echo "planner oversized task prompt fallback test passed"
