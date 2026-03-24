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
      "id": "task-dashboard-ownership",
      "title": "Make active worker ownership and progress explicit in the dashboard",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:05:00Z",
      "task_intent": {
        "objective": "Make active worker ownership and progress explicit in the dashboard",
        "context_hint": "Surface one additional deterministic live-work ownership signal without changing queue semantics.",
        "constraints": [
          "Keep the change scoped to the dashboard read path.",
          "Do not change queue execution behavior."
        ],
        "affected_files": [
          "codex-dashboard/server.js",
          "codex-dashboard/index.html"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/system-smoke.sh"
      }
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
    "Make active worker ownership and progress explicit in the dashboard" \
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
  (.data.step | contains("In `codex-dashboard/server.js`, `codex-dashboard/index.html`, implement the smallest safe change for: Make active worker ownership and progress explicit in the dashboard.")) and
  (.data.step | contains("Focus on Surface one additional deterministic live-work ownership signal without changing queue semantics.")) and
  (.data.step | contains("Keep these constraints: Keep the change scoped to the dashboard read path; Do not change queue execution behavior.")) and
  (.data.checks | index("Preferred verification command: bash tests/system-smoke.sh"))
' "$OUTPUT_FILE" >/dev/null

echo "coder fallback task intent test passed"
