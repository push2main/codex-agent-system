#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

INPUT_FILE="${1:-$RULES_CANDIDATE_FILE}"
OUTPUT_FILE="${2:-$RULES_FILE}"

ensure_runtime_dirs
mkdir -p "$(dirname "$OUTPUT_FILE")"

INPUT_TEXT="$(cat "$INPUT_FILE" 2>/dev/null || true)"
PROMPT="$(cat <<EOF
You are the safety agent.

Role:
- Validate candidate rules.
- Reject overfitted, highly specific, or complex rules.
- Return at most 5 concise bullet rules.
- Return only bullet lines that start with "- ".

Candidate rules:
$INPUT_TEXT
EOF
)"

fallback_safety() {
  {
    printf '# Learned Rules\n\n'
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
    ' "$INPUT_FILE"
  } >"$OUTPUT_FILE"

  if ! grep -q '^- ' "$OUTPUT_FILE"; then
    cat >"$OUTPUT_FILE" <<'EOF'
# Learned Rules

- Keep changes minimal and easy to verify.
- Prefer deterministic local checks over assumptions.
EOF
  fi
}

if ! run_codex_exec safety "$ROOT_DIR" "$PROMPT" "$OUTPUT_FILE"; then
  fallback_safety
fi

if ! grep -q '^- ' "$OUTPUT_FILE"; then
  fallback_safety
fi

log_msg INFO safety "Validated rules saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
cat "$OUTPUT_FILE"
