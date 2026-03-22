#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap learner

PROJECT_DIR="${1:-$ROOT_DIR}"
TASK="${2:-}"
RESULT="${3:-UNKNOWN}"
RUN_DIR="${4:-$RUNS_DIR}"
RULES_OUTPUT_FILE="${5:-$PROMPT_RULES_FILE}"
OUTPUT_FILE="${6:-$LOG_DIR/learner-latest.json}"
RAW_RULES_FILE="$RUN_DIR/learner-rules.txt"

ensure_runtime_dirs
mkdir -p "$RUN_DIR" "$(dirname "$RULES_OUTPUT_FILE")" "$(dirname "$OUTPUT_FILE")"

RECENT_TASKS="$(tail -n 20 "$TASK_LOG" 2>/dev/null || true)"
RECENT_LOGS="$(tail -n 80 "$SYSTEM_LOG" 2>/dev/null || true)"
CURRENT_RULES="$(tail -n 50 "$RULES_FILE" 2>/dev/null || true)"

PROMPT="$(cat <<EOF
You are the learner agent.

Role:
- Analyze recent successes and failures.
- Generate at most 5 simple prompt rules.
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
  cat >"$RAW_RULES_FILE" <<EOF
- Keep prompt changes minimal and tied to repeated evidence.
- Prefer prompt rules that improve determinism and verification.
- Avoid task-specific prompt tweaks unless the same failure repeats.
- Capture outcomes in a way that future runs can reuse safely.
EOF

  if [ "$RESULT" != "SUCCESS" ]; then
    printf '%s\n' '- When retries are exhausted, narrow the next prompt instead of adding scope.' >>"$RAW_RULES_FILE"
  fi
}

if ! run_codex_exec learner "$PROJECT_DIR" "$PROMPT" "$RAW_RULES_FILE"; then
  fallback_learner
elif ! grep -q '^- ' "$RAW_RULES_FILE"; then
  log_msg WARN learner "codex learner output had no bullet rules; using fallback rules"
  fallback_learner
fi

RULES_JSON="$(extract_bullet_rules_json "$RAW_RULES_FILE" 5)"
if [ "$(jq 'length' <<<"$RULES_JSON")" -eq 0 ]; then
  fallback_learner
  RULES_JSON="$(extract_bullet_rules_json "$RAW_RULES_FILE" 5)"
fi

write_rules_markdown_file "# Prompt Rules" "$RULES_OUTPUT_FILE" "$RULES_JSON"
DATA_JSON="$(jq -cn \
  --arg result "$RESULT" \
  --arg output_file "$(relative_path "$RULES_OUTPUT_FILE" "$ROOT_DIR")" \
  --argjson rules "$RULES_JSON" \
  '{result:$result,rules:$rules,output_file:$output_file}')"
write_json_file "$OUTPUT_FILE" "success" "Prompt improvements captured." "$DATA_JSON"

log_msg INFO learner "Prompt rules saved to $(relative_path "$RULES_OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
