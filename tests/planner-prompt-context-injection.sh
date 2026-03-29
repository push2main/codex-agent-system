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
cp -R "$ROOT_DIR/playbooks" "$TEST_ROOT/playbooks"
mkdir -p "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-memory" "$TEST_ROOT/projects/codex-agent-system"

cat >"$TEST_ROOT/codex-memory/index.md" <<'EOF'
# Memory Index

- Always keep queue state deterministic.
EOF

cat >"$TEST_ROOT/codex-memory/decisions.md" <<'EOF'
- Recent decision: keep planner prompts compact and scoped.
EOF

cat >"$TEST_ROOT/projects/codex-agent-system/memory.md" <<'EOF'
# Project Memory

- Queue backlog recovery must not change approval semantics.
- Reuse the existing queue state helpers before adding a new path.
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-current-queue-recovery",
      "title": "Keep queue backlog recovery deterministic",
      "project": "codex-agent-system",
      "status": "approved",
      "created_at": "2026-03-29T07:55:00Z",
      "updated_at": "2026-03-29T08:01:00Z",
      "task_intent": {
        "objective": "Keep queue backlog recovery deterministic",
        "context_hint": "Patch only the queue drain reconciliation path without changing approval semantics.",
        "constraints": [
          "Keep the change inside the existing queue reconciliation path.",
          "Do not add a parallel approval flow."
        ],
        "success_signals": [
          "Queue drain behavior stays deterministic under replay."
        ],
        "affected_files": [
          "scripts/multi-queue.sh",
          "scripts/lib.sh"
        ]
      },
      "task_shape": {
        "editable_files": [
          "scripts/multi-queue.sh"
        ],
        "frozen_files": [
          "scripts/lib.sh"
        ],
        "playbook": "playbooks/stale-pipeline.md",
        "verification_command": "bash tests/queue-hot-reload-drain.sh"
      },
      "execution_brief": {
        "editable_files": [
          "scripts/multi-queue.sh"
        ],
        "frozen_files": [
          "scripts/lib.sh"
        ],
        "frozen_verify_command": "bash tests/queue-hot-reload-drain.sh"
      }
    },
    {
      "id": "task-historical-queue-recovery",
      "title": "Keep queue backlog recovery deterministic",
      "project": "codex-agent-system",
      "status": "failed",
      "created_at": "2026-03-28T08:00:00Z",
      "updated_at": "2026-03-28T08:05:00Z",
      "reason": "Queue drain completion anomaly",
      "failure_context": {
        "failed_step": "Inspect `scripts/multi-queue.sh` and patch only the queue drain reconciliation branch."
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
  "message": "mock planner plan",
  "data": {
    "steps": [
      "Inspect `scripts/multi-queue.sh` and identify the queue drain branch to update.",
      "In `scripts/multi-queue.sh`, keep the queue backlog recovery deterministic without changing approval semantics.",
      "Run `bash tests/queue-hot-reload-drain.sh` and confirm the exact pass/fail outcome."
    ]
  }
}
JSON
EOF

chmod +x "$MOCK_BIN/codex"

OUTPUT_FILE="$TMP_DIR/plan.json"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

(
  cd "$TEST_ROOT"
  PATH="$MOCK_BIN:$PATH" \
  CAPTURED_PROMPT_FILE="$CAPTURED_PROMPT_FILE" \
  TASK_ID="task-current-queue-recovery" \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  ROOT_DIR="$TEST_ROOT" \
  bash "$TEST_ROOT/agents/planner.sh" "$PROJECT_DIR" "Keep queue backlog recovery deterministic" "$OUTPUT_FILE" >"$TMP_DIR/planner.stdout"
)

grep -Fq 'PROJECT MEMORY:' "$CAPTURED_PROMPT_FILE"
grep -Fq 'Queue backlog recovery must not change approval semantics.' "$CAPTURED_PROMPT_FILE"
grep -Fq 'CURRENT TASK SHAPE:' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Objective: Keep queue backlog recovery deterministic' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Focus: Patch only the queue drain reconciliation path without changing approval semantics.' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Editable files: `scripts/multi-queue.sh`' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Affected files: `scripts/multi-queue.sh`, `scripts/lib.sh`' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Frozen files: `scripts/lib.sh`' "$CAPTURED_PROMPT_FILE"
grep -Fq -- '- Frozen verification command: `bash tests/queue-hot-reload-drain.sh`' "$CAPTURED_PROMPT_FILE"
grep -Fq 'every non-verification step MUST stay within those files' "$CAPTURED_PROMPT_FILE"
grep -Fq 'PLAYBOOK:' "$CAPTURED_PROMPT_FILE"
grep -Fq 'Path: playbooks/stale-pipeline.md' "$CAPTURED_PROMPT_FILE"
grep -Fq 'Treat stale-pipeline work as queue and execution recovery, not broad feature work.' "$CAPTURED_PROMPT_FILE"
grep -Fq 'SIMILAR TASKS:' "$CAPTURED_PROMPT_FILE"
grep -Fq '"id": "task-current-queue-recovery"' "$CAPTURED_PROMPT_FILE"
grep -Fq '"current_task": true' "$CAPTURED_PROMPT_FILE"

jq -e '
  .status == "success" and
  .message == "mock planner plan" and
  (.data.steps | length) == 4 and
  (.data.steps[1] | contains("add or update one focused failing or currently missing regression test")) and
  .data.steps[3] == "Run `bash tests/queue-hot-reload-drain.sh` and confirm the exact pass/fail outcome."
' "$OUTPUT_FILE" >/dev/null

echo "planner prompt context injection test passed"
