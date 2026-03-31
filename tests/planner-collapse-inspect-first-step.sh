#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
MOCK_BIN="$TMP_DIR/bin"
OUTPUT_FILE="$TMP_DIR/plan.json"
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
  "$TEST_ROOT/projects/superheld/repo/docs/architecture" \
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

- Keep first-slice architecture docs deterministic.
EOF

cat >"$TEST_ROOT/projects/superheld/spec.md" <<'EOF'
# Spec

- Confirm mandatory MVP protection cases.
EOF

cat >"$TEST_ROOT/projects/superheld/policy.json" <<'EOF'
{
  "project": "superheld",
  "auto_approve_allowed": true
}
EOF

cat >"$PROJECT_DIR/docs/architecture/first-slice.md" <<'EOF'
# First Slice

## Scope

- existing scope entry
EOF

mkdir -p "$PROJECT_DIR/.codex-agent"
cat >"$PROJECT_DIR/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-current-first-slice-doc",
      "title": "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope.",
      "project": "superheld",
      "status": "approved",
      "created_at": "2026-03-30T10:51:26Z",
      "updated_at": "2026-03-30T10:51:26Z",
      "reason": "Start with `docs/architecture/first-slice.md` after `## Scope`. Add one deterministic section that enumerates the currently supported first-slice protection cases backed by the current playbooks.",
      "task_intent": {
        "objective": "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope.",
        "context_hint": "Start with `docs/architecture/first-slice.md` after `## Scope`.",
        "affected_files": [
          "docs/architecture/first-slice.md"
        ]
      },
      "task_shape": {
        "editable_files": [
          "docs/architecture/first-slice.md"
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
      "Step 1: In `docs/architecture/first-slice.md`, read the content immediately after the existing `## Scope` heading and identify the surrounding section structure, heading style, and list/table format already used in the document. Expected: you know the exact insertion point after `## Scope` and the local formatting pattern to match without editing any other file.",
      "Step 2: In `docs/architecture/first-slice.md`, insert a new `## Mandatory MVP Protection Cases` section directly after the `## Scope` section, and within it add a deterministic list that names the four currently supported first-slice protection cases backed by the exact playbook files `packages/playbooks/account_recovery_after_credential_risk.json`, `packages/playbooks/media_authenticity_risk_review.json`, `packages/playbooks/phishing_link_response.json`, and `packages/playbooks/social_message_risk_review.json`.",
      "Step 3 (verify): Run `python3 - <<'PY'\nfrom pathlib import Path\ntext = Path('docs/architecture/first-slice.md').read_text()\nassert '## Mandatory MVP Protection Cases' in text\nprint('ok')\nPY` and confirm it prints `ok`."
    ]
  }
}
JSON
EOF
chmod +x "$MOCK_BIN/codex"

(
  cd "$TEST_ROOT"
  PATH="$MOCK_BIN:$PATH" \
  PROJECT_NAME="superheld" \
  TASK_ID="task-current-first-slice-doc" \
  TASK_REGISTRY_FILE="$PROJECT_DIR/.codex-agent/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "[self-improve:medium] Document mandatory MVP protection cases in first slice -- Start with docs/architecture/first-slice.md after ## Scope." "$OUTPUT_FILE" >/dev/null
)

jq -e '
  .status == "success" and
  (.data.steps | length) == 2 and
  (.data.steps[0] | contains("insert a new `## Mandatory MVP Protection Cases` section")) and
  (.data.steps[0] | contains("read the content immediately after") | not) and
  (.data.steps[1] | contains("Step 2 (verify):")) and
  (.data.steps[1] | contains("python3 - <<'\''PY'\''"))
' "$OUTPUT_FILE" >/dev/null

echo "planner collapse inspect-first step test passed"
