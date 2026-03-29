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
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/queues"

cp -R "$ROOT_DIR/scripts/." "$TEST_ROOT/scripts/"

cat >"$TEST_ROOT/AGENTS.md" <<'EOF'
# Agent Rules

## Goal
Build a stable, self-improving, production-ready AI system.

## Auto-Synced Learnings

<!-- stale content -->

- stale line

## End Auto-Synced
EOF

cat >"$TEST_ROOT/codex-memory/index.md" <<'EOF'
# Codex Agent System — Memory Index

## Core Architecture Rules
- All agents must return valid JSON with status, message, data fields
- Maximum 6 steps per plan, last step must be verification

## Operational Rules
- Shell scripts must pass bash -n before deployment
- [code_quality] Task failed [timeout]: Reduce timeout rate — Planner timed out after 60s before step execution began
- Add test: verify planner output steps are each under 600 characters — Step 1: Create file `tests/planner-step-length-limit.sh`
EOF

cat >"$TEST_ROOT/codex-learning/rules.md" <<'EOF'
# Learned Rules

- Require every generated task to name at least one existing file path and one concrete function, branch, or section anchor.
- Reject or rewrite tasks that span multiple files or multiple objectives into a single-file, single-outcome task before execution.
EOF

(
  cd "$TEST_ROOT"
  bash scripts/memory-sync.sh export >/dev/null
)

grep -q '^## Stable Operating Rules$' "$TEST_ROOT/AGENTS.md"
grep -q -- '- All agents must return valid JSON with status, message, data fields' "$TEST_ROOT/AGENTS.md"
grep -q -- '- Shell scripts must pass bash -n before deployment' "$TEST_ROOT/AGENTS.md"
grep -q '^## Current Learned Rules$' "$TEST_ROOT/AGENTS.md"
grep -q '^## Detailed Memory$' "$TEST_ROOT/AGENTS.md"
! grep -q 'Task failed' "$TEST_ROOT/AGENTS.md"
! grep -q 'Step 1:' "$TEST_ROOT/AGENTS.md"

echo "memory sync agents compact test passed"
