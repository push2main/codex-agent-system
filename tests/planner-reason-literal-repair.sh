#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
MOCK_BIN="$TMP_DIR/bin"

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

- Keep contract literals aligned with the playbook reason.
EOF

cat >"$TEST_ROOT/projects/superheld/spec.md" <<'EOF'
# Spec

- The telemetry contract must match playbook trigger event types.
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
      "reason": "Start with `packages/schema/telemetry-event.schema.json` in `properties.event_type.enum` and the root `examples` array. `packages/playbooks/account_recovery_after_credential_risk.json` expects trigger event types `credential_risk_detected`, `user_reported_credential_exposure`, while the schema package rule says every incident must map to at least one event. Extend the root `examples` array with one canonical credential-risk event payload using `credential_risk_detected` so the new enum has concrete contract coverage.",
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$output_file" ] || exit 2
cat >"$output_file" <<'JSON'
{
  "status": "success",
  "message": "mock plan",
  "data": {
    "steps": [
      "Step 1: In packages/schema/telemetry-event.schema.json, inspect the existing enum and examples.",
      "Step 2: In packages/schema/telemetry-event.schema.json, add the missing `\"credential_recovery_trigger\"` literal to `properties.event_type.enum`, then append one new object in the root `examples` array that uses `\"event_type\": \"credential_recovery_trigger\"`.",
      "Step 3 (verify): Run `python - <<'PY'\nimport json\np='packages/schema/telemetry-event.schema.json'\nwith open(p) as f:\n    data=json.load(f)\nassert 'credential_recovery_trigger' in data['properties']['event_type']['enum']\nassert any(ex.get('event_type')=='credential_recovery_trigger' for ex in data.get('examples', []))\nprint('ok')\nPY` and confirm it prints `ok`."
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
  TASK_ID="task-current-telemetry-gap" \
  TASK_REGISTRY_FILE="$TEST_ROOT/projects/superheld/repo/.codex-agent/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "[self-improve:high] Add credential recovery trigger coverage to telemetry event schema -- Start with packages/schema/telemetry-event.schema." "$OUTPUT_FILE" >/dev/null
)

if jq -e '.data.steps[] | contains("credential_recovery_trigger")' "$OUTPUT_FILE" >/dev/null; then
  echo "planner should repair invented trigger literals back to the grounded playbook values" >&2
  exit 1
fi

grep -Fq 'credential_risk_detected' "$OUTPUT_FILE"
grep -Fq 'user_reported_credential_exposure' "$OUTPUT_FILE"
grep -Fq "python3 - <<'PY'" "$OUTPUT_FILE"
grep -Fq "assert 'credential_risk_detected' in enum_values" "$OUTPUT_FILE"
grep -Fq "assert 'user_reported_credential_exposure' in enum_values" "$OUTPUT_FILE"

echo "planner reason literal repair test passed"
