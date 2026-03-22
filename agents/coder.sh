#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

PROJECT_DIR="${1:-}"
TASK="${2:-}"
PLAN_FILE="${3:-}"
MEMORY_FILE="${4:-}"
FEEDBACK_FILE="${5:-}"
OUTPUT_FILE="${6:-$LOG_DIR/coder-latest.txt}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ] || [ -z "$PLAN_FILE" ]; then
  echo "usage: coder.sh <project_dir> <task> <plan_file> [memory_file] [feedback_file] [output_file]" >&2
  exit 2
fi

ensure_runtime_dirs
mkdir -p "$PROJECT_DIR" "$(dirname "$OUTPUT_FILE")"

PLAN_TEXT="$(cat "$PLAN_FILE" 2>/dev/null || true)"
MEMORY_TEXT=""
if [ -n "$MEMORY_FILE" ] && [ -f "$MEMORY_FILE" ]; then
  MEMORY_TEXT="$(cat "$MEMORY_FILE")"
fi

FEEDBACK_TEXT="None"
if [ -n "$FEEDBACK_FILE" ] && [ -f "$FEEDBACK_FILE" ]; then
  FEEDBACK_TEXT="$(cat "$FEEDBACK_FILE")"
fi

EXISTING_FILES="$(find "$PROJECT_DIR" -maxdepth 2 -type f | sed "s|$ROOT_DIR/||" | sort | head -n 50)"
PROMPT="$(cat <<EOF
You are the coder agent in an autonomous local coding system.

Role:
- Implement the smallest working solution.
- Modify files directly inside the project directory.
- Keep the change set minimal and robust.
- Run lightweight checks when useful.

Task:
$TASK

Project directory:
$(relative_path "$PROJECT_DIR" "$ROOT_DIR")

Plan:
$PLAN_TEXT

Relevant memory:
$MEMORY_TEXT

Reviewer and evaluator feedback from prior attempts:
$FEEDBACK_TEXT

Current files:
$EXISTING_FILES

After editing the code, return a short summary using this format:
Summary: ...
Files:
- path
Checks:
- command or note
EOF
)"

fallback_coder() {
  local task_lower
  task_lower="$(printf '%s' "$TASK" | tr '[:upper:]' '[:lower:]')"
  local target_file
  local check_note

  if [[ "$task_lower" == *"python"* ]]; then
    target_file="$PROJECT_DIR/hello.py"
    cat >"$target_file" <<'EOF'
print("Hello, World!")
EOF
    check_note='python3 hello.py'
  elif [[ "$task_lower" == *"javascript"* ]] || [[ "$task_lower" == *"node"* ]]; then
    target_file="$PROJECT_DIR/hello.js"
    cat >"$target_file" <<'EOF'
console.log("Hello, World!");
EOF
    check_note='node hello.js'
  elif [[ "$task_lower" == *"shell"* ]] || [[ "$task_lower" == *"bash"* ]] || [[ "$task_lower" == *"hello world"* ]]; then
    target_file="$PROJECT_DIR/hello.sh"
    cat >"$target_file" <<'EOF'
#!/usr/bin/env bash
echo "Hello, World!"
EOF
    chmod +x "$target_file"
    check_note='./hello.sh'
  else
    target_file="$PROJECT_DIR/TASK_RESPONSE.md"
    cat >"$target_file" <<EOF
# Task Response

Codex CLI was unavailable, so a minimal placeholder file was created for the requested task:

$TASK
EOF
    check_note='Fallback placeholder created'
  fi

  cat >"$OUTPUT_FILE" <<EOF
Summary: Created a minimal fallback implementation for the task.
Files:
- $(relative_path "$target_file" "$ROOT_DIR")
Checks:
- $check_note
EOF
}

project_fingerprint() {
  python3 - "$PROJECT_DIR" <<'PY'
from __future__ import annotations

import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
if not root.exists():
    print("MISSING")
    raise SystemExit(0)

records: list[str] = []
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    records.append(f"{path.relative_to(root)}:{digest}")

print("\n".join(records) if records else "EMPTY")
PY
}

before_fingerprint="$(project_fingerprint)"
if ! run_codex_exec coder "$PROJECT_DIR" "$PROMPT" "$OUTPUT_FILE"; then
  fallback_coder
else
  after_fingerprint="$(project_fingerprint)"
  if [ "$before_fingerprint" = "$after_fingerprint" ]; then
    log_msg WARN coder "codex exec produced no project file changes; using fallback implementation"
    fallback_coder
  fi
fi

if ! grep -q '^Summary:' "$OUTPUT_FILE"; then
  fallback_coder
fi

log_msg INFO coder "Implementation summary saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
cat "$OUTPUT_FILE"
