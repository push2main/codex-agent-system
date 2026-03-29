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

# ─── Code-enforced task rejection gates (self-learning fix 2026-03-28) ───
# Rules were previously prompt-only suggestions with 0% compliance.
# Now enforced as hard bash gates before any LLM call.
_task_char_count="${#TASK}"
if [ "$_task_char_count" -gt 500 ]; then
  log_msg WARN planner "Task text too long (${_task_char_count} chars > 500 limit); rejecting as non-retriable"
  jq -cn \
    --arg status "fail" \
    --arg message "Task text exceeds 500-char limit (${_task_char_count} chars). Rewrite as a shorter, single-goal task." \
    '{status:$status,message:$message,data:{}}' > "$OUTPUT_FILE"
  print_json_file "$OUTPUT_FILE"
  exit 3
fi

MEMORY_CONTEXT=""
if [ -n "$MEMORY_FILE" ] && [ -f "$MEMORY_FILE" ]; then
  MEMORY_CONTEXT="$(safe_read_file "$MEMORY_FILE")"
else
  MEMORY_CONTEXT="$(read_memory_context "$(basename "$PROJECT_DIR")" "$TASK")"
fi

RULES_TEXT="$(safe_tail 50 "$RULES_FILE")"
PROJECT_HINT="$(relative_path "$PROJECT_DIR" "$ROOT_DIR")"
SOURCE_CONTEXT="$(build_prompt_source_context "$TASK" "" "$(basename "$PROJECT_DIR")")"
SIMILAR_TASKS="$(build_similar_task_context "$TASK" "$(basename "$PROJECT_DIR")" "$TASK_CONTEXT_ID")"
VERIFICATION_GUIDANCE="$(build_verification_guidance "$TASK" "" "$(basename "$PROJECT_DIR")" "$TASK_CONTEXT_ID")"

CURRENT_TASK_GUIDANCE="$(python3 - "$SIMILAR_TASKS" "$TASK" <<'PY'
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


def execution_brief_payload(task: dict[str, Any]) -> dict[str, Any]:
    execution_brief = task.get("execution_brief")
    if isinstance(execution_brief, dict):
        return execution_brief
    return {}


def task_shape_payload(task: dict[str, Any]) -> dict[str, Any]:
    task_shape = task.get("task_shape")
    if isinstance(task_shape, dict):
        return task_shape
    return {}


def editable_files_payload(task: dict[str, Any]) -> list[str]:
    execution_brief = execution_brief_payload(task)
    editable_files = normalize_list(execution_brief.get("editable_files"))
    if editable_files:
        return editable_files
    task_shape = task_shape_payload(task)
    editable_files = normalize_list(task_shape.get("editable_files"))
    if editable_files:
        return editable_files
    return normalize_list(task_intent_payload(task).get("affected_files"))


def frozen_files_payload(task: dict[str, Any]) -> list[str]:
    execution_brief = execution_brief_payload(task)
    frozen_files = normalize_list(execution_brief.get("frozen_files"))
    if frozen_files:
        return frozen_files
    return normalize_list(task_shape_payload(task).get("frozen_files"))


def verification_command(task: dict[str, Any]) -> str:
    execution_brief = execution_brief_payload(task)
    candidate = normalize_text(execution_brief.get("frozen_verify_command"))
    if candidate:
        return candidate
    task_shape = task_shape_payload(task)
    candidate = normalize_text(task_shape.get("verification_command"))
    if candidate:
        return candidate
    return ""


try:
    similar_tasks = json.loads(similar_raw)
except Exception:
    similar_tasks = []

current_task = pick_current_task(similar_tasks)
if not isinstance(current_task, dict):
    raise SystemExit(0)

intent = task_intent_payload(current_task)
objective = normalize_text(
    intent.get("objective")
    or current_task.get("title")
    or fallback_task
)
context_hint = normalize_text(intent.get("context_hint"))
affected_files = normalize_list(intent.get("affected_files"))
editable_files = editable_files_payload(current_task)
frozen_files = frozen_files_payload(current_task)
constraints = normalize_list(intent.get("constraints"))
success_signals = normalize_list(intent.get("success_signals"))
command = verification_command(current_task)

lines: list[str] = []
if objective:
    lines.append(f"- Objective: {objective}")
if context_hint:
    lines.append(f"- Focus: {context_hint}")
if editable_files:
    lines.append("- Editable files: " + ", ".join(f"`{path}`" for path in editable_files))
if affected_files and affected_files != editable_files:
    lines.append("- Affected files: " + ", ".join(f"`{path}`" for path in affected_files))
if frozen_files:
    lines.append("- Frozen files: " + ", ".join(f"`{path}`" for path in frozen_files))
if constraints:
    lines.append("- Constraints: " + "; ".join(constraints))
if success_signals:
    lines.append("- Success signals: " + "; ".join(success_signals))
if command:
    lines.append(f"- Frozen verification command: `{command}`")

if lines:
    lines.append("- Use this metadata to turn the compact queue title into one bounded implementation plan without editing outside the approved execution surface.")
    print("\n".join(lines))
PY
)"
CURRENT_TASK_PLAYBOOK_PATH="$(python3 - "$SIMILAR_TASKS" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


similar_raw = sys.argv[1]


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def pick_current_task(tasks: Any) -> dict[str, Any] | None:
    if not isinstance(tasks, list):
        return None
    for task in tasks:
        if isinstance(task, dict) and task.get("current_task") is True:
            return task
    return None


def playbook_path(task: dict[str, Any]) -> str:
    task_shape = task.get("task_shape")
    if isinstance(task_shape, dict):
        candidate = normalize_text(task_shape.get("playbook"))
        if candidate:
            return candidate
    candidate = normalize_text(task.get("strategy_playbook"))
    return candidate


try:
    similar_tasks = json.loads(similar_raw)
except Exception:
    similar_tasks = []

current_task = pick_current_task(similar_tasks)
if not isinstance(current_task, dict):
    raise SystemExit(0)

path = playbook_path(current_task)
if path:
    print(path)
PY
)"
PLAYBOOK_CONTEXT=""
if [ -n "$CURRENT_TASK_PLAYBOOK_PATH" ]; then
  CURRENT_TASK_PLAYBOOK_FILE="$CURRENT_TASK_PLAYBOOK_PATH"
  case "$CURRENT_TASK_PLAYBOOK_FILE" in
    /*) ;;
    *) CURRENT_TASK_PLAYBOOK_FILE="$ROOT_DIR/$CURRENT_TASK_PLAYBOOK_FILE" ;;
  esac
  if [ -f "$CURRENT_TASK_PLAYBOOK_FILE" ]; then
    PLAYBOOK_CONTEXT="$(safe_read_file "$CURRENT_TASK_PLAYBOOK_FILE")"
    if [ -n "$PLAYBOOK_CONTEXT" ]; then
      PLAYBOOK_CONTEXT="$(printf 'Path: %s\n%s' "$CURRENT_TASK_PLAYBOOK_PATH" "$PLAYBOOK_CONTEXT")"
    fi
  fi
fi
RULES_TEXT="$(truncate_context_to_budget "$RULES_TEXT" 1200)"
MEMORY_CONTEXT="$(truncate_context_to_budget "$MEMORY_CONTEXT" 1800)"
SOURCE_CONTEXT="$(truncate_context_to_budget "$SOURCE_CONTEXT" 1500)"
SIMILAR_TASKS="$(truncate_context_to_budget "$SIMILAR_TASKS" 1200)"
VERIFICATION_GUIDANCE="$(truncate_context_to_budget "$VERIFICATION_GUIDANCE" 1200)"
CURRENT_TASK_GUIDANCE="$(truncate_context_to_budget "$CURRENT_TASK_GUIDANCE" 1000)"
PLAYBOOK_CONTEXT="$(truncate_context_to_budget "$PLAYBOOK_CONTEXT" 1000)"
STEP_BOUNDS="$(resolve_task_step_bounds "$(basename "$PROJECT_DIR")" "$TASK" "2" "6" 2>/dev/null || printf '2\n6\n')"
PLAN_MIN_STEPS="$(printf '%s\n' "$STEP_BOUNDS" | sed -n '1p')"
PLAN_MAX_STEPS="$(printf '%s\n' "$STEP_BOUNDS" | sed -n '2p')"
[ -n "$PLAN_MIN_STEPS" ] || PLAN_MIN_STEPS="2"
[ -n "$PLAN_MAX_STEPS" ] || PLAN_MAX_STEPS="6"
PROMPT="$(cat <<EOF
You are a planner agent for an autonomous coding system. Break the task into $PLAN_MIN_STEPS-$PLAN_MAX_STEPS concrete, actionable steps.

SCOPE: Focus on ONE discrete deliverable per plan. If the task implies multiple features, plan only the most important one. A focused plan with 3 precise steps beats a broad plan with 6 vague ones.

STEP FORMAT — every step MUST include ALL of:
1. TARGET FILE: The exact file path to create or edit (e.g. "scripts/lib.sh")
2. EXACT CHANGE: What function/variable/block to add, modify, or remove — not just "update" but HOW
3. EXPECTED OUTCOME: What the file should look like after the change or what command should succeed

BAD step: "Update the retry logic in orchestrator.sh"
GOOD step: "In agents/orchestrator.sh, inside the for loop at the retry section (~line 400), add a call to classify_failure() before the retry decision. If retriable=false, break out of the loop and mark the task as failed with the classification reason."

RULES:
- Do NOT use vague words like "implement", "update", "improve", "enhance" without specifying HOW
- Each step MUST name the exact files to modify and the expected output/artifact. Vague steps like "implement the feature" are not allowed.
- Step 1 should always be an inspection step that reads existing code to understand the current structure.
- If the task changes runtime or persisted behavior and a concrete test file/command is available, add a pre-implementation step that adds or updates one focused failing or missing test first. Docs, inventory, naming-only, and pure refactor tasks are exempt.
- Do NOT create inventory/inspection steps unless the task explicitly requires understanding unknown code structure
- The LAST step (verification step) must specify the EXACT command to run and what success looks like.
- Each step must be completable by a coder agent that can ONLY read/write files and run shell commands
- If a step might fail, state the expected error and how the coder should handle it
- Prefer creating/editing EXISTING files over creating new ones
- If CURRENT TASK SHAPE lists editable files, every non-verification step MUST stay within those files. Treat frozen files and the frozen verification command as immutable context.
- If the task involves Android/Gradle commands and CODEX_DOCKER_DELEGATE is set, tell the coder to use the docker wrapper for those commands.

TASK: $TASK
PROJECT: $PROJECT_HINT

$(if [ -n "$RULES_TEXT" ]; then printf 'RULES:\n%s\n' "$RULES_TEXT"; fi)

$(if [ -n "$MEMORY_CONTEXT" ]; then printf 'PROJECT MEMORY:\n%s\n' "$MEMORY_CONTEXT"; fi)

$(if [ -n "$CURRENT_TASK_GUIDANCE" ] && [ "$CURRENT_TASK_GUIDANCE" != "null" ]; then printf 'CURRENT TASK SHAPE:\n%s\n' "$CURRENT_TASK_GUIDANCE"; fi)

$(if [ -n "$PLAYBOOK_CONTEXT" ] && [ "$PLAYBOOK_CONTEXT" != "null" ]; then printf 'PLAYBOOK:\n%s\n' "$PLAYBOOK_CONTEXT"; fi)

$(if [ -n "$SOURCE_CONTEXT" ] && [ "$SOURCE_CONTEXT" != "null" ]; then printf 'RELEVANT SOURCE:\n%s\n' "$SOURCE_CONTEXT"; fi)

$(if [ -n "$SIMILAR_TASKS" ] && [ "$SIMILAR_TASKS" != "[]" ] && [ "$SIMILAR_TASKS" != "null" ]; then printf 'SIMILAR TASKS:\n%s\n' "$SIMILAR_TASKS"; fi)

$(if [ -n "$VERIFICATION_GUIDANCE" ] && [ "$VERIFICATION_GUIDANCE" != "null" ]; then printf 'VERIFICATION:\n%s\n' "$VERIFICATION_GUIDANCE"; fi)

Return JSON only:
{
  "status": "success",
  "message": "short summary of the ONE deliverable",
  "data": {
    "steps": [
      "Step 1: In <file>, <exact change>. Expected: <outcome>.",
      "Step 2: ...",
      "Step N (verify): Run <command> and confirm <expected result>."
    ]
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
        "test",
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
    execution_brief = task.get("execution_brief")
    if isinstance(execution_brief, dict):
        candidate = normalize_text(execution_brief.get("frozen_verify_command"))
        if looks_like_command(candidate):
            return candidate
    task_shape = task.get("task_shape")
    if isinstance(task_shape, dict):
        candidate = normalize_text(task_shape.get("verification_command"))
        if looks_like_command(candidate):
            return candidate
    if normalize_text(task.get("strategy_template")) == "bounded_learning_inventory":
        experiment = normalize_text(task.get("experiment"))
        artifact_match = re.search(r"\bat\s+([A-Za-z0-9_./-]+\.md)\b", experiment)
        if artifact_match:
            return f"test -s {artifact_match.group(1)}"
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

    if normalize_text(task.get("strategy_template")) == "bounded_learning_inventory":
        experiment = normalize_text(task.get("experiment"))
        if experiment:
            return experiment.rstrip(".") + "."

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

    execution_brief = task.get("execution_brief")
    affected_files = []
    if isinstance(execution_brief, dict):
        affected_files = [
            normalize_text(value)
            for value in (execution_brief.get("editable_files") if isinstance(execution_brief.get("editable_files"), list) else [])
            if normalize_text(value)
        ][:3]
    if not affected_files:
        task_shape = task.get("task_shape")
        if isinstance(task_shape, dict):
            affected_files = [
                normalize_text(value)
                for value in (task_shape.get("editable_files") if isinstance(task_shape.get("editable_files"), list) else [])
                if normalize_text(value)
            ][:3]
    if not affected_files:
        affected_files = [
            normalize_text(value)
            for value in (task_intent.get("affected_files") if isinstance(task_intent.get("affected_files"), list) else [])
            if normalize_text(value)
        ][:3]
    if not affected_files:
        affected_files = [
            normalize_text(value)
            for value in (task.get("target_files") if isinstance(task.get("target_files"), list) else [])
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

planner_timeout_fallback_signal() {
  python3 - "$TASK_LOG" "$(basename "$PROJECT_DIR")" "$TASK" "${TASK_REGISTRY_FILE:-}" "$TASK_CONTEXT_ID" <<'PY'
from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


log_path = Path(sys.argv[1])
project_name = str(sys.argv[2] or "").strip()
task_title = str(sys.argv[3] or "").strip()
registry_path = Path(sys.argv[4]) if len(sys.argv) > 4 and str(sys.argv[4] or "").strip() else None
task_id = str(sys.argv[5] or "").strip()


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


def parse_timestamp(value: Any) -> datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    normalized = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        return datetime.fromisoformat(normalized)
    except ValueError:
        return None


def normalize_identifier(value: Any) -> str:
    return str(value or "").strip().lower()


def original_failed_root_id(task: dict[str, Any]) -> str:
    direct = str(task.get("original_failed_root_id") or "").strip()
    if direct:
        return direct
    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = str(context.get("original_failed_root_id") or "").strip()
        if candidate:
            return candidate
    return str(task.get("id") or "").strip()


def canonical_objective(task: dict[str, Any]) -> str:
    task_intent = task.get("task_intent") if isinstance(task.get("task_intent"), dict) else {}
    execution_brief = task.get("execution_brief") if isinstance(task.get("execution_brief"), dict) else {}
    brief_intent = execution_brief.get("task_intent") if isinstance(execution_brief.get("task_intent"), dict) else {}
    return normalize_text(
        task_intent.get("objective")
        or brief_intent.get("objective")
        or task.get("title")
        or ""
    )


def unwrap_task_title(value: Any) -> str:
    text = normalize_text(value)
    if not text:
        return ""
    text = re.sub(r"^\[[^\]]+\]\s*", "", text)
    match = re.fullmatch(r"replace\s+(.+?)\s+with a different bounded experiment", text)
    if match:
        text = match.group(1).strip()
    text = re.sub(r"^inventory current state for\s+", "", text)
    return normalize_text(text)


def remember_title(target: set[str], value: Any) -> None:
    normalized = normalize_text(value)
    if normalized:
        target.add(normalized)
    unwrapped = unwrap_task_title(value)
    if unwrapped:
        target.add(unwrapped)


def collect_lineage_titles() -> set[str]:
    keys: set[str] = set()
    if registry_path is None or not registry_path.is_file() or not task_id:
        return keys
    try:
        payload = json.loads(registry_path.read_text(encoding="utf-8"))
    except Exception:
        return keys
    tasks = payload.get("tasks")
    if not isinstance(tasks, list):
        return keys

    project_key = normalize_text(project_name)
    selected_task: dict[str, Any] | None = None
    for candidate in tasks:
        if not isinstance(candidate, dict):
            continue
        candidate_project = normalize_text(candidate.get("project") or candidate.get("target_project") or "")
        if project_key and candidate_project != project_key:
            continue
        if normalize_identifier(candidate.get("id")) == normalize_identifier(task_id):
            selected_task = candidate
            break

    if not isinstance(selected_task, dict):
        return keys

    selected_root = normalize_identifier(original_failed_root_id(selected_task))
    selected_objective = canonical_objective(selected_task)
    remember_title(keys, selected_task.get("title"))
    remember_title(keys, (selected_task.get("task_intent") or {}).get("objective") if isinstance(selected_task.get("task_intent"), dict) else "")
    execution_brief = selected_task.get("execution_brief")
    if isinstance(execution_brief, dict):
        brief_intent = execution_brief.get("task_intent")
        if isinstance(brief_intent, dict):
            remember_title(keys, brief_intent.get("objective"))

    for candidate in tasks:
        if not isinstance(candidate, dict):
            continue
        candidate_project = normalize_text(candidate.get("project") or candidate.get("target_project") or "")
        if project_key and candidate_project != project_key:
            continue
        same_root = bool(selected_root) and normalize_identifier(original_failed_root_id(candidate)) == selected_root
        same_objective = bool(selected_objective) and canonical_objective(candidate) == selected_objective
        if not same_root and not same_objective:
            continue
        remember_title(keys, candidate.get("title"))
        remember_title(keys, (candidate.get("task_intent") or {}).get("objective") if isinstance(candidate.get("task_intent"), dict) else "")
        execution_brief = candidate.get("execution_brief")
        if isinstance(execution_brief, dict):
            brief_intent = execution_brief.get("task_intent")
            if isinstance(brief_intent, dict):
                remember_title(keys, brief_intent.get("objective"))

    return keys


def title_match_kind(record_title: Any, exact_titles: set[str], lineage_titles: set[str]) -> str:
    normalized = normalize_text(record_title)
    if not normalized:
        return ""
    normalized_unwrapped = unwrap_task_title(record_title)
    comparisons = {normalized}
    if normalized_unwrapped:
        comparisons.add(normalized_unwrapped)
    for candidate in exact_titles:
        for comparison in comparisons:
            if comparison == candidate:
                return "exact_title"
            if comparison.endswith(candidate):
                return "exact_title"
    for candidate in lineage_titles:
        for comparison in comparisons:
            if comparison == candidate:
                return "lineage"
            if comparison.endswith(candidate):
                return "lineage"
    return ""


if not log_path.is_file() or not project_name or not task_title:
    raise SystemExit(0)

target_project = normalize_text(project_name)
exact_titles: set[str] = set()
current_title = normalize_text(task_title)
if current_title:
    exact_titles.add(current_title)
lineage_titles = collect_lineage_titles()
current_unwrapped_title = unwrap_task_title(task_title)
if current_unwrapped_title and current_unwrapped_title != current_title:
    lineage_titles.add(current_unwrapped_title)
lineage_titles -= exact_titles
latest_success_at: datetime | None = None
latest_zero_step_timeout: dict[str, Any] | None = None

for raw_line in log_path.read_text(encoding="utf-8").splitlines():
    raw_line = raw_line.strip()
    if not raw_line:
        continue
    try:
        record = json.loads(raw_line)
    except Exception:
        continue

    if normalize_text(record.get("project")) != target_project:
        continue
    match_kind = title_match_kind(record.get("task"), exact_titles, lineage_titles)
    if not match_kind:
        continue

    timestamp = parse_timestamp(record.get("timestamp"))
    result = normalize_text(record.get("result"))
    if result == "success":
        if timestamp is not None and (latest_success_at is None or timestamp > latest_success_at):
            latest_success_at = timestamp
        continue

    if result != "failure":
        continue
    if normalize_text(record.get("failure_kind")) != "timeout":
        continue
    if int(record.get("total_step_attempts") or 0) != 0:
        continue

    if latest_zero_step_timeout is None:
        latest_zero_step_timeout = {
            "timestamp": timestamp,
            "reason": str(record.get("failed_step") or "").strip(),
            "match_type": match_kind,
            "matched_title": str(record.get("task") or "").strip(),
        }
        continue

    previous_ts = latest_zero_step_timeout.get("timestamp")
    if timestamp is not None and (previous_ts is None or timestamp > previous_ts):
        latest_zero_step_timeout = {
            "timestamp": timestamp,
            "reason": str(record.get("failed_step") or "").strip(),
            "match_type": match_kind,
            "matched_title": str(record.get("task") or "").strip(),
        }

if latest_zero_step_timeout is None:
    raise SystemExit(0)

timeout_timestamp = latest_zero_step_timeout.get("timestamp")
if latest_success_at is not None and timeout_timestamp is not None and latest_success_at >= timeout_timestamp:
    raise SystemExit(0)

reason = str(latest_zero_step_timeout.get("reason") or "").strip()
if not reason:
    reason = "historical unresolved zero-step timeout"
print(json.dumps({
    "reason": reason,
    "match_type": str(latest_zero_step_timeout.get("match_type") or "exact_title"),
    "matched_title": str(latest_zero_step_timeout.get("matched_title") or "").strip(),
}, separators=(",", ":"), sort_keys=True))
PY
}

fallback_planner() {
  local fallback_match_type="${1:-}"
  local fallback_reason="${2:-}"
  local fallback_matched_title="${3:-}"
  local fallback_trigger="${4:-}"
  local data_json guidance_json implementation_step verification_command
  guidance_json="$(task_specific_guidance)"
  implementation_step="$(printf '%s' "$guidance_json" | jq -r '.step // ""')"
  verification_command="$(printf '%s' "$guidance_json" | jq -r '.verification_command // ""')"
  data_json="$(python3 - "$ROOT_DIR" "$TASK" "$implementation_step" "$verification_command" "$fallback_match_type" "$fallback_reason" "$fallback_matched_title" "$fallback_trigger" <<'PY'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


root_dir = Path(sys.argv[1])
task_text = sys.argv[2]
implementation_step = str(sys.argv[3] or "").strip()
verification_command = str(sys.argv[4] or "").strip()
fallback_match_type = str(sys.argv[5] or "").strip()
fallback_reason = str(sys.argv[6] or "").strip()
fallback_matched_title = str(sys.argv[7] or "").strip()
fallback_trigger = str(sys.argv[8] or "").strip()
TICK = chr(96)


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def normalize_sentence(value: Any) -> str:
    text = normalize_text(value)
    if not text:
        return ""
    return text.rstrip(".") + "."


def behavior_change_task(task_text: str) -> bool:
    normalized = normalize_text(task_text).lower()
    if not normalized:
        return False
    if any(
        token in normalized
        for token in (
            "inventory current",
            "inspect only",
            "read-only",
            "read only",
            "docs",
            "readme",
            "documentation",
            "comment-only",
            "comment only",
            "rename",
            "refactor",
            "cleanup",
            "format",
            "lint",
            "typo",
            "whitespace",
        )
    ):
        return False
    return any(
        token in normalized
        for token in (
            "fix",
            "prevent",
            "ensure",
            "guard",
            "enforce",
            "handle",
            "recover",
            "reconcile",
            "retry",
            "timeout",
            "queue",
            "approval",
            "approve",
            "route",
            "routing",
            "block",
            "allow",
            "deny",
            "fail",
            "failure",
            "stale",
            "metric",
            "metrics",
            "count",
            "rate",
            "classif",
            "detect",
            "restore",
            "drain",
        )
    )


def inventory_only_step(value: Any) -> bool:
    text = normalize_text(value).lower()
    if not text:
        return False
    return (
        "write one compact inventory artifact" in text
        and "do not implement code changes in the same run" in text
    )


def generated_inventory_artifact(candidate: Any) -> bool:
    normalized = normalize_text(candidate)
    if not normalized.startswith("codex-memory/"):
        return False
    return bool(
        re.fullmatch(
            r"codex-memory/(?:self-improve|strategy)-inventory-[\w./-]+\.md",
            normalized,
        )
    )


def extract_file_scope(*values: Any) -> list[str]:
    files: list[str] = []
    seen: set[str] = set()
    pattern = re.compile(r"[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|html|css|json|md|yaml|yml|toml|xml|gradle)")
    for value in values:
        for candidate in pattern.findall(str(value or "")):
            normalized = normalize_text(candidate)
            if not normalized or normalized in seen or generated_inventory_artifact(normalized):
                continue
            seen.add(normalized)
            files.append(candidate)
            if len(files) >= 3:
                return files
    return files


def quoted_files(files: list[str]) -> str:
    return ", ".join(f"{TICK}{path}{TICK}" for path in files[:3])


def extract_inventory_artifact_path(value: Any) -> str:
    match = re.search(r"\bat\s+([A-Za-z0-9_./-]+\.md)\b", str(value or ""))
    if not match:
        return ""
    return normalize_text(match.group(1))


def test_file_from_context(*values: Any) -> str:
    for candidate in extract_file_scope(*values):
        normalized = normalize_text(candidate).lower()
        if not normalized:
            continue
        filename = Path(normalized).name
        if normalized.startswith("tests/") or any(token in filename for token in ("test", "spec", "smoke")):
            return candidate
    return ""


def build_test_first_step(task_text: str, implementation_step: str, verification_command: str) -> str:
    if inventory_only_step(implementation_step):
        return ""
    if not behavior_change_task(task_text):
        return ""
    test_file = test_file_from_context(verification_command, implementation_step)
    if not test_file:
        return ""
    return (
        f"In {TICK}{test_file}{TICK}, add or update one focused failing or currently missing regression test for: "
        f"{normalize_sentence(task_text)} Expected: the targeted assertion fails before the implementation change or "
        "clearly exposes the missing coverage."
    )


def inventory_anchor_hint(root_dir: Path, implementation_step: str, files: list[str]) -> str:
    artifact_rel = extract_inventory_artifact_path(implementation_step)
    if not artifact_rel:
        return ""

    artifact_path = Path(artifact_rel)
    if not artifact_path.is_absolute():
        artifact_path = root_dir / artifact_path
    if not artifact_path.is_file():
        return ""

    try:
        text = artifact_path.read_text(encoding="utf-8")
    except Exception:
        return ""

    primary_section_match = re.search(r"(?ms)^## Primary edit site\s*(.+?)(?=^## |\Z)", text)
    if not primary_section_match:
        return ""
    primary_section = primary_section_match.group(1)

    file_match = re.search(rf"^- File:\s*{TICK}?(.+?){TICK}?\s*$", primary_section, re.MULTILINE)
    function_match = re.search(rf"^- Function:\s*{TICK}?(.+?){TICK}?\s*$", primary_section, re.MULTILINE)
    branch_match = re.search(rf"^- Narrow branch:\s*{TICK}?(.+?){TICK}?\s*$", primary_section, re.MULTILINE)

    primary_file = normalize_text(file_match.group(1)) if file_match else ""
    normalized_files = {normalize_text(path) for path in files}
    if primary_file and normalized_files and primary_file not in normalized_files:
        return ""

    function_name = normalize_text(function_match.group(1)) if function_match else ""
    branch_name = normalize_text(branch_match.group(1)) if branch_match else ""
    if function_name and branch_name:
        return f" Start with {TICK}{function_name}{TICK} and the {TICK}{branch_name}{TICK} branch."
    if function_name:
        return f" Start with {TICK}{function_name}{TICK}."
    if branch_name:
        return f" Start with the {TICK}{branch_name}{TICK} branch."
    return ""


def concrete_inspection_step(task_text: str, implementation_step: str) -> str:
    files = extract_file_scope(implementation_step, task_text)
    anchor_hint = inventory_anchor_hint(root_dir, implementation_step, files)
    if files:
        return (
            f"Inspect only {quoted_files(files)} and identify the narrowest existing function, branch, or state "
            f"transition that controls: {normalize_sentence(task_text)}{anchor_hint} Expected: name the exact edit location "
            "before making code changes."
        )
    return (
        f"Inspect the current code path most directly related to: {normalize_sentence(task_text)}{anchor_hint} "
        "Expected: identify one existing file and one concrete edit location before making changes."
    )


def derived_implementation_step(task_text: str, implementation_step: str) -> str:
    files = extract_file_scope(implementation_step, task_text)
    if files:
        return (
            f"In {quoted_files(files)}, apply the smallest safe change for: {normalize_sentence(task_text)} "
            "Keep the edit scoped to the location identified in the inspection step."
        )
    return (
        f"Apply the smallest safe change for: {normalize_sentence(task_text)} "
        "Keep the edit scoped to one file and one concrete behavior."
    )


steps = []
test_first_step = build_test_first_step(task_text, implementation_step, verification_command)
if inventory_only_step(implementation_step):
    steps.append(concrete_inspection_step(task_text, implementation_step))
    steps.append(normalize_sentence(implementation_step))
elif implementation_step and implementation_step.lower().startswith("inspect"):
    steps.append(normalize_sentence(implementation_step))
    if test_first_step:
        steps.append(test_first_step)
    steps.append(derived_implementation_step(task_text, implementation_step))
else:
    inspection_step = concrete_inspection_step(task_text, implementation_step)
    steps.append(inspection_step)
    if test_first_step:
        steps.append(test_first_step)
    if implementation_step:
        steps.append(normalize_sentence(implementation_step))
    else:
        steps.append(derived_implementation_step(task_text, implementation_step))

if verification_command:
    tick = chr(96)
    steps.append(f"Run {tick}{verification_command}{tick} and confirm the exact pass/fail outcome.")
else:
    tick = chr(96)
    steps.append(
        f"Verify the change: for shell scripts run {tick}bash -n <file>{tick}, "
        f"for Python run {tick}python3 -c \"import ast; ast.parse(open('<file>').read())\"{tick}, "
        f"for JSON run {tick}python3 -m json.tool <file> > /dev/null{tick}. Report pass/fail."
    )

payload: dict[str, Any] = {"steps": steps}
if fallback_reason or fallback_trigger:
    payload["fallback"] = {
        "trigger": fallback_trigger or "unresolved_zero_step_timeout",
        "match_type": fallback_match_type or "exact_title",
        "reason": fallback_reason,
        "matched_title": fallback_matched_title,
    }

print(json.dumps(payload))
PY
)"
  write_json_file "$OUTPUT_FILE" "success" "Created deterministic fallback plan." "$data_json"
}

planner_prompt_shape_fallback_signal() {
  python3 - "$TASK" <<'PY'
from __future__ import annotations

import json
import re
import sys


task_text = re.sub(r"\s+", " ", str(sys.argv[1] or "").strip())
if not task_text:
    raise SystemExit(0)

task_text = re.sub(r"^\[[^\]]+\]\s*", "", task_text)
words = re.findall(r"[A-Za-z0-9_./:-]+", task_text)
coordination_markers = (
    len(re.findall(r"\band\b", task_text, re.IGNORECASE))
    + len(re.findall(r"\bwith\b", task_text, re.IGNORECASE))
    + task_text.count(",")
    + task_text.count("(")
    + task_text.count(")")
    + task_text.count(";")
)
file_targets = re.findall(r"[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|json|md|yaml|yml|toml|xml|gradle)", task_text)

if len(words) <= 24 and coordination_markers < 3:
    raise SystemExit(0)

reason_parts: list[str] = []
if len(words) > 24:
    reason_parts.append(f"task prompt has {len(words)} words")
if coordination_markers >= 3:
    reason_parts.append(f"task prompt has {coordination_markers} coordination markers")
if file_targets:
    reason_parts.append(f"task prompt already names {min(len(file_targets), 3)} file target(s)")

print(json.dumps({
    "trigger": "oversized_task_prompt",
    "reason": "; ".join(reason_parts) or "task prompt is oversized or multi-clause",
}, separators=(",", ":"), sort_keys=True))
PY
}

planner_inventory_fallback_signal() {
  local guidance_json implementation_step
  guidance_json="$(task_specific_guidance)"
  implementation_step="$(printf '%s' "$guidance_json" | jq -r '.step // ""')"

  python3 - "$implementation_step" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def inventory_only_step(value: Any) -> bool:
    text = normalize_text(value).lower()
    if not text:
        return False
    return (
        "write one compact inventory artifact" in text
        and "do not implement code changes in the same run" in text
    )


implementation_step = str(sys.argv[1] or "")
if not inventory_only_step(implementation_step):
    raise SystemExit(0)

print(json.dumps({
    "trigger": "bounded_learning_inventory",
    "reason": "task is already a bounded inventory-only follow-up with a deterministic artifact target",
}, separators=(",", ":"), sort_keys=True))
PY
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

  python3 - "$OUTPUT_FILE" "$implementation_step" "$verification_command" "$TASK" <<'PY'
from __future__ import annotations

import json
from pathlib import Path
import re
import sys
from typing import Any


path = Path(sys.argv[1])
implementation_step = str(sys.argv[2] or "").strip()
verification_command = str(sys.argv[3] or "").strip()
task_text = str(sys.argv[4] or "").strip()


def normalize_text(value: Any) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())


def is_generic_implementation_step(value: str) -> bool:
    return normalize_text(value).lower().rstrip(".") == "implement the requested change with minimal modifications"


def is_generic_verification_step(value: str) -> bool:
    normalized = normalize_text(value).lower().rstrip(".")
    return normalized == "run a lightweight verification relevant to the task and confirm the outcome"


def behavior_change_task(task_text: str) -> bool:
    normalized = normalize_text(task_text).lower()
    if not normalized:
        return False
    if any(
        token in normalized
        for token in (
            "inventory current",
            "inspect only",
            "read-only",
            "read only",
            "docs",
            "readme",
            "documentation",
            "comment-only",
            "comment only",
            "rename",
            "refactor",
            "cleanup",
            "format",
            "lint",
            "typo",
            "whitespace",
        )
    ):
        return False
    return any(
        token in normalized
        for token in (
            "fix",
            "prevent",
            "ensure",
            "guard",
            "enforce",
            "handle",
            "recover",
            "reconcile",
            "retry",
            "timeout",
            "queue",
            "approval",
            "approve",
            "route",
            "routing",
            "block",
            "allow",
            "deny",
            "fail",
            "failure",
            "stale",
            "metric",
            "metrics",
            "count",
            "rate",
            "classif",
            "detect",
            "restore",
            "drain",
        )
    )


def test_file_from_context(*values: Any) -> str:
    pattern = re.compile(r"[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|json)")
    for value in values:
        for candidate in pattern.findall(str(value or "")):
            normalized = normalize_text(candidate).lower()
            if not normalized:
                continue
            filename = Path(normalized).name
            if normalized.startswith("tests/") or any(token in filename for token in ("test", "spec", "smoke")):
                return candidate
    return ""


def looks_like_test_step(value: str) -> bool:
    normalized = normalize_text(value).lower()
    if not normalized:
        return False
    if normalized.startswith(("run ", "verify", "check", "confirm")):
        return False
    return "test" in normalized and any(token in normalized for token in ("failing", "missing", "regression", "assert"))


def build_test_first_step(task_text: str, implementation_step: str, verification_command: str) -> str:
    if not behavior_change_task(task_text):
        return ""
    test_file = test_file_from_context(verification_command, implementation_step)
    if not test_file:
        return ""
    return (
        f"In `{test_file}`, add or update one focused failing or currently missing regression test for: "
        f"{normalize_text(task_text).rstrip('.')}. Expected: the targeted assertion fails before the implementation "
        "change or clearly exposes the missing coverage."
    )


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
      tick = chr(96)
      updated_steps.append(f"Run {tick}{verification_command}{tick} and confirm the exact pass/fail outcome.")
      changed = True
      continue
    updated_steps.append(candidate)

test_first_step = build_test_first_step(task_text, implementation_step, verification_command)
if (
    test_first_step
    and len(updated_steps) < 6
    and not any(looks_like_test_step(step) for step in updated_steps[:-1])
):
    insert_index = 1 if len(updated_steps) >= 2 else len(updated_steps)
    updated_steps.insert(insert_index, test_first_step)
    changed = True

if not changed:
    raise SystemExit(0)

payload.setdefault("data", {})["steps"] = updated_steps
path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

forced_fallback_signal="$(planner_timeout_fallback_signal || true)"
forced_fallback_reason="$(printf '%s' "$forced_fallback_signal" | jq -r '.reason // ""' 2>/dev/null || true)"
forced_fallback_match_type="$(printf '%s' "$forced_fallback_signal" | jq -r '.match_type // ""' 2>/dev/null || true)"
forced_fallback_matched_title="$(printf '%s' "$forced_fallback_signal" | jq -r '.matched_title // ""' 2>/dev/null || true)"
if [ -n "$(trim_text "$forced_fallback_reason")" ]; then
  if [ "$forced_fallback_match_type" = "lineage" ]; then
    log_msg WARN planner "Using deterministic fallback plan because the same-root or same-objective lineage already has an unresolved zero-step timeout${forced_fallback_matched_title:+ [${forced_fallback_matched_title}]}: $forced_fallback_reason"
  else
    log_msg WARN planner "Using deterministic fallback plan because this exact title already has an unresolved zero-step timeout${forced_fallback_matched_title:+ [${forced_fallback_matched_title}]}: $forced_fallback_reason"
  fi
  fallback_planner "$forced_fallback_match_type" "$forced_fallback_reason" "$forced_fallback_matched_title"
  print_json_file "$OUTPUT_FILE"
  exit 0
fi

prompt_shape_fallback_signal="$(planner_prompt_shape_fallback_signal || true)"
prompt_shape_fallback_reason="$(printf '%s' "$prompt_shape_fallback_signal" | jq -r '.reason // ""' 2>/dev/null || true)"
prompt_shape_fallback_trigger="$(printf '%s' "$prompt_shape_fallback_signal" | jq -r '.trigger // ""' 2>/dev/null || true)"
if [ -n "$(trim_text "$prompt_shape_fallback_reason")" ]; then
  log_msg WARN planner "Using deterministic fallback plan because the task prompt is oversized for provider planning: $prompt_shape_fallback_reason"
  fallback_planner "" "$prompt_shape_fallback_reason" "" "$prompt_shape_fallback_trigger"
  print_json_file "$OUTPUT_FILE"
  exit 0
fi

inventory_fallback_signal="$(planner_inventory_fallback_signal || true)"
inventory_fallback_reason="$(printf '%s' "$inventory_fallback_signal" | jq -r '.reason // ""' 2>/dev/null || true)"
inventory_fallback_trigger="$(printf '%s' "$inventory_fallback_signal" | jq -r '.trigger // ""' 2>/dev/null || true)"
if [ -n "$(trim_text "$inventory_fallback_reason")" ]; then
  log_msg WARN planner "Using deterministic fallback plan because the task is already a bounded inventory-only follow-up: $inventory_fallback_reason"
  fallback_planner "" "$inventory_fallback_reason" "" "$inventory_fallback_trigger"
  print_json_file "$OUTPUT_FILE"
  exit 0
fi

# ─── Hard planning timeout to prevent zero-step timeouts (self-learning fix 2026-03-28) ───
# 91% of timeouts were zero-step (planner consumed full 420s budget).
# Cap planner LLM call to PLANNING_TIMEOUT_SECONDS (90s) so the remaining
# budget is available for actual step execution.
_saved_exec_timeout="${AGENT_EXEC_TIMEOUT_SECONDS:-}"
export AGENT_EXEC_TIMEOUT_SECONDS="${PLANNING_TIMEOUT_SECONDS:-90}"

if ! run_agent_exec planner "$PROJECT_DIR" "$TASK" "$PROMPT" "$OUTPUT_FILE"; then
  # Restore original timeout for subsequent agent calls (coder, reviewer)
  if [ -n "$_saved_exec_timeout" ]; then
    export AGENT_EXEC_TIMEOUT_SECONDS="$_saved_exec_timeout"
  else
    unset AGENT_EXEC_TIMEOUT_SECONDS
  fi
  if provider_exec_requires_abort; then
    log_msg WARN planner "Selected provider $(current_exec_provider) is unavailable: $(provider_exec_failure_reason)"
    provider_unavailable_planner
  else
    log_msg WARN planner "Planner LLM call failed within ${PLANNING_TIMEOUT_SECONDS:-90}s budget; using fallback plan"
    fallback_planner
  fi
else
  # Restore original timeout after successful planning
  if [ -n "$_saved_exec_timeout" ]; then
    export AGENT_EXEC_TIMEOUT_SECONDS="$_saved_exec_timeout"
  else
    unset AGENT_EXEC_TIMEOUT_SECONDS
  fi
fi

if ! validate_agent_json "$OUTPUT_FILE"; then
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

# ─── Step scope validation and character cap (self-learning fix 2026-03-29) ───
# Root cause: 100% of recent failures are review_rejection caused by steps
# exceeding 600 chars. The coder cannot execute overly verbose instructions.
# Fix: hard-cap each step at 600 chars, trim broad scope, limit impl steps.
python3 - "$OUTPUT_FILE" <<'PYSCOPE'
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)

data = payload.get("data")
steps = data.get("steps") if isinstance(data, dict) else None
if not isinstance(steps, list) or len(steps) < 2:
    raise SystemExit(0)

VAGUE_VERBS = re.compile(
    r"\b(implement|build|create|design|set up|develop|establish)\b.*\b(full|complete|comprehensive|entire|all)\b",
    re.IGNORECASE,
)

FILE_PATTERN = re.compile(r"[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|kt|swift|json|yaml|yml|toml|md|xml|gradle)")

# Hard cap: individual steps must not exceed this length.
# Steps over 600 chars cause review_rejection because the coder times out
# trying to parse and execute overly detailed instructions.
MAX_STEP_CHARS = 600

changed = False
trimmed_steps = []

for i, step in enumerate(steps):
    s = str(step)

    # Flag: step mentions 4+ files (too broad for a single coder step)
    files_mentioned = FILE_PATTERN.findall(s)
    if len(files_mentioned) > 3 and i < len(steps) - 1:
        s = re.sub(
            r"((?:[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|kt|swift|json|yaml|yml|toml|md|xml|gradle)[,;\s]*){3})[\w./-]+\.(?:sh|py|js|ts|tsx|jsx|kt|swift|json|yaml|yml|toml|md|xml|gradle).*?(?=\.|$)",
            r"\1",
            s,
        )
        s = s.rstrip(" ,;") + ". Focus on at most 3 files per step."
        changed = True

    # Flag: vague broad language that correlates with timeouts
    if VAGUE_VERBS.search(s) and i < len(steps) - 1:
        s += " SCOPE LIMIT: Touch at most 3 files and keep changes under 100 lines total."
        changed = True

    # Hard cap: truncate overly verbose steps to MAX_STEP_CHARS
    if len(s) > MAX_STEP_CHARS:
        # Find the last sentence boundary before the cap
        truncated = s[:MAX_STEP_CHARS]
        last_period = truncated.rfind(". ")
        last_newline = truncated.rfind("\n")
        cut_point = max(last_period, last_newline)
        if cut_point > MAX_STEP_CHARS // 2:
            s = truncated[:cut_point + 1].rstrip()
        else:
            s = truncated.rstrip()
        if not s.endswith("."):
            s += "."
        changed = True

    trimmed_steps.append(s)

# If plan has more than 4 implementation steps (excl verification), it's too broad
impl_steps = [s for s in trimmed_steps[:-1] if not re.match(r"(?:verify|run |check |confirm )", s, re.IGNORECASE)]
if len(impl_steps) > 4:
    kept = trimmed_steps[:3] + [trimmed_steps[-1]]
    trimmed_steps = kept
    changed = True

if changed:
    payload["data"]["steps"] = trimmed_steps
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PYSCOPE

log_msg INFO planner "Plan saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
