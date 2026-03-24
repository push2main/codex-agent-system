#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/codex-agent-system"

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

cat >"$TEST_ROOT/agents/planner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

[ "${TASK_ID:-}" = "task-orchestrator-context" ] || {
  jq -cn --arg status "fail" --arg message "TASK_ID was not exported to planner" '{status:$status,message:$message,data:{}}'
  exit 1
}

OUTPUT_FILE="${3:-}"
jq -cn \
  --arg status "success" \
  --arg message "ok" \
  '{status:$status,message:$message,data:{steps:["Inspect the current project files and choose the smallest safe implementation."]}}' >"$OUTPUT_FILE"
cat "$OUTPUT_FILE"
EOF

cat >"$TEST_ROOT/agents/coder.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

OUTPUT_FILE="${7:-}"
jq -cn \
  --arg status "success" \
  --arg message "ok" \
  '{status:$status,message:$message,data:{step:"Inspect the current project files and choose the smallest safe implementation.",index:1,kind:"inspect",summary:"stub",files:[],checks:[],changed:false}}' >"$OUTPUT_FILE"
cat "$OUTPUT_FILE"
EOF

cat >"$TEST_ROOT/agents/reviewer.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

OUTPUT_FILE="${6:-}"
jq -cn \
  --arg status "approved" \
  --arg message "ok" \
  '{status:$status,message:$message,data:{step:"Inspect the current project files and choose the smallest safe implementation.",findings:[]}}' >"$OUTPUT_FILE"
cat "$OUTPUT_FILE"
EOF

cat >"$TEST_ROOT/agents/evaluator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

OUTPUT_FILE="${6:-}"
jq -cn \
  --arg status "success" \
  --arg message "ok" \
  '{status:$status,message:$message,data:{score:8,reason:"stub"}}' >"$OUTPUT_FILE"
cat "$OUTPUT_FILE"
EOF

cat >"$TEST_ROOT/agents/learner.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -cn '{status:"success",message:"stub",data:{}}'
EOF

cat >"$TEST_ROOT/agents/safety.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
jq -cn '{status:"success",message:"stub",data:{}}'
EOF

chmod +x "$TEST_ROOT/agents/"*.sh

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-orchestrator-context",
      "title": "Verify orchestrator task context export",
      "project": "codex-agent-system",
      "status": "approved"
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-learning/prompt-rules.md"
: >"$TEST_ROOT/codex-learning/rules.md"
: >"$TEST_ROOT/codex-memory/decisions.md"
: >"$TEST_ROOT/codex-memory/context.md"
: >"$TEST_ROOT/projects/codex-agent-system/memory.md"

(
  cd "$TEST_ROOT"
  NOTIFY_DISABLE=1 \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  TASK_LOG="$TEST_ROOT/codex-memory/tasks.log" \
  RULES_FILE="$TEST_ROOT/codex-learning/rules.md" \
  PROMPT_RULES_FILE="$TEST_ROOT/codex-learning/prompt-rules.md" \
  DECISIONS_FILE="$TEST_ROOT/codex-memory/decisions.md" \
  CONTEXT_FILE="$TEST_ROOT/codex-memory/context.md" \
  bash "$TEST_ROOT/agents/orchestrator.sh" \
    "$PROJECT_DIR" \
    "Verify orchestrator task context export" \
    "task-orchestrator-context" >/dev/null
)

echo "orchestrator task id context test passed"
