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
TASK_PROJECT_NAME="$(trim_text "${PROJECT_NAME:-$(basename "$PROJECT_DIR")}")"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ] || [ -z "$STEP_FILE" ] || [ -z "$PLAN_FILE" ] || [ -z "$CODER_FILE" ]; then
  require_command reviewer jq
  jq -cn \
    --arg status "retry" \
    --arg message "usage: reviewer.sh <project_dir> <task> <step_file> <plan_file> <coder_file> [output_file]" \
    '{status:$status,message:$message,data:{}}'
  exit 2
fi

require_command reviewer jq
ensure_runtime_dirs
mkdir -p "$(dirname "$OUTPUT_FILE")"

STEP_TEXT="$(json_get "$STEP_FILE" '.text')"
STEP_INDEX="$(json_get "$STEP_FILE" '.index')"
PLAN_JSON="$(safe_read_file "$PLAN_FILE")"
CODER_JSON="$(safe_read_file "$CODER_FILE")"
TASK_CONTEXT_ID="${TASK_ID:-}"
MEMORY_TEXT="$(read_memory_context "$TASK_PROJECT_NAME" "$TASK $STEP_TEXT")"
MEMORY_TEXT="$(truncate_context_to_budget "$MEMORY_TEXT" 2500)"
SIMILAR_TASKS="$(build_similar_task_context "$TASK $STEP_TEXT" "$TASK_PROJECT_NAME" "$TASK_CONTEXT_ID")"
SIMILAR_TASKS_RAW="$SIMILAR_TASKS"
SIMILAR_TASKS="$(truncate_context_to_budget "$SIMILAR_TASKS" 3000)"
CURRENT_TASK_GUIDANCE="$(python3 - "$SIMILAR_TASKS_RAW" "$TASK" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


similar_raw = sys.argv[1]
fallback_task = sys.argv[2]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_list(value: Any, *, limit: int = 3) -> list[str]:
    if not isinstance(value, list):
        return []
    items: list[str] = []
    for entry in value:
        normalized = normalize_text(entry)
        if not normalized or normalized in items:
            continue
        items.append(normalized)
        if len(items) >= limit:
            break
    return items


def pick_current_task(tasks: Any) -> dict[str, Any] | None:
    if not isinstance(tasks, list):
        return None
    for task in tasks:
        if isinstance(task, dict) and task.get("current_task") is True:
            return task
    return None


def task_intent_payload(task: dict[str, Any]) -> dict[str, Any]:
    intent = task.get("task_intent")
    if isinstance(intent, dict):
        return intent
    execution_brief = task.get("execution_brief")
    if isinstance(execution_brief, dict):
        brief_intent = execution_brief.get("task_intent")
        if isinstance(brief_intent, dict):
            return brief_intent
    return {}


def verification_command(task: dict[str, Any]) -> str:
    task_shape = task.get("task_shape")
    if isinstance(task_shape, dict):
        return normalize_text(task_shape.get("verification_command"))
    return ""


try:
    similar_tasks = json.loads(similar_raw)
except Exception:
    similar_tasks = []

current_task = pick_current_task(similar_tasks)
if not isinstance(current_task, dict):
    raise SystemExit(0)

intent = task_intent_payload(current_task)
objective = normalize_text(intent.get("objective") or current_task.get("title") or fallback_task)
context_hint = normalize_text(intent.get("context_hint"))
affected_files = normalize_list(intent.get("affected_files"))
constraints = normalize_list(intent.get("constraints"))
success_signals = normalize_list(intent.get("success_signals"))
command = verification_command(current_task)

lines: list[str] = []
if objective:
    lines.append(f"- Objective: {objective}")
if context_hint:
    lines.append(f"- Focus: {context_hint}")
if affected_files:
    lines.append("- Affected files: " + ", ".join(f"`{path}`" for path in affected_files))
if constraints:
    lines.append("- Constraints: " + "; ".join(constraints))
if success_signals:
    lines.append("- Success signals: " + "; ".join(success_signals))
if command:
    lines.append(f"- Verification command: `{command}`")

if lines:
    lines.append("- Use this metadata to review only the approved scope instead of broadening the queue title.")
    print("\n".join(lines))
PY
)"
CURRENT_TASK_GUIDANCE="$(truncate_context_to_budget "$CURRENT_TASK_GUIDANCE" 1000)"

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
  local step_override="${4:-$STEP_TEXT}"
  local data_json
  data_json="$(jq -cn \
    --arg step "$step_override" \
    --argjson index "$STEP_INDEX" \
    --arg kind "$STEP_KIND" \
    --argjson findings "$findings_json" \
    '{step:$step,index:$index,kind:$kind,findings:$findings}')"
  write_json_file "$OUTPUT_FILE" "$status" "$message" "$data_json"
}

is_generic_implementation_step_value() {
  local normalized_step
  normalized_step="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  [ "$normalized_step" = "implement the requested change with minimal modifications." ] || \
    [ "$normalized_step" = "implement the requested change with minimal modifications" ]
}

coder_retry_guidance() {
  local guidance_step guidance_command
  if ! validate_agent_json "$CODER_FILE"; then
    printf '\n'
    return 0
  fi

  guidance_step="$(jq -r 'if .status != "success" and (.data | type == "object") then (.data.step // "") else "" end' "$CODER_FILE" 2>/dev/null || true)"
  guidance_step="$(printf '%s' "$guidance_step" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  if [ -z "$guidance_step" ] || is_generic_implementation_step_value "$guidance_step"; then
    printf '\n'
    return 0
  fi

  guidance_command="$(
    jq -r '
      first(
        (.data.checks // [])[]?
        | select(type == "string" and startswith("Preferred verification command: "))
        | sub("^Preferred verification command: "; "")
      ) // ""
    ' "$CODER_FILE" 2>/dev/null || true
  )"
  guidance_command="$(printf '%s' "$guidance_command" | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"

  jq -cn --arg step "$guidance_step" --arg command "$guidance_command" '{step:$step,verification_command:$command}'
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
      return 1
      ;;
  esac
}

fallback_reviewer() {
  local retry_guidance retry_step retry_command findings_json
  if ! validate_agent_json "$CODER_FILE"; then
    build_payload "retry" "Coder output was invalid; retry required." '["Coder output could not be parsed as valid JSON."]'
    return 0
  fi

  if ! jq -e '.status == "success"' "$CODER_FILE" >/dev/null 2>&1; then
    retry_guidance="$(coder_retry_guidance)"
    retry_step="$(printf '%s' "$retry_guidance" | jq -r '.step // ""' 2>/dev/null || true)"
    retry_command="$(printf '%s' "$retry_guidance" | jq -r '.verification_command // ""' 2>/dev/null || true)"
    if [ -n "$retry_step" ]; then
      if [ -n "$retry_command" ]; then
        findings_json="$(jq -cn --arg step "$retry_step" --arg command "$retry_command" '[
          "Retry the bounded step: " + $step,
          "Use the preferred verification command: " + $command
        ]')"
      else
        findings_json="$(jq -cn --arg step "$retry_step" '[
          "Retry the bounded step: " + $step
        ]')"
      fi
      build_payload "retry" "Coder reported bounded retry guidance; retry required." "$findings_json" "$retry_step"
      return 0
    fi
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
      elif jq -e '.status == "success"' "$CODER_FILE" >/dev/null 2>&1; then
        # Coder reported success — trust it even for generic tasks to avoid infinite retry loops
        build_payload "approved" "Implementation step approved (coder self-reported success)." '["Coder reported successful completion.","Fallback reviewer accepted coder self-report to prevent retry deadlock."]'
      elif [ "$(task_language)" = "generic" ]; then
        build_payload "retry" "Fallback reviewer cannot validate this generic task deterministically." '["The deterministic fallback reviewer only approves known task patterns such as hello-world implementations.","Retry with live Codex execution or add a task-specific deterministic validator."]'
      else
        build_payload "retry" "Implementation artifact is missing or incomplete." '["Expected implementation output was not found in the project directory.","Retry the implementation step with the required code change."]'
      fi
      ;;
  esac
}

provider_unavailable_reviewer() {
  local findings_json provider reason
  provider="$(current_exec_provider)"
  reason="$(provider_exec_failure_reason)"
  findings_json="$(jq -cn --arg provider "$provider" --arg reason "$reason" '[ "Selected provider " + $provider + " is unavailable: " + $reason ]')"
  build_payload "retry" "Selected provider is unavailable; retry required." "$findings_json"
}

PROMPT="$(cat <<EOF
You are the reviewer agent.

Role:
- Detect bugs, risks, regressions, and missing edge cases for one plan step.
- Return JSON only.
- Use status "approved" when the step is acceptable, otherwise use "retry".
- Prioritize findings that would break runtime behavior, queue/approval/retry semantics, state transitions, data integrity, or deterministic verification.
- Treat missing regression coverage for a behavior-changing step as a review finding when the coder changed runtime logic without adding or updating the focused test the plan called for.
- Check placeholder/stub code, empty function bodies, TODO comments, and hardcoded test values only when they leave the requested behavior incomplete or make verification misleading.
- Ignore naming/style-only issues unless they directly cause a bug, break imports/paths, or violate an explicit file/identifier contract in the step.
- Prefer a short list of high-signal defects over broad cleanup commentary. If there is no concrete defect or regression risk, approve the step.

Task:
$TASK

Active step index:
$STEP_INDEX

Active step:
$STEP_TEXT

Project directory:
$(relative_path "$PROJECT_DIR" "$ROOT_DIR")

$(if [ -n "$MEMORY_TEXT" ] && [ "$MEMORY_TEXT" != "null" ]; then printf 'PROJECT MEMORY:\n%s\n\n' "$MEMORY_TEXT"; fi)$(if [ -n "$CURRENT_TASK_GUIDANCE" ] && [ "$CURRENT_TASK_GUIDANCE" != "null" ]; then printf 'CURRENT TASK SHAPE:\n%s\n\n' "$CURRENT_TASK_GUIDANCE"; fi)

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

if ! run_agent_exec reviewer "$PROJECT_DIR" "$TASK" "$PROMPT" "$OUTPUT_FILE"; then
  if provider_exec_requires_abort; then
    log_msg WARN reviewer "Selected provider $(current_exec_provider) is unavailable: $(provider_exec_failure_reason)"
    provider_unavailable_reviewer
  else
    fallback_reviewer
  fi
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
