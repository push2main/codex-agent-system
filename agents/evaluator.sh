#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

PROJECT_DIR="${1:-}"
TASK="${2:-}"
PLAN_FILE="${3:-}"
REVIEW_FILE="${4:-}"
OUTPUT_FILE="${5:-$LOG_DIR/evaluator-latest.txt}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ] || [ -z "$PLAN_FILE" ] || [ -z "$REVIEW_FILE" ]; then
  echo "usage: evaluator.sh <project_dir> <task> <plan_file> <review_file> [output_file]" >&2
  exit 2
fi

ensure_runtime_dirs
PLAN_TEXT="$(cat "$PLAN_FILE" 2>/dev/null || true)"
REVIEW_TEXT="$(cat "$REVIEW_FILE" 2>/dev/null || true)"
PROMPT="$(cat <<EOF
You are the evaluator agent.

Role:
- Score the result from 0 to 10.
- Mark the result GOOD or BAD.
- Keep the response machine-readable.

Task:
$TASK

Plan:
$PLAN_TEXT

Review result:
$REVIEW_TEXT

Return exactly:
SCORE: <integer 0-10>
VERDICT: GOOD or BAD
REASON: <one short sentence>
EOF
)"

fallback_evaluator() {
  if grep -q '^APPROVED' "$REVIEW_FILE"; then
    cat >"$OUTPUT_FILE" <<'EOF'
SCORE: 8
VERDICT: GOOD
REASON: Review approved the implementation and no blocking issues remain.
EOF
    return
  fi

  cat >"$OUTPUT_FILE" <<'EOF'
SCORE: 3
VERDICT: BAD
REASON: Review did not approve the implementation.
EOF
}

if ! run_codex_exec evaluator "$PROJECT_DIR" "$PROMPT" "$OUTPUT_FILE"; then
  fallback_evaluator
elif ! grep -q '^SCORE:' "$OUTPUT_FILE" || ! grep -q '^VERDICT: \(GOOD\|BAD\)$' "$OUTPUT_FILE"; then
  log_msg WARN evaluator "codex evaluator output was not machine-readable; using fallback evaluation"
  fallback_evaluator
fi

log_msg INFO evaluator "Evaluation saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
cat "$OUTPUT_FILE"
