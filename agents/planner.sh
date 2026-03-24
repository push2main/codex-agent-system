#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap planner

PROJECT_DIR="${1:-}"
TASK="${2:-}"
OUTPUT_FILE="${3:-$LOG_DIR/planner-latest.json}"
MEMORY_FILE="${4:-}"
TASK_CONTEXT_ID="${TASK_ID:-}"

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
SIMILAR_TASKS="$(build_similar_task_context "$TASK" "$(basename "$PROJECT_DIR")" "$TASK_CONTEXT_ID")"
VERIFICATION_GUIDANCE="$(build_verification_guidance "$TASK" "" "$(basename "$PROJECT_DIR")" "$TASK_CONTEXT_ID")"
STEP_BOUNDS="$(resolve_task_step_bounds "$(basename "$PROJECT_DIR")" "$TASK" "2" "6" 2>/dev/null || printf '2\n6\n')"
PLAN_MIN_STEPS="$(printf '%s\n' "$STEP_BOUNDS" | sed -n '1p')"
PLAN_MAX_STEPS="$(printf '%s\n' "$STEP_BOUNDS" | sed -n '2p')"
[ -n "$PLAN_MIN_STEPS" ] || PLAN_MIN_STEPS="2"
[ -n "$PLAN_MAX_STEPS" ] || PLAN_MAX_STEPS="6"
PROMPT="$(cat <<EOF
You are the planner agent in an autonomous local coding system on macOS.

Role:
- Break the task into the smallest safe execution steps.
- Prefer deterministic and debuggable work.
- Keep the plan between $PLAN_MIN_STEPS and $PLAN_MAX_STEPS steps.
- For smaller tasks, collapse inspection and verification into fewer steps instead of producing a long inventory-style plan.
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

Similar historical task context:
$SIMILAR_TASKS

Verification guidance:
$VERIFICATION_GUIDANCE

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

task_specific_guidance() {
  python3 - "$TASK" "$SIMILAR_TASKS" "$VERIFICATION_GUIDANCE" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


task_text = sys.argv[1]
similar_raw = sys.argv[2]
verification_guidance = sys.argv[3]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_key(value: Any) -> str:
    return normalize_text(value).lower()


def is_generic_implementation_step(value: str) -> bool:
    return normalize_key(value).rstrip(".") == "implement the requested change with minimal modifications"


def step_kind(value: str) -> str:
    lower = normalize_key(value)
    if lower.startswith(("verify", "test", "run ", "check", "confirm")):
        return "verify"
    if lower.startswith(("inspect", "review", "analy", "understand", "choose")):
        return "inspect"
    return "implement"


def looks_like_command(value: str) -> bool:
    normalized = normalize_text(value)
    if not normalized:
        return False
    token = normalized.split()[0]
    if token in {
        "bash",
        "sh",
        "python",
        "python3",
        "node",
        "npm",
        "npx",
        "pnpm",
        "yarn",
        "pytest",
        "py.test",
        "go",
        "cargo",
        "make",
        "jq",
    }:
        return True
    return token.startswith("./") or token.startswith("../")


def extract_command(value: str) -> str:
    for candidate in re.findall(r"`([^`]+)`", str(value or "")):
        normalized = normalize_text(candidate)
        if looks_like_command(normalized):
            return normalized
    normalized = normalize_text(value)
    return normalized if looks_like_command(normalized) else ""


def failed_step_from_task(task: dict[str, Any], *, allow_verify: bool) -> str:
    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = normalize_text(context.get("failed_step"))
        if not candidate or is_generic_implementation_step(candidate):
            continue
        if not allow_verify and step_kind(candidate) == "verify":
            continue
        return candidate.rstrip(".") + "."
    return ""


def verification_command_from_task(task: dict[str, Any]) -> str:
    task_shape = task.get("task_shape")
    if isinstance(task_shape, dict):
        candidate = normalize_text(task_shape.get("verification_command"))
        if looks_like_command(candidate):
            return candidate
    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = extract_command(normalize_text(context.get("failed_step")))
        if candidate:
            return candidate
    return ""


def intent_implementation_step(task: dict[str, Any], fallback_task_text: str) -> str:
    if not isinstance(task, dict):
        return ""

    task_intent = task.get("task_intent")
    if not isinstance(task_intent, dict):
        execution_brief = task.get("execution_brief")
        if isinstance(execution_brief, dict):
            task_intent = execution_brief.get("task_intent")
    if not isinstance(task_intent, dict):
        return ""

    objective = normalize_text(task_intent.get("objective") or task.get("title") or fallback_task_text)
    if not objective:
        return ""

    affected_files = [
        normalize_text(value)
        for value in (task_intent.get("affected_files") if isinstance(task_intent.get("affected_files"), list) else [])
        if normalize_text(value)
    ][:3]
    constraints = [
        normalize_text(value)
        for value in (task_intent.get("constraints") if isinstance(task_intent.get("constraints"), list) else [])
        if normalize_text(value)
    ][:3]
    context_hint = normalize_text(task_intent.get("context_hint"))

    file_scope = ""
    if affected_files:
        tick = chr(96)
        formatted_files = ", ".join(f"{tick}{path}{tick}" for path in affected_files)
        file_scope = f"In {formatted_files}, "

    step = f"{file_scope}implement the smallest safe change for: {objective}."
    if context_hint:
        step += f" Focus on {context_hint.rstrip('.')}."
    if constraints:
        step += " Keep these constraints: " + "; ".join(constraint.rstrip(".") for constraint in constraints) + "."
    return step


def exact_match(task: dict[str, Any], task_key: str) -> bool:
    titles = [
        task.get("title"),
        ((task.get("task_intent") or {}).get("objective") if isinstance(task.get("task_intent"), dict) else ""),
    ]
    return any(normalize_key(title) == task_key for title in titles if normalize_text(title))


try:
    similar_tasks = json.loads(similar_raw)
except Exception:
    similar_tasks = []
if not isinstance(similar_tasks, list):
    similar_tasks = []

task_key = normalize_key(task_text)
selected_step_task: dict[str, Any] | None = None
selected_step_score: tuple[Any, ...] | None = None

for candidate in similar_tasks:
    if not isinstance(candidate, dict):
        continue
    nonverify_failed_step = failed_step_from_task(candidate, allow_verify=False)
    any_failed_step = failed_step_from_task(candidate, allow_verify=True)
    intent_step = intent_implementation_step(candidate, task_text)
    score = (
        1 if candidate.get("current_task") is True else 0,
        1 if nonverify_failed_step else 0,
        1 if exact_match(candidate, task_key) else 0,
        1 if any_failed_step else 0,
        1 if intent_step else 0,
        normalize_text(candidate.get("updated_at") or candidate.get("created_at")),
    )
    if selected_step_score is None or score > selected_step_score:
        selected_step_task = candidate
        selected_step_score = score

implementation_step = failed_step_from_task(selected_step_task or {}, allow_verify=False)
if not implementation_step:
    implementation_step = failed_step_from_task(selected_step_task or {}, allow_verify=True)
if not implementation_step:
    implementation_step = intent_implementation_step(selected_step_task or {}, task_text)

verification_command = ""
for pool in (
    [task for task in similar_tasks if isinstance(task, dict) and exact_match(task, task_key)],
    [task for task in similar_tasks if isinstance(task, dict)],
):
    for candidate in pool:
        verification_command = verification_command_from_task(candidate)
        if verification_command:
            break
    if verification_command:
        break

if not verification_command:
    verification_command = extract_command(verification_guidance)

print(json.dumps({"step": implementation_step, "verification_command": verification_command}))
PY
}

fallback_planner() {
  local data_json guidance_json implementation_step verification_command
  guidance_json="$(task_specific_guidance)"
  implementation_step="$(printf '%s' "$guidance_json" | jq -r '.step // ""')"
  verification_command="$(printf '%s' "$guidance_json" | jq -r '.verification_command // ""')"
  data_json="$(python3 - "$TASK" "$implementation_step" "$verification_command" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


task_text = sys.argv[1]
implementation_step = str(sys.argv[2] or "").strip()
verification_command = str(sys.argv[3] or "").strip()


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


steps = [
    f"Inspect the current project files and choose the smallest safe implementation for: {normalize_text(task_text)}",
    implementation_step or "Implement the requested change with minimal modifications.",
]
if verification_command:
    tick = chr(96)
    steps.append(f"Run {tick}{verification_command}{tick} and confirm the exact pass/fail outcome.")
else:
    steps.append("Run a lightweight verification relevant to the task and confirm the outcome.")

print(json.dumps({"steps": steps}))
PY
)"
  write_json_file "$OUTPUT_FILE" "success" "Created deterministic fallback plan." "$data_json"
}

provider_unavailable_planner() {
  local data_json provider reason
  provider="$(current_exec_provider)"
  reason="$(provider_exec_failure_reason)"
  data_json="$(jq -cn --arg provider "$provider" --arg reason "$reason" '{provider:$provider,reason:$reason}')"
  write_json_file "$OUTPUT_FILE" "fail" "Selected provider is unavailable for planner execution." "$data_json"
}

repair_generic_plan() {
  local guidance_json implementation_step verification_command
  guidance_json="$(task_specific_guidance)"
  implementation_step="$(printf '%s' "$guidance_json" | jq -r '.step // ""')"
  verification_command="$(printf '%s' "$guidance_json" | jq -r '.verification_command // ""')"

  python3 - "$OUTPUT_FILE" "$implementation_step" "$verification_command" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


path = Path(sys.argv[1])
implementation_step = str(sys.argv[2] or "").strip()
verification_command = str(sys.argv[3] or "").strip()


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def is_generic_implementation_step(value: str) -> bool:
    return normalize_text(value).lower().rstrip(".") == "implement the requested change with minimal modifications"


def is_generic_verification_step(value: str) -> bool:
    normalized = normalize_text(value).lower().rstrip(".")
    return normalized == "run a lightweight verification relevant to the task and confirm the outcome"


try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

data = payload.get("data")
steps = data.get("steps") if isinstance(data, dict) else None
if not isinstance(steps, list):
    raise SystemExit(0)

updated_steps: list[str] = []
changed = False

for step in steps:
    candidate = str(step or "")
    if implementation_step and is_generic_implementation_step(candidate):
      updated_steps.append(implementation_step)
      changed = True
      continue
    if verification_command and is_generic_verification_step(candidate):
      updated_steps.append(f"Run `{verification_command}` and confirm the exact pass/fail outcome.")
      changed = True
      continue
    updated_steps.append(candidate)

if not changed:
    raise SystemExit(0)

payload.setdefault("data", {})["steps"] = updated_steps
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

if ! run_agent_exec planner "$PROJECT_DIR" "$TASK" "$PROMPT" "$OUTPUT_FILE"; then
  if provider_exec_requires_abort; then
    log_msg WARN planner "Selected provider $(current_exec_provider) is unavailable: $(provider_exec_failure_reason)"
    provider_unavailable_planner
  else
    fallback_planner
  fi
elif ! validate_agent_json "$OUTPUT_FILE"; then
  log_msg WARN planner "Planner output was not valid JSON; using fallback plan"
  fallback_planner
elif ! jq -e '
  .status == "success" and
  (.data.steps | type == "array") and
  ((.data.steps | length) >= ($min_steps | tonumber)) and
  ((.data.steps | length) <= ($max_steps | tonumber)) and
  all(.data.steps[]; type == "string" and (gsub("\\s+"; " ") | length > 0))
' --arg min_steps "$PLAN_MIN_STEPS" --arg max_steps "$PLAN_MAX_STEPS" "$OUTPUT_FILE" >/dev/null 2>&1; then
  log_msg WARN planner "Planner output did not satisfy the deterministic schema; using fallback plan"
  fallback_planner
fi

repair_generic_plan
log_msg INFO planner "Plan saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
