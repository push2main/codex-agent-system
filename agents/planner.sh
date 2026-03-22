#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap planner

PROJECT_DIR="${1:-}"
TASK="${2:-}"
OUTPUT_FILE="${3:-$LOG_DIR/planner-latest.json}"
MEMORY_FILE="${4:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ]; then
  require_command planner jq
  jq -cn \
    --arg status "fail" \
    --arg message "usage: planner.sh <project_dir> <task> [output_file] [memory_file]" \
    '{status:$status,message:$message,data:{}}'
  exit 2
fi

require_command planner jq
ensure_runtime_dirs
mkdir -p "$PROJECT_DIR" "$(dirname "$OUTPUT_FILE")"

MEMORY_CONTEXT=""
if [ -n "$MEMORY_FILE" ] && [ -f "$MEMORY_FILE" ]; then
  MEMORY_CONTEXT="$(safe_read_file "$MEMORY_FILE")"
else
  MEMORY_CONTEXT="$(read_memory_context)"
fi

RULES_TEXT="$(safe_tail 50 "$RULES_FILE")"
PROJECT_HINT="$(relative_path "$PROJECT_DIR" "$ROOT_DIR")"
SOURCE_CONTEXT="$(build_prompt_source_context "$TASK" "")"
PROMPT="$(cat <<EOF
You are the planner agent in an autonomous local coding system on macOS.

Role:
- Break the task into the smallest safe execution steps.
- Prefer deterministic and debuggable work.
- Keep the plan between 2 and 6 steps.
- Every step must be actionable by a coder agent.

Task:
$TASK

Project directory:
$PROJECT_HINT

Relevant memory:
$MEMORY_CONTEXT

Validated rules:
$RULES_TEXT

Relevant source context:
$SOURCE_CONTEXT

Return JSON only with this exact shape:
{
  "status": "success",
  "message": "short summary",
  "data": {
    "steps": ["step 1", "step 2"]
  }
}
EOF
)"

fallback_planner() {
  local data_json
  data_json="$(jq -cn --arg task "$TASK" '{
    steps: [
      "Inspect the current project files and choose the smallest safe implementation for: " + $task,
      "Implement the requested change with minimal modifications.",
      "Run a lightweight verification relevant to the task and confirm the outcome."
    ]
  }')"
  write_json_file "$OUTPUT_FILE" "success" "Created deterministic fallback plan." "$data_json"
}

if ! run_codex_exec planner "$PROJECT_DIR" "$PROMPT" "$OUTPUT_FILE"; then
  fallback_planner
elif ! validate_agent_json "$OUTPUT_FILE"; then
  log_msg WARN planner "Planner output was not valid JSON; using fallback plan"
  fallback_planner
elif ! jq -e '
  .status == "success" and
  (.data.steps | type == "array") and
  ((.data.steps | length) >= 2) and
  ((.data.steps | length) <= 6) and
  all(.data.steps[]; type == "string" and (gsub("\\s+"; " ") | length > 0))
' "$OUTPUT_FILE" >/dev/null 2>&1; then
  log_msg WARN planner "Planner output did not satisfy the deterministic schema; using fallback plan"
  fallback_planner
fi

log_msg INFO planner "Plan saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
