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
TASK_PROJECT_NAME="$(trim_text "${PROJECT_NAME:-$(basename "$PROJECT_DIR")}")"

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
    lines.append("- Use this metadata to evaluate only the approved scope instead of broadening the queue title.")
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

$(if [ -n "$MEMORY_TEXT" ] && [ "$MEMORY_TEXT" != "null" ]; then printf 'PROJECT MEMORY:\n%s\n\n' "$MEMORY_TEXT"; fi)$(if [ -n "$CURRENT_TASK_GUIDANCE" ] && [ "$CURRENT_TASK_GUIDANCE" != "null" ]; then printf 'CURRENT TASK SHAPE:\n%s\n\n' "$CURRENT_TASK_GUIDANCE"; fi)

Plan JSON:
$PLAN_JSON

Review JSON:
$REVIEW_JSON

SCORING RULES — you MUST calculate the score field, do NOT default to 0:
- score is an integer from 0 to 10 measuring how much VALUE this step produced
- 0 = no useful work done (empty output, no change, pure boilerplate)
- 1-2 = introspection only (inventory, verification, or analysis that confirms existing state without code changes)
- 3-4 = minor work (trivial code change, cosmetic fix, adding a comment, no functional impact)
- 5-6 = moderate work (meaningful implementation, partial feature, bug fix with tests)
- 7-9 = significant work (complete feature, important fix, measurable improvement)
- 10 = exceptional (critical fix, major feature, breakthrough improvement)
- If the review approved the step AND the step produced code changes, score should be at least 5
- If the review approved the step but only introspection/inventory was performed (no code changes), score should be 1-2
- If the review rejected the step, score should be 0-3 based on partial progress made
- IMPORTANT: Inventory tasks, verification tasks, and tasks that only READ code without CHANGING it are worth 1-2 at most, even if they succeed

Return JSON only with this exact shape:
{
  "status": "success" or "fail",
  "message": "short summary",
  "data": {
    "step": "$STEP_TEXT",
    "index": $STEP_INDEX,
    "kind": "$STEP_KIND",
    "score": <integer 0-10 — CALCULATE THIS based on value produced>,
    "reason": "short reason including why you assigned this score"
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

# v15/v32 fix: Clamp scores for successful steps to prevent zero-score blindness.
# v15 original: blanket clamp to 5. v32 improvement: differentiate inventory/verify
# tasks (clamp to 1) from code-producing tasks (clamp to 5). This gives the
# effective_success_rate metric meaningful signal instead of inflating all successes.
if jq -e '.status == "success" and (.data.score | type == "number") and .data.score < 1' "$OUTPUT_FILE" >/dev/null 2>&1; then
  _old_score="$(jq -r '.data.score' "$OUTPUT_FILE")"
  # Detect inventory/introspection-only tasks by task title.
  # v38: Expanded to include "verify" and "validate" tasks which consistently
  # score 0 because they read code without changing it. Previous exclusion of
  # "verify" was based on the assumption they produce code assertions, but
  # trace data shows 50+ verify tasks all scoring 0 — they are pure reads.
  _is_introspection="false"
  if printf '%s' "$TASK" | grep -qiE '(inventory|introspect|decision path|verify |validate )'; then
    _is_introspection="true"
  fi
  if [ "$_is_introspection" = "true" ]; then
    _clamp_score=1
    log_msg INFO evaluator "Introspection task success: score=$_old_score → clamping to $_clamp_score (inventory/verify task)"
  else
    _clamp_score=5
    log_msg WARN evaluator "Zero-score blindness detected: status=success but score=$_old_score; clamping to $_clamp_score"
  fi
  jq --argjson clamp "$_clamp_score" '.data.score = (if .data.score < $clamp then $clamp else .data.score end)' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
fi

log_msg INFO evaluator "Evaluation saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
