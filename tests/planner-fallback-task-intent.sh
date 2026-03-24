#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-memory" "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-dashboard-intent-only",
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

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

CODEX_DISABLE=1 \
TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
ROOT_DIR="$TEST_ROOT" \
bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "Make active worker ownership and progress explicit in the dashboard" "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  (.data.steps | length) == 3 and
  (.data.steps[1] | contains("In `codex-dashboard/server.js`, `codex-dashboard/index.html`, implement the smallest safe change for: Make active worker ownership and progress explicit in the dashboard.")) and
  (.data.steps[1] | contains("Focus on Surface one additional deterministic live-work ownership signal without changing queue semantics.")) and
  (.data.steps[1] | contains("Keep these constraints: Keep the change scoped to the dashboard read path; Do not change queue execution behavior.")) and
  .data.steps[2] == "Run `bash tests/system-smoke.sh` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

echo "planner fallback task intent test passed"
