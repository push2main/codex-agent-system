#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

PROJECT_DIR="${1:-}"
TASK="${2:-}"
OUTPUT_FILE="${3:-$LOG_DIR/planner-latest.txt}"
MEMORY_FILE="${4:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ]; then
  echo "usage: planner.sh <project_dir> <task> [output_file] [memory_file]" >&2
  exit 2
fi

ensure_runtime_dirs
mkdir -p "$PROJECT_DIR" "$(dirname "$OUTPUT_FILE")"

MEMORY_CONTEXT=""
if [ -n "$MEMORY_FILE" ] && [ -f "$MEMORY_FILE" ]; then
  MEMORY_CONTEXT="$(cat "$MEMORY_FILE")"
fi

RULES_TEXT="$(tail -n 50 "$RULES_FILE" 2>/dev/null || true)"
PROJECT_HINT="$(relative_path "$PROJECT_DIR" "$ROOT_DIR")"
PROMPT="$(cat <<EOF
You are the planner agent in an autonomous local coding system on macOS.

Role:
- Break the task into the smallest safe steps.
- Prefer minimal working changes.
- Consider local verification and git hygiene.

Task:
$TASK

Project directory:
$PROJECT_HINT

Relevant memory:
$MEMORY_CONTEXT

Validated rules:
$RULES_TEXT

Return only a concise numbered plan with 3 to 6 steps.
EOF
)"

if ! run_codex_exec planner "$PROJECT_DIR" "$PROMPT" "$OUTPUT_FILE"; then
  cat >"$OUTPUT_FILE" <<EOF
1. Inspect the current project files in $PROJECT_HINT and identify the smallest required change.
2. Implement the minimal working solution for: $TASK
3. Run a lightweight local verification relevant to the changed files.
4. Review for obvious bugs, edge cases, and incomplete work before finishing.
EOF
fi

log_msg INFO planner "Plan saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
cat "$OUTPUT_FILE"
