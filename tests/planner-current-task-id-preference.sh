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
      "id": "task-dashboard-current",
      "title": "Cut dashboard task-registry read amplification before growth stalls the loop",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-24T11:21:28Z",
      "updated_at": "2026-03-24T11:21:28Z",
      "task_intent": {
        "objective": "Cut dashboard task-registry read amplification before growth stalls the loop",
        "context_hint": "Reuse the existing artifact-bundle and task-registry cache patterns so one refresh cycle shares one normalized registry snapshot instead of reloading nested dashboard readers.",
        "constraints": [
          "Touch only dashboard task-registry read-path code and its focused regression tests.",
          "Do not change task schemas, approval flow, queue semantics, or strategy task generation."
        ],
        "affected_files": [
          "codex-dashboard/server.js",
          "tests/dashboard-task-registry-cache.sh"
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/dashboard-task-registry-cache.sh && bash tests/dashboard-artifact-bundle.sh"
      }
    },
    {
      "id": "task-dashboard-old-failure",
      "title": "Cut dashboard task-registry read amplification before growth stalls the loop",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:05:00Z",
      "failure_context": {
        "failed_step": "Inspect `codex-dashboard/server.js` and `scripts/lib.sh` together, confirm the exact first-pass success filter/rule/threshold already used in the dashboard path, then patch only the persisted metrics logic in `scripts/lib.sh`."
      },
      "task_shape": {
        "verification_command": "bash scripts/run-playwright-docker.sh bash tests/dashboard-screenshot-verification.sh"
      }
    }
  ]
}
EOF

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

CODEX_DISABLE=1 \
CLAUDE_DISABLE=1 \
TASK_ID="task-dashboard-current" \
TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
ROOT_DIR="$TEST_ROOT" \
bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "Cut dashboard task-registry read amplification before growth stalls the loop" "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"

jq -e '
  .status == "success" and
  .message == "Created deterministic fallback plan." and
  (.data.steps | length) == 3 and
  (.data.steps[0] | contains("Inspect only `codex-dashboard/server.js`, `tests/dashboard-task-registry-cache.sh`")) and
  (.data.steps[1] | contains("In `codex-dashboard/server.js`, `tests/dashboard-task-registry-cache.sh`, implement the smallest safe change for: Cut dashboard task-registry read amplification before growth stalls the loop.")) and
  (.data.steps[1] | contains("Focus on Reuse the existing artifact-bundle and task-registry cache patterns so one refresh cycle shares one normalized registry snapshot instead of reloading nested dashboard readers.")) and
  (.data.steps[1] | contains("Touch only dashboard task-registry read-path code and its focused regression tests; Do not change task schemas, approval flow, queue semantics, or strategy task generation.")) and
  .data.steps[2] == "Run `bash tests/dashboard-task-registry-cache.sh && bash tests/dashboard-artifact-bundle.sh` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

echo "planner current task id preference test passed"
