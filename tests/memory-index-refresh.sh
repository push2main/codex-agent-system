#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$TEST_ROOT/scripts" \
  "$TEST_ROOT/codex-memory/topics" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/projects"

cp -R "$ROOT_DIR/scripts/." "$TEST_ROOT/scripts/"

cat >"$TEST_ROOT/codex-memory/index.md" <<'EOF'
# Codex Agent System — Memory Index
# This file is always loaded into agent context (max 200 lines).
# Detailed learnings are stored in codex-memory/topics/<category>.md

## Core Architecture Rules
- All agents must return valid JSON with status, message, data fields
- Maximum 6 steps per plan, last step must be verification

## Known Failure Patterns
- Timeout failures often caused by oversized context or missing dependencies

## Operational Rules
- Shell scripts must pass bash -n before deployment
- [code_quality] Task failed [timeout]: Reduce timeout rate — Planner timed out after 60s before step execution began
- Add unit test: verify clamp_prompt_context respects 4000-char limit — Step 1: Create file tests/clamp-prompt-context-limit.sh
EOF

cat >"$TEST_ROOT/codex-learning/rules.md" <<'EOF'
# Learned Rules

- Require every generated task to name at least one existing file path and one concrete function, branch, or section anchor.
- Reject or rewrite tasks that span multiple files or multiple objectives into a single-file, single-outcome task before execution.
EOF

(
  cd "$TEST_ROOT"
  bash -lc '
    source scripts/lib.sh
    categorize_and_store_learning \
      "[code_quality] Task failed [timeout]: Reduce timeout rate — Planner timed out after 60s before step execution began" \
      "code_quality"
  '
)

grep -q '^## Learned Rules$' "$TEST_ROOT/codex-memory/index.md"
grep -q -- '- All agents must return valid JSON with status, message, data fields' "$TEST_ROOT/codex-memory/index.md"
grep -q -- '- Shell scripts must pass bash -n before deployment' "$TEST_ROOT/codex-memory/index.md"
grep -q -- '- Require every generated task to name at least one existing file path and one concrete function, branch, or section anchor.' "$TEST_ROOT/codex-memory/index.md"
! grep -q 'Task failed' "$TEST_ROOT/codex-memory/index.md"
! grep -q 'Step 1:' "$TEST_ROOT/codex-memory/index.md"

grep -q 'Task failed' "$TEST_ROOT/codex-memory/topics/code_quality.md"

echo "memory index refresh test passed"
