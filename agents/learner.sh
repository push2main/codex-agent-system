#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

PROJECT_DIR="${1:-$ROOT_DIR}"
TASK="${2:-}"
RESULT="${3:-UNKNOWN}"
RUN_DIR="${4:-$RUNS_DIR}"
OUTPUT_FILE="${5:-$RULES_CANDIDATE_FILE}"

ensure_runtime_dirs

RECENT_TASKS="$(tail -n 20 "$TASK_LOG" 2>/dev/null || true)"
RECENT_LOGS="$(tail -n 80 "$SYSTEM_LOG" 2>/dev/null || true)"
CURRENT_RULES="$(tail -n 50 "$RULES_FILE" 2>/dev/null || true)"

PROMPT="$(cat <<EOF
You are the learner agent.

Role:
- Analyze recent successes and failures.
- Generate at most 5 simple rules.
- Avoid complexity and overfitting.
- Return only bullet points beginning with "- ".

Latest task:
$TASK

Latest result:
$RESULT

Recent task history:
$RECENT_TASKS

Recent system logs:
$RECENT_LOGS

Current rules:
$CURRENT_RULES
EOF
)"

fallback_learner() {
  cat >"$OUTPUT_FILE" <<EOF
# Candidate Rules

- Keep task changes minimal and easy to verify.
- Run a quick local check before marking work complete.
- Retry only when review or evaluation identifies a fixable issue.
- Record task outcomes so future runs can reuse context.
EOF

  if [ "$RESULT" != "SUCCESS" ]; then
    printf '%s\n' '- When a task fails twice, simplify the implementation scope.' >>"$OUTPUT_FILE"
  fi
}

if ! run_codex_exec learner "$PROJECT_DIR" "$PROMPT" "$OUTPUT_FILE"; then
  fallback_learner
elif ! grep -q '^- ' "$OUTPUT_FILE"; then
  log_msg WARN learner "codex learner output had no bullet rules; using fallback rules"
  fallback_learner
fi

log_msg INFO learner "Candidate rules saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
cat "$OUTPUT_FILE"
