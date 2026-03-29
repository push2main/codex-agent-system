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
      "id": "task-timeout-repeat",
      "title": "Implement comprehensive Android and iOS deep linking for all app screens",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-25T10:00:00Z",
      "updated_at": "2026-03-25T10:01:00Z",
      "task_intent": {
        "objective": "Implement comprehensive Android and iOS deep linking for all app screens",
        "context_hint": "Keep the work bounded to one deterministic slice instead of planning the whole cross-platform feature at once.",
        "constraints": [
          "Touch at most 3 files.",
          "Preserve current routing behavior outside the chosen slice."
        ],
        "affected_files": [
          "app/src/main/AndroidManifest.xml",
          "ios/App/AppDelegate.swift"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T09:55:00Z","project":"codex-agent-system","task":"Implement comprehensive Android and iOS deep linking for all app screens","result":"FAILURE","failure_kind":"timeout","total_step_attempts":0,"failed_step":"zero-step timeout after 600s -- planner consumed full budget before step execution","task_id":"task-timeout-repeat"}
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
  bash "$TEST_ROOT/agents/planner.sh" \
    "$PROJECT_DIR" \
    "Implement comprehensive Android and iOS deep linking for all app screens" \
    "$OUTPUT_FILE" >/dev/null
)

if [ -e "$MARKER_FILE" ]; then
  echo "planner should have skipped provider execution after unresolved zero-step timeout history" >&2
  exit 1
fi

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  .data.fallback.trigger == "unresolved_zero_step_timeout" and
  .data.fallback.match_type == "exact_title" and
  .data.fallback.matched_title == "Implement comprehensive Android and iOS deep linking for all app screens" and
  ((.data.fallback.reason // "") | contains("planner consumed full budget before step execution")) and
  ((.data.steps | join(" ")) | contains("app/src/main/AndroidManifest.xml")) and
  ((.data.steps | join(" ")) | contains("ios/App/AppDelegate.swift")) and
  ((.data.steps | join(" ")) | contains("Touch at most 3 files")) and
  .data.steps[-1] == "Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

grep -Fq 'this exact title already has an unresolved zero-step timeout' "$TEST_ROOT/codex-logs/system.log"

echo "planner zero-step timeout fallback test passed"
