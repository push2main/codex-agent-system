#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap evaluator

PROJECT_DIR="${1:-}"
TASK="${2:-}"
STEP_FILE="${3:-}"
PLAN_FILE="${4:-}"
REVIEW_FILE="${5:-}"
OUTPUT_FILE="${6:-$LOG_DIR/evaluator-latest.json}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ] || [ -z "$STEP_FILE" ] || [ -z "$PLAN_FILE" ] || [ -z "$REVIEW_FILE" ]; then
  require_command evaluator jq
  jq -cn \
    --arg status "fail" \
    --arg message "usage: evaluator.sh <project_dir> <task> <step_file> <plan_file> <review_file> [output_file]" \
    '{status:$status,message:$message,data:{}}'
  exit 2
fi

require_command evaluator jq
ensure_runtime_dirs
mkdir -p "$(dirname "$OUTPUT_FILE")"

STEP_TEXT="$(json_get "$STEP_FILE" '.text')"
STEP_INDEX="$(json_get "$STEP_FILE" '.index')"
PLAN_JSON="$(safe_read_file "$PLAN_FILE")"
REVIEW_JSON="$(safe_read_file "$REVIEW_FILE")"

step_kind() {
  local step_lower
  step_lower="$(printf '%s' "$STEP_TEXT" | tr '[:upper:]' '[:lower:]')"
  if [[ "$step_lower" == *"verify"* ]] || [[ "$step_lower" == *"test"* ]] || [[ "$step_lower" == *"run "* ]] || [[ "$step_lower" == *"check"* ]] || [[ "$step_lower" == *"confirm"* ]]; then
    printf 'verify\n'
    return 0
  fi
  if [[ "$step_lower" == *"inspect"* ]] || [[ "$step_lower" == *"review"* ]] || [[ "$step_lower" == *"analy"* ]] || [[ "$step_lower" == *"understand"* ]] || [[ "$step_lower" == *"choose"* ]]; then
    printf 'inspect\n'
    return 0
  fi
  printf 'implement\n'
}

STEP_KIND="$(step_kind)"

build_payload() {
  local status="$1"
  local message="$2"
  local score="${3:-0}"
  local reason="$4"
  local step_override="${5:-$STEP_TEXT}"
  local data_json
  data_json="$(jq -cn \
    --arg step "$step_override" \
    --argjson index "$STEP_INDEX" \
    --arg kind "$STEP_KIND" \
    --argjson score "$score" \
    --arg reason "$reason" \
    '{step:$step,index:$index,kind:$kind,score:$score,reason:$reason}')"
  write_json_file "$OUTPUT_FILE" "$status" "$message" "$data_json"
}

is_generic_implementation_step_value() {
  local normalized_step
  normalized_step="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  [ "$normalized_step" = "implement the requested change with minimal modifications." ] || \
    [ "$normalized_step" = "implement the requested change with minimal modifications" ]
}

review_retry_guidance() {
  local retry_step retry_command
  if ! validate_agent_json "$REVIEW_FILE"; then
    printf '\n'
    return 0
  fi

  retry_step="$(jq -r 'if .status != "approved" and (.data | type == "object") then (.data.step // "") else "" end' "$REVIEW_FILE" 2>/dev/null || true)"
  retry_step="$(printf '%s' "$retry_step" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  if [ -z "$retry_step" ] || is_generic_implementation_step_value "$retry_step"; then
    printf '\n'
    return 0
  fi

  retry_command="$(
    jq -r '
      first(
        (.data.findings // [])[]?
        | select(type == "string" and startswith("Use the preferred verification command: "))
        | sub("^Use the preferred verification command: "; "")
      ) // ""
    ' "$REVIEW_FILE" 2>/dev/null || true
  )"
  retry_command="$(printf '%s' "$retry_command" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"

  jq -cn --arg step "$retry_step" --arg command "$retry_command" '{step:$step,verification_command:$command}'
}

fallback_evaluator() {
  local retry_guidance retry_step retry_command
  if ! validate_agent_json "$REVIEW_FILE"; then
    build_payload "fail" "Reviewer output was invalid." 1 "Review JSON could not be parsed."
    return 0
  fi

  if jq -e '.status == "approved"' "$REVIEW_FILE" >/dev/null 2>&1; then
    build_payload "success" "Step evaluation passed." 8 "Review approved the step and no blocking issue remains."
    return 0
  fi

  retry_guidance="$(review_retry_guidance)"
  retry_step="$(printf '%s' "$retry_guidance" | jq -r '.step // ""' 2>/dev/null || true)"
  retry_command="$(printf '%s' "$retry_guidance" | jq -r '.verification_command // ""' 2>/dev/null || true)"
  if [ -n "$retry_step" ]; then
    if [ -n "$retry_command" ]; then
      build_payload \
        "fail" \
        "Step evaluation failed." \
        3 \
        "Review requested another attempt for the bounded step: $retry_step Use the preferred verification command: $retry_command" \
        "$retry_step"
    else
      build_payload \
        "fail" \
        "Step evaluation failed." \
        3 \
        "Review requested another attempt for the bounded step: $retry_step" \
        "$retry_step"
    fi
    return 0
  fi

  build_payload "fail" "Step evaluation failed." 3 "Review requested another attempt for this step."
}

provider_unavailable_evaluator() {
  local provider reason
  provider="$(current_exec_provider)"
  reason="$(provider_exec_failure_reason)"
  build_payload "fail" "Selected provider is unavailable for evaluator execution." 1 "Selected provider ${provider:-unknown} is unavailable: ${reason:-unknown reason}."
}

PROMPT="$(cat <<EOF
You are the evaluator agent.

Role:
- Evaluate one plan step after review.
- Return JSON only.
- Use status "success" when the step is acceptable, otherwise use "fail".

Task:
$TASK

Active step index:
$STEP_INDEX

Active step:
$STEP_TEXT

Project directory:
$(relative_path "$PROJECT_DIR" "$ROOT_DIR")

Plan JSON:
$PLAN_JSON

Review JSON:
$REVIEW_JSON

Return JSON only with this exact shape:
{
  "status": "success" or "fail",
  "message": "short summary",
  "data": {
    "step": "$STEP_TEXT",
    "index": $STEP_INDEX,
    "kind": "$STEP_KIND",
    "score": 0,
    "reason": "short reason"
  }
}
EOF
)"

if ! run_agent_exec evaluator "$PROJECT_DIR" "$TASK" "$PROMPT" "$OUTPUT_FILE"; then
  if provider_exec_requires_abort; then
    log_msg WARN evaluator "Selected provider $(current_exec_provider) is unavailable: $(provider_exec_failure_reason)"
    provider_unavailable_evaluator
  else
    fallback_evaluator
  fi
elif ! validate_agent_json "$OUTPUT_FILE"; then
  log_msg WARN evaluator "Evaluator output was not valid JSON; using fallback evaluation"
  fallback_evaluator
elif ! jq -e '
  (.status == "success" or .status == "fail") and
  (.data | type == "object") and
  (.data.score | type == "number") and
  (.data.reason | type == "string")
' "$OUTPUT_FILE" >/dev/null 2>&1; then
  log_msg WARN evaluator "Evaluator output did not satisfy the deterministic schema; using fallback evaluation"
  fallback_evaluator
fi

log_msg INFO evaluator "Evaluation saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
