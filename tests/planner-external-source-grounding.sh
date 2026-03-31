#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
MOCK_BIN="$TMP_DIR/bin"
CAPTURED_PROMPT_FILE="$TMP_DIR/planner-prompt.txt"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT" "$MOCK_BIN"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects/superheld/repo/packages/schema" \
  "$TEST_ROOT/projects/superheld"

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$TEST_ROOT/projects/superheld/repo",
  "memory_file": "$TEST_ROOT/projects/superheld/memory.md",
  "spec_file": "$TEST_ROOT/projects/superheld/spec.md",
  "policy_file": "$TEST_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$TEST_ROOT/projects/superheld/repo/.codex-agent/tasks.json"
}
EOF

cat >"$TEST_ROOT/projects/superheld/memory.md" <<'EOF'
# Project Memory

- Keep telemetry schema work grounded to the project workspace.
EOF

cat >"$TEST_ROOT/projects/superheld/spec.md" <<'EOF'
# Spec

- Telemetry and incident contracts live in packages/schema.
EOF

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "auto_approve_allowed": true
}
EOF

cat >"$TEST_ROOT/projects/superheld/repo/packages/schema/telemetry-event.schema.json" <<'EOF'
{
  "properties": {
    "event_type": {
      "enum": [
        "social_message_risk_detected"
      ]
    }
  },
  "examples": []
}
EOF

mkdir -p "$TEST_ROOT/projects/superheld/repo/.codex-agent"
cat >"$TEST_ROOT/projects/superheld/repo/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-current-telemetry-gap",
      "title": "[self-improve:high] Add credential recovery trigger coverage to telemetry event schema -- Start with packages/schema/telemetry-event.schema.",
      "project": "superheld",
      "status": "approved",
      "created_at": "2026-03-30T06:48:04Z",
      "updated_at": "2026-03-30T06:49:46Z",
      "reason": "Start with `packages/schema/telemetry-event.schema.json` in `properties.event_type.enum` and the root `examples` array. `packages/playbooks/account_recovery_after_credential_risk.json` expects trigger event types `credential_risk_detected`, `user_reported_credential_exposure`.",
      "task_intent": {
        "objective": "[self-improve:high] Add credential recovery trigger coverage to telemetry event schema -- Start with packages/schema/telemetry-event.schema.",
        "context_hint": "Start with `packages/schema/telemetry-event.schema.json` in `properties.event_type.enum` and the root `examples` array.",
        "affected_files": [
          "packages/schema/telemetry-event.schema.json"
        ]
      },
      "task_shape": {
        "editable_files": [
          "packages/schema/telemetry-event.schema.json"
        ]
      }
    }
  ]
}
EOF

cat >"$MOCK_BIN/codex" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output_file=""
prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      prompt="$1"
      shift
      ;;
  esac
done
[ -n "$output_file" ] || exit 2
[ -n "${CAPTURED_PROMPT_FILE:-}" ] || exit 3
printf '%s' "$prompt" >"$CAPTURED_PROMPT_FILE"
cat >"$output_file" <<'JSON'
{
  "status": "success",
  "message": "mock plan",
  "data": {
    "steps": [
      "Step 1: In packages/schema/telemetry-event.schema.json, inspect the enum and examples.",
      "Step 2: In packages/schema/telemetry-event.schema.json, add the missing literals and example.",
      "Step 3 (verify): Run `python3 -m json.tool packages/schema/telemetry-event.schema.json > /dev/null` and confirm it passes."
    ]
  }
}
JSON
EOF
chmod +x "$MOCK_BIN/codex"

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/superheld/repo"

(
  cd "$TEST_ROOT"
  PATH="$MOCK_BIN:$PATH" \
  PROJECT_NAME="superheld" \
  CAPTURED_PROMPT_FILE="$CAPTURED_PROMPT_FILE" \
  TASK_ID="task-current-telemetry-gap" \
  TASK_REGISTRY_FILE="$TEST_ROOT/projects/superheld/repo/.codex-agent/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "[self-improve:high] Add credential recovery trigger coverage to telemetry event schema -- Start with packages/schema/telemetry-event.schema." "$OUTPUT_FILE" >/dev/null
)

grep -Fq 'CURRENT TASK SHAPE:' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Reason anchor: Start with `packages/schema/telemetry-event.schema.json` in `properties.event_type.enum` and the root `examples` array. `packages/playbooks/account_recovery_after_credential_risk.json` expects trigger event types `credential_risk_detected`, `user_reported_credential_exposure`.' "$CAPTURED_PROMPT_FILE"
grep -Fq 'RELEVANT SOURCE:' "$CAPTURED_PROMPT_FILE"
grep -Fq 'FILE projects/superheld/repo/packages/schema/telemetry-event.schema.json' "$CAPTURED_PROMPT_FILE"
if grep -Fq 'FILE codex-dashboard/server.js' "$CAPTURED_PROMPT_FILE"; then
  echo "planner prompt should not inject codex-agent-system dashboard source for a grounded superheld schema task" >&2
  exit 1
fi

echo "planner external source grounding test passed"
