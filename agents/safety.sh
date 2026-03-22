#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap safety

INPUT_FILE="${1:-$PROMPT_RULES_FILE}"
OUTPUT_FILE="${2:-$RULES_FILE}"
JSON_OUTPUT_FILE="${3:-$LOG_DIR/safety-latest.json}"
RAW_RULES_FILE="$(mktemp)"
trap 'rm -f "$RAW_RULES_FILE"' EXIT

ensure_runtime_dirs
mkdir -p "$(dirname "$OUTPUT_FILE")" "$(dirname "$JSON_OUTPUT_FILE")"

INPUT_TEXT="$(cat "$INPUT_FILE" 2>/dev/null || true)"
PROMPT="$(cat <<EOF
You are the safety agent.

Role:
- Validate candidate prompt rules.
- Reject overfitted, highly specific, or complex rules.
- Return at most 5 concise bullet rules.
- Return only bullet lines that start with "- ".

Candidate rules:
$INPUT_TEXT
EOF
)"

fallback_safety() {
  awk '
    BEGIN { count=0 }
    /^- / {
      rule=$0
      gsub(/[[:space:]]+$/, "", rule)
      if (length(rule) > 120) next
      if (rule ~ /\//) next
      if (rule ~ /[0-9]{5,}/) next
      if (!seen[rule]++) {
        print rule
        count += 1
      }
      if (count >= 5) exit
    }
  ' "$INPUT_FILE" >"$RAW_RULES_FILE"

  if ! grep -q '^- ' "$RAW_RULES_FILE"; then
    cat >"$RAW_RULES_FILE" <<'EOF'
- Keep changes minimal and easy to verify.
- Prefer deterministic local checks over assumptions.
EOF
  fi
}

if ! run_codex_exec safety "$ROOT_DIR" "$PROMPT" "$RAW_RULES_FILE"; then
  fallback_safety
elif ! grep -q '^- ' "$RAW_RULES_FILE"; then
  fallback_safety
fi

RULES_JSON="$(extract_bullet_rules_json "$RAW_RULES_FILE" 5)"
if [ "$(jq 'length' <<<"$RULES_JSON")" -eq 0 ]; then
  fallback_safety
  RULES_JSON="$(extract_bullet_rules_json "$RAW_RULES_FILE" 5)"
fi

write_rules_markdown_file "# Learned Rules" "$OUTPUT_FILE" "$RULES_JSON"
DATA_JSON="$(jq -cn \
  --arg input_file "$(relative_path "$INPUT_FILE" "$ROOT_DIR")" \
  --arg output_file "$(relative_path "$OUTPUT_FILE" "$ROOT_DIR")" \
  --argjson rules "$RULES_JSON" \
  '{input_file:$input_file,output_file:$output_file,rules:$rules}')"
write_json_file "$JSON_OUTPUT_FILE" "success" "Validated prompt rules." "$DATA_JSON"

log_msg INFO safety "Validated rules saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$JSON_OUTPUT_FILE"
