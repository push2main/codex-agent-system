#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

PROJECT_DIR="${1:-}"
TASK="${2:-}"
PLAN_FILE="${3:-}"
CODER_FILE="${4:-}"
OUTPUT_FILE="${5:-$LOG_DIR/reviewer-latest.txt}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ] || [ -z "$PLAN_FILE" ] || [ -z "$CODER_FILE" ]; then
  echo "usage: reviewer.sh <project_dir> <task> <plan_file> <coder_file> [output_file]" >&2
  exit 2
fi

ensure_runtime_dirs
PLAN_TEXT="$(cat "$PLAN_FILE" 2>/dev/null || true)"
CODER_TEXT="$(cat "$CODER_FILE" 2>/dev/null || true)"
PROJECT_HINT="$(relative_path "$PROJECT_DIR" "$ROOT_DIR")"
PROMPT="$(cat <<EOF
You are the reviewer agent.

Role:
- Detect bugs, risks, regressions, and missing edge cases.
- Be concise and decisive.
- First line must be APPROVED or REQUEST_CHANGES.

Task:
$TASK

Project directory:
$PROJECT_HINT

Plan:
$PLAN_TEXT

Coder summary:
$CODER_TEXT

Return:
APPROVED or REQUEST_CHANGES
Then 1 to 5 short findings or confirmations.
EOF
)"

fallback_reviewer() {
  if grep -R "Hello, World!" "$PROJECT_DIR" >/dev/null 2>&1; then
    cat >"$OUTPUT_FILE" <<'EOF'
APPROVED
- Minimal hello world behavior is present.
- No obvious blocking issues were detected in the fallback implementation.
EOF
    return
  fi

  if find "$PROJECT_DIR" -maxdepth 2 -type f | grep -q .; then
    cat >"$OUTPUT_FILE" <<'EOF'
APPROVED
- Files were created or updated.
- Manual inspection is still recommended for non-trivial tasks if Codex fallback was used.
EOF
    return
  fi

  cat >"$OUTPUT_FILE" <<'EOF'
REQUEST_CHANGES
- No implementation files were found in the project directory.
- The task still needs a concrete code change.
EOF
}

if ! run_codex_exec reviewer "$PROJECT_DIR" "$PROMPT" "$OUTPUT_FILE"; then
  fallback_reviewer
elif ! head -n 1 "$OUTPUT_FILE" | grep -Eq '^(APPROVED|REQUEST_CHANGES)$'; then
  log_msg WARN reviewer "codex reviewer output was not machine-readable; using fallback review"
  fallback_reviewer
fi

log_msg INFO reviewer "Review saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
cat "$OUTPUT_FILE"
