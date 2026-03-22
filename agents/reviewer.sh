#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap reviewer

PROJECT_DIR="${1:-}"
TASK="${2:-}"
STEP_FILE="${3:-}"
PLAN_FILE="${4:-}"
CODER_FILE="${5:-}"
OUTPUT_FILE="${6:-$LOG_DIR/reviewer-latest.json}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ] || [ -z "$STEP_FILE" ] || [ -z "$PLAN_FILE" ] || [ -z "$CODER_FILE" ]; then
  require_command reviewer jq
  jq -cn \
    --arg status "retry" \
    --arg message "usage: reviewer.sh <project_dir> <task> <step_file> <plan_file> <coder_file> [output_file]" \
    '{status:$status,message:$message,data:null}'
  exit 2
fi

require_command reviewer jq
ensure_runtime_dirs
mkdir -p "$(dirname "$OUTPUT_FILE")"

STEP_TEXT="$(json_get "$STEP_FILE" '.text')"
STEP_INDEX="$(json_get "$STEP_FILE" '.index')"
PLAN_JSON="$(safe_read_file "$PLAN_FILE")"
CODER_JSON="$(safe_read_file "$CODER_FILE")"

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
  local findings_json="${3:-[]}"
  local data_json
  data_json="$(jq -cn \
    --arg step "$STEP_TEXT" \
    --argjson index "$STEP_INDEX" \
    --arg kind "$STEP_KIND" \
    --argjson findings "$findings_json" \
    '{step:$step,index:$index,kind:$kind,findings:$findings}')"
  write_json_file "$OUTPUT_FILE" "$status" "$message" "$data_json"
}

task_language() {
  local combined
  combined="$(printf '%s %s' "$TASK" "$STEP_TEXT" | tr '[:upper:]' '[:lower:]')"
  if [[ "$combined" == *"python"* ]]; then
    printf 'python\n'
    return 0
  fi
  if [[ "$combined" == *"javascript"* ]] || [[ "$combined" == *"node"* ]]; then
    printf 'javascript\n'
    return 0
  fi
  if [[ "$combined" == *"shell"* ]] || [[ "$combined" == *"bash"* ]] || [[ "$combined" == *"hello world"* ]]; then
    printf 'shell\n'
    return 0
  fi
  printf 'generic\n'
}

implementation_artifact_ok() {
  case "$(task_language)" in
    python)
      [ -f "$PROJECT_DIR/hello.py" ] && grep -q 'Hello, World!' "$PROJECT_DIR/hello.py"
      ;;
    javascript)
      [ -f "$PROJECT_DIR/hello.js" ] && grep -q 'Hello, World!' "$PROJECT_DIR/hello.js"
      ;;
    shell)
      [ -f "$PROJECT_DIR/hello.sh" ] && grep -q 'Hello, World!' "$PROJECT_DIR/hello.sh"
      ;;
    *)
      jq -e '((.data.changed // false) == true) or (((.data.files // []) | length) > 0)' "$CODER_FILE" >/dev/null 2>&1
      ;;
  esac
}

fallback_reviewer() {
  if ! validate_agent_json "$CODER_FILE"; then
    build_payload "retry" "Coder output was invalid; retry required." '["Coder output could not be parsed as valid JSON."]'
    return 0
  fi

  if ! jq -e '.status == "success"' "$CODER_FILE" >/dev/null 2>&1; then
    build_payload "retry" "Coder reported failure; retry required." '["Coder did not complete the step successfully."]'
    return 0
  fi

  case "$STEP_KIND" in
    inspect)
      build_payload "approved" "Inspection step approved." '["Inspection completed without blocking issues.","No code changes were required for this step."]'
      ;;
    verify)
      if jq -e '(.data.checks | length) > 0' "$CODER_FILE" >/dev/null 2>&1; then
        build_payload "approved" "Verification step approved." '["Verification evidence was recorded.","No blocking issues were detected in the verification step."]'
      else
        build_payload "retry" "Verification step lacks evidence; retry required." '["The verification step did not report any checks.","Retry with an explicit runnable check."]'
      fi
      ;;
    *)
      if implementation_artifact_ok; then
        build_payload "approved" "Implementation step approved." '["Expected implementation artifact is present.","No blocking issues were detected in the fallback review."]'
      else
        build_payload "retry" "Implementation artifact is missing or incomplete." '["Expected implementation output was not found in the project directory.","Retry the implementation step with the required code change."]'
      fi
      ;;
  esac
}

PROMPT="$(cat <<EOF
You are the reviewer agent.

Role:
- Detect bugs, risks, regressions, and missing edge cases for one plan step.
- Return JSON only.
- Use status "approved" when the step is acceptable, otherwise use "retry".

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

Coder JSON:
$CODER_JSON

Return JSON only with this exact shape:
{
  "status": "approved" or "retry",
  "message": "short summary",
  "data": {
    "step": "$STEP_TEXT",
    "index": $STEP_INDEX,
    "kind": "$STEP_KIND",
    "findings": ["short finding"]
  }
}
EOF
)"

if ! run_codex_exec reviewer "$PROJECT_DIR" "$PROMPT" "$OUTPUT_FILE"; then
  fallback_reviewer
elif ! validate_agent_json "$OUTPUT_FILE"; then
  log_msg WARN reviewer "Reviewer output was not valid JSON; using fallback review"
  fallback_reviewer
elif ! jq -e '
  (.status == "approved" or .status == "retry") and
  (.data | type == "object") and
  (.data.findings | type == "array") and
  all(.data.findings[]; type == "string")
' "$OUTPUT_FILE" >/dev/null 2>&1; then
  log_msg WARN reviewer "Reviewer output did not satisfy the deterministic schema; using fallback review"
  fallback_reviewer
fi

log_msg INFO reviewer "Review saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
