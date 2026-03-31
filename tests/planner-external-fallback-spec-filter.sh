#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
MOCK_BIN="$TMP_DIR/bin"
OUTPUT_FILE="$TMP_DIR/plan.json"
MARKER_FILE="$TMP_DIR/provider-invoked"
PROJECT_DIR="$TEST_ROOT/projects/superheld/repo"

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
  "$PROJECT_DIR/packages/schema" \
  "$PROJECT_DIR/scripts" \
  "$PROJECT_DIR/.codex-agent" \
  "$TEST_ROOT/projects/superheld"

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$PROJECT_DIR",
  "memory_file": "$TEST_ROOT/projects/superheld/memory.md",
  "spec_file": "$TEST_ROOT/projects/superheld/spec.md",
  "policy_file": "$TEST_ROOT/projects/superheld/policy.json",
  "task_registry_file": "$PROJECT_DIR/.codex-agent/tasks.json"
}
EOF

cat >"$TEST_ROOT/projects/superheld/memory.md" <<'EOF'
# Project Memory

- Keep verify-baseline changes grounded to the project workspace.
EOF

cat >"$TEST_ROOT/projects/superheld/spec.md" <<'EOF'
# Project Spec

## First Milestones

17. Add verification gates so `bash scripts/verify-baseline.sh` guards the dashboard status, payload, and approval-state schema fields.
EOF

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "auto_approve_allowed": true
}
EOF

cat >"$PROJECT_DIR/scripts/verify-baseline.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
require_query() {
  :
}
EOF
chmod +x "$PROJECT_DIR/scripts/verify-baseline.sh"

cat >"$PROJECT_DIR/packages/schema/incident.schema.json" <<'EOF'
{
  "required": ["incident_id", "status", "approval_state", "learning_path"],
  "properties": {
    "status": {
      "type": "string",
      "enum": ["open", "pending_approval", "resolved"]
    },
    "approval_state": {
      "type": "string",
      "enum": ["pending", "approved", "denied", "postponed"]
    },
    "learning_path": {
      "type": "string"
    }
  }
}
EOF

cat >"$PROJECT_DIR/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-064-add-baseline-verification-for-dashboard-",
      "title": "Add baseline verification for dashboard payload contract fields",
      "project": "superheld",
      "status": "approved",
      "reason": "Start with `scripts/verify-baseline.sh` in the existing `require_query` block for `packages/schema/incident.schema.json`. `projects/superheld/spec.md` lists milestone `Add verification gates so `bash scripts/verify-baseline.sh` guards the dashboard status, payload, and approval-state schema fields.`, but baseline verification still does not guard the dashboard-facing incident status, postponed approval state, or the new payload fields. Add deterministic jq checks so these public contract fields cannot silently regress.",
      "target_files": [
        "scripts/verify-baseline.sh"
      ],
      "task_intent": {
        "objective": "Add baseline verification for dashboard payload contract fields",
        "project": "superheld",
        "category": "stability",
        "affected_files": [
          "scripts/verify-baseline.sh"
        ]
      },
      "execution_brief": {
        "editable_files": [
          "scripts/verify-baseline.sh"
        ],
        "affected_files": [
          "scripts/verify-baseline.sh"
        ],
        "frozen_verify_command": "bash scripts/verify-baseline.sh"
      }
    }
  ]
}
EOF

cat >"$MOCK_BIN/codex" <<'EOF'
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
chmod +x "$MOCK_BIN/codex"

TASK_TEXT='[self-improve:high] Add baseline verification for dashboard payload contract fields in scripts/verify-baseline.sh using packages/schema/incident.schema.json so dashboard status pending_approval, approval state postponed, and required payload fields stay guarded by one deterministic jq check.'

(
  cd "$TEST_ROOT"
  PATH="$MOCK_BIN:$PATH" \
  PLANNER_PROVIDER_MARKER="$MARKER_FILE" \
  TASK_ID="task-064-add-baseline-verification-for-dashboard-" \
  TASK_REGISTRY_FILE="$PROJECT_DIR/.codex-agent/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  PROJECT_NAME="superheld" \
  bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "$TASK_TEXT" "$OUTPUT_FILE" >/dev/null
)

if [ -e "$MARKER_FILE" ]; then
  echo "planner should have stayed on deterministic fallback for the oversized external task prompt" >&2
  exit 1
fi

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  .data.fallback.trigger == "oversized_task_prompt" and
  (.data.steps | length) == 3 and
  (.data.steps[0] | contains("scripts/verify-baseline.sh")) and
  (.data.steps[0] | contains("packages/schema/incident.schema.json")) and
  (.data.steps | join(" ") | contains("projects/superheld/spec.md") | not) and
  (.data.steps | join(" ") | contains("focused failing or currently missing regression test") | not)
' "$OUTPUT_FILE" >/dev/null

echo "planner external fallback spec filter test passed"
