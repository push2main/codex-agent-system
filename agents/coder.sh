#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap coder

PROJECT_DIR="${1:-}"
TASK="${2:-}"
STEP_FILE="${3:-}"
PLAN_FILE="${4:-}"
MEMORY_FILE="${5:-}"
FEEDBACK_FILE="${6:-}"
OUTPUT_FILE="${7:-$LOG_DIR/coder-latest.json}"
TASK_CONTEXT_ID="${TASK_ID:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ] || [ -z "$STEP_FILE" ] || [ -z "$PLAN_FILE" ]; then
  require_command coder jq
  jq -cn \
    --arg status "fail" \
    --arg message "usage: coder.sh <project_dir> <task> <step_file> <plan_file> [memory_file] [feedback_file] [output_file]" \
    '{status:$status,message:$message,data:{}}'
  exit 2
fi

require_command coder jq
ensure_runtime_dirs
mkdir -p "$PROJECT_DIR" "$(dirname "$OUTPUT_FILE")"

STEP_TEXT="$(json_get "$STEP_FILE" '.text')"
STEP_INDEX="$(json_get "$STEP_FILE" '.index')"
PLAN_JSON="$(safe_read_file "$PLAN_FILE")"
MEMORY_TEXT="$(if [ -n "$MEMORY_FILE" ] && [ -f "$MEMORY_FILE" ]; then safe_read_file "$MEMORY_FILE"; else read_memory_context "$(basename "$PROJECT_DIR")" "$TASK $STEP_TEXT"; fi)"
MEMORY_TEXT="$(truncate_context_to_budget "$MEMORY_TEXT" 4000)"
FEEDBACK_TEXT="$(if [ -n "$FEEDBACK_FILE" ] && [ -f "$FEEDBACK_FILE" ]; then safe_read_file "$FEEDBACK_FILE"; else printf 'null'; fi)"
FEEDBACK_TEXT="$(truncate_context_to_budget "$FEEDBACK_TEXT" 3000)"
SOURCE_CONTEXT="$(build_prompt_source_context "$TASK" "$STEP_TEXT" "$(basename "$PROJECT_DIR")")"
SOURCE_CONTEXT="$(truncate_context_to_budget "$SOURCE_CONTEXT" 4000)"
SIMILAR_TASKS="$(build_similar_task_context "$TASK $STEP_TEXT" "$(basename "$PROJECT_DIR")" "$TASK_CONTEXT_ID")"
SIMILAR_TASKS="$(truncate_context_to_budget "$SIMILAR_TASKS" 3000)"
VERIFICATION_GUIDANCE="$(build_verification_guidance "$TASK" "$STEP_TEXT" "$(basename "$PROJECT_DIR")" "$TASK_CONTEXT_ID")"
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
    lines.append("- Use this metadata to keep the implementation bounded to the approved execution surface instead of broadening the queue title.")
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

# Directories to skip — contain ephemeral files (leases, locks, logs)
SKIP_DIRS = {"codex-logs", ".git", "node_modules", "__pycache__", ".codex-agent"}
SKIP_SUFFIXES = (".lock", ".tmp", ".pid")

records: list[str] = []
for path in sorted(item for item in root.rglob("*") if item.is_file()):
    # Skip files in ephemeral directories
    parts = path.relative_to(root).parts
    if any(part in SKIP_DIRS for part in parts):
        continue
    # Skip ephemeral file types
    if any(path.name.endswith(suffix) for suffix in SKIP_SUFFIXES):
        continue
    try:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        records.append(f"{path.relative_to(root)}:{digest}")
    except (FileNotFoundError, PermissionError, OSError):
        # File was deleted between listing and reading (race condition)
        continue

print("\n".join(records) if records else "EMPTY")
PY
}

build_payload() {
  local status="$1"
  local message="$2"
  local summary="$3"
  local files_json="${4:-[]}"
  local checks_json="${5:-[]}"
  local changed_json="${6:-false}"
  local step_override="${7:-$STEP_TEXT}"
  local data_json
  data_json="$(jq -cn \
    --arg step "$step_override" \
    --argjson index "$STEP_INDEX" \
    --arg kind "$STEP_KIND" \
    --arg summary "$summary" \
    --argjson files "$files_json" \
    --argjson checks "$checks_json" \
    --argjson changed "$changed_json" \
    '{step:$step,index:$index,kind:$kind,summary:$summary,files:$files,checks:$checks,changed:$changed}')"
  write_json_file "$OUTPUT_FILE" "$status" "$message" "$data_json"
}

target_language() {
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
  if [[ "$combined" == *"shell"* ]] || [[ "$combined" == *"bash"* ]]; then
    printf 'shell\n'
    return 0
  fi
  if [[ "$combined" == *"hello world"* ]]; then
    printf 'shell\n'
    return 0
  fi
  printf 'markdown\n'
}

implementation_target_file() {
  case "$(target_language)" in
    python) printf '%s/hello.py\n' "$PROJECT_DIR" ;;
    javascript) printf '%s/hello.js\n' "$PROJECT_DIR" ;;
    shell) printf '%s/hello.sh\n' "$PROJECT_DIR" ;;
    *) printf '%s/TASK_RESPONSE.md\n' "$PROJECT_DIR" ;;
  esac
}

is_generic_implementation_step() {
  local normalized_step
  normalized_step="$(printf '%s' "$STEP_TEXT" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  [ "$normalized_step" = "implement the requested change with minimal modifications." ] || \
    [ "$normalized_step" = "implement the requested change with minimal modifications" ]
}

fallback_task_specific_guidance() {
  python3 - "$TASK" "$SIMILAR_TASKS" "$VERIFICATION_GUIDANCE" "$FEEDBACK_TEXT" <<'PY'
from __future__ import annotations

import json
import re
import sys
from typing import Any


task_text = sys.argv[1]
similar_raw = sys.argv[2]
verification_guidance = sys.argv[3]
feedback_raw = sys.argv[4]


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


def parse_json(value: str) -> Any:
    try:
        return json.loads(value)
    except Exception:
        return None


def feedback_command_from_lines(lines: Any, prefix: str) -> str:
    if not isinstance(lines, list):
        return ""
    for line in lines:
        normalized = normalize_text(line)
        if normalized.startswith(prefix):
            return normalize_text(normalized[len(prefix) :])
    return ""


def feedback_guidance(feedback: Any) -> dict[str, str]:
    if not isinstance(feedback, dict):
        return {"step": "", "verification_command": ""}

    review = feedback.get("review")
    if isinstance(review, dict):
        review_data = review.get("data")
        retry_step = normalize_text(review_data.get("step")) if isinstance(review_data, dict) else ""
        if retry_step and not is_generic_implementation_step(retry_step):
            return {
                "step": retry_step.rstrip(".") + ".",
                "verification_command": feedback_command_from_lines(
                    review_data.get("findings") if isinstance(review_data, dict) else [],
                    "Use the preferred verification command: ",
                ),
            }

    evaluation = feedback.get("evaluation")
    if isinstance(evaluation, dict):
        evaluation_data = evaluation.get("data")
        retry_step = normalize_text(evaluation_data.get("step")) if isinstance(evaluation_data, dict) else ""
        if retry_step and not is_generic_implementation_step(retry_step):
            return {
                "step": retry_step.rstrip(".") + ".",
                "verification_command": extract_command(
                    normalize_text(evaluation_data.get("reason")) if isinstance(evaluation_data, dict) else ""
                ),
            }

    coder = feedback.get("coder")
    if isinstance(coder, dict):
        coder_data = coder.get("data")
        retry_step = normalize_text(coder_data.get("step")) if isinstance(coder_data, dict) else ""
        if retry_step and not is_generic_implementation_step(retry_step):
            return {
                "step": retry_step.rstrip(".") + ".",
                "verification_command": feedback_command_from_lines(
                    coder_data.get("checks") if isinstance(coder_data, dict) else [],
                    "Preferred verification command: ",
                ),
            }

    return {"step": "", "verification_command": ""}


def failed_step_from_task(task: dict[str, Any]) -> str:
    for context_key in ("failure_context", "execution_context"):
        context = task.get(context_key)
        if not isinstance(context, dict):
            continue
        candidate = normalize_text(context.get("failed_step"))
        if candidate and not is_generic_implementation_step(candidate):
            return candidate.rstrip(".") + "."
    return ""


def verification_command_from_task(task: dict[str, Any]) -> str:
    execution_brief = task.get("execution_brief")
    if isinstance(execution_brief, dict):
        candidate = normalize_text(execution_brief.get("frozen_verify_command"))
        if candidate:
            return candidate
    task_shape = task.get("task_shape")
    if isinstance(task_shape, dict):
        candidate = normalize_text(task_shape.get("verification_command"))
        if candidate:
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
feedback = parse_json(feedback_raw)

task_key = normalize_key(task_text)
selected_task: dict[str, Any] | None = None
selected_score: tuple[Any, ...] | None = None

for candidate in similar_tasks:
    if not isinstance(candidate, dict):
        continue
    failed_step = failed_step_from_task(candidate)
    intent_step = intent_implementation_step(candidate, task_text)
    score = (
        1 if candidate.get("current_task") is True else 0,
        1 if failed_step and step_kind(failed_step) != "verify" else 0,
        1 if exact_match(candidate, task_key) else 0,
        1 if failed_step else 0,
        1 if intent_step else 0,
        normalize_text(candidate.get("updated_at") or candidate.get("created_at")),
    )
    if selected_score is None or score > selected_score:
        selected_task = candidate
        selected_score = score

feedback_choice = feedback_guidance(feedback)
implementation_step = feedback_choice.get("step") or failed_step_from_task(selected_task or {})
if not implementation_step:
    implementation_step = intent_implementation_step(selected_task or {}, task_text)

verification_command = feedback_choice.get("verification_command") or ""
if not verification_command:
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

run_verification_fallback() {
  local target_file command_text output_text files_json checks_json

  if [ -f "$PROJECT_DIR/hello.py" ]; then
    if ! command -v python3 >/dev/null 2>&1; then
      build_payload "fail" "python3 is unavailable for verification." "Verification could not run because python3 is not installed." "[]" '["python3 is required to verify hello.py."]' "false"
      return 0
    fi
    target_file="$PROJECT_DIR/hello.py"
    command_text="python3 hello.py"
    if ! output_text="$(cd "$PROJECT_DIR" && python3 hello.py 2>&1)"; then
      build_payload "fail" "Verification command failed." "The verification command for hello.py exited with an error." "$(jq -cn --arg file "$(relative_path "$target_file" "$ROOT_DIR")" '[ $file ]')" "$(jq -cn --arg command "$command_text" --arg output "$output_text" '[ "Executed " + $command, "Command output: " + $output ]')" "false"
      return 0
    fi
  elif [ -f "$PROJECT_DIR/hello.js" ] && command -v node >/dev/null 2>&1; then
    target_file="$PROJECT_DIR/hello.js"
    command_text="node hello.js"
    if ! output_text="$(cd "$PROJECT_DIR" && node hello.js 2>&1)"; then
      build_payload "fail" "Verification command failed." "The verification command for hello.js exited with an error." "$(jq -cn --arg file "$(relative_path "$target_file" "$ROOT_DIR")" '[ $file ]')" "$(jq -cn --arg command "$command_text" --arg output "$output_text" '[ "Executed " + $command, "Command output: " + $output ]')" "false"
      return 0
    fi
  elif [ -f "$PROJECT_DIR/hello.sh" ]; then
    target_file="$PROJECT_DIR/hello.sh"
    command_text="bash hello.sh"
    if ! output_text="$(cd "$PROJECT_DIR" && bash hello.sh 2>&1)"; then
      build_payload "fail" "Verification command failed." "The verification command for hello.sh exited with an error." "$(jq -cn --arg file "$(relative_path "$target_file" "$ROOT_DIR")" '[ $file ]')" "$(jq -cn --arg command "$command_text" --arg output "$output_text" '[ "Executed " + $command, "Command output: " + $output ]')" "false"
      return 0
    fi
  else
    build_payload "fail" "Verification fallback could not find a runnable artifact." "No runnable file was available for verification." "[]" '["No verification command could be run."]' "false"
    return 0
  fi

  if [ "$output_text" != "Hello, World!" ] && [ "$output_text" != "Hello, World!"$'\r' ]; then
    build_payload "fail" "Verification command completed with unexpected output." "Verification ran but the output did not match the expected hello world string." "$(jq -cn --arg file "$(relative_path "$target_file" "$ROOT_DIR")" '[ $file ]')" "$(jq -cn --arg command "$command_text" --arg output "$output_text" '[ "Executed " + $command, "Observed output: " + $output ]')" "false"
    return 0
  fi

  files_json="$(jq -cn --arg file "$(relative_path "$target_file" "$ROOT_DIR")" '[ $file ]')"
  checks_json="$(jq -cn --arg command "$command_text" '[ "Executed " + $command + " successfully." ]')"
  build_payload "success" "Verification fallback completed successfully." "Ran the lightweight verification step successfully." "$files_json" "$checks_json" "false"
}

implement_fallback() {
  local target_file check_note files_json checks_json guidance_json bounded_step verification_command
  guidance_json="$(fallback_task_specific_guidance)"
  bounded_step="$(printf '%s' "$guidance_json" | jq -r '.step // ""')"
  verification_command="$(printf '%s' "$guidance_json" | jq -r '.verification_command // ""')"

  if is_generic_implementation_step && [ -n "$bounded_step" ]; then
    if [ -n "$verification_command" ]; then
      checks_json="$(jq -cn --arg guidance "$bounded_step" --arg command "$verification_command" '[ "Recovered bounded implementation guidance: " + $guidance, "Preferred verification command: " + $command ]')"
    else
      checks_json="$(jq -cn --arg guidance "$bounded_step" '[ "Recovered bounded implementation guidance: " + $guidance ]')"
    fi
    build_payload "fail" "Fallback implementation requires bounded task-specific execution." "Recovered bounded task guidance and refused to invent a placeholder artifact for a generic implementation step." "[]" "$checks_json" "false" "$bounded_step"
    return 0
  fi

  # For non-trivial tasks, report failure with actionable guidance instead of silently giving up
  local task_lower
  task_lower="$(printf '%s' "$TASK" | tr '[:upper:]' '[:lower:]')"
  if [[ "$task_lower" != *"hello world"* ]] && [[ "$task_lower" != *"hello, world"* ]]; then
    local step_guidance=""
    if [ -n "$bounded_step" ]; then
      step_guidance="Bounded guidance available: $bounded_step"
    fi
    checks_json="$(jq -cn --arg step "$STEP_TEXT" --arg guidance "${step_guidance:-No bounded guidance available.}" '[ "Provider execution failed. Retry needed with live agent: " + $step, $guidance ]')"
    build_payload "fail" "Provider execution failed; live agent retry needed." "Provider timed out or failed. The step needs live agent execution." "[]" "$checks_json" "false"
    return 0
  fi

  target_file="$(implementation_target_file)"

  case "$(target_language)" in
    python)
      cat >"$target_file" <<'EOF'
print("Hello, World!")
EOF
      check_note='python3 hello.py'
      ;;
    javascript)
      cat >"$target_file" <<'EOF'
console.log("Hello, World!");
EOF
      check_note='node hello.js'
      ;;
    shell)
      cat >"$target_file" <<'EOF'
#!/usr/bin/env bash
echo "Hello, World!"
EOF
      chmod +x "$target_file"
      check_note='bash hello.sh'
      ;;
    *)
      checks_json="$(jq -cn --arg step "$STEP_TEXT" '[ "No safe generic fallback is available for this implementation step: " + $step ]')"
      build_payload "fail" "Fallback implementation is unavailable for this step." "Refused to create a placeholder file for a concrete implementation step." "[]" "$checks_json" "false"
      return 0
      ;;
  esac

  files_json="$(jq -cn --arg file "$(relative_path "$target_file" "$ROOT_DIR")" '[ $file ]')"
  checks_json="$(jq -cn --arg check "$check_note" '[ $check ]')"
  build_payload "success" "Fallback implementation completed successfully." "Implemented the smallest safe fallback for the step." "$files_json" "$checks_json" "true"
}

inspect_fallback() {
  local files_json checks_json file_list file_summary
  # Collect file listing with sizes for actionable context
  file_list="$(find "$PROJECT_DIR" -maxdepth 2 -type f -printf '%s %p\n' 2>/dev/null | sort -rn | head -n 15 | sed "s|$ROOT_DIR/||" || find "$PROJECT_DIR" -maxdepth 2 -type f | sed "s|$ROOT_DIR/||" | sort | head -n 15)"
  files_json="$(printf '%s\n' "$file_list" | awk '{print $NF}' | jq -R . | jq -s '.')"
  # Read first 30 lines of the most relevant file to provide actual content
  local target_file=""
  if printf '%s' "$STEP_TEXT" | grep -oP '[A-Za-z0-9_./-]+\.(sh|py|js|json|md|ts)' | head -1 | read -r mentioned_file; then
    if [ -f "$PROJECT_DIR/$mentioned_file" ] || [ -f "$ROOT_DIR/$mentioned_file" ]; then
      target_file="${PROJECT_DIR}/${mentioned_file}"
      [ -f "$target_file" ] || target_file="${ROOT_DIR}/${mentioned_file}"
    fi
  fi
  if [ -n "$target_file" ] && [ -f "$target_file" ]; then
    file_summary="$(head -n 30 "$target_file" 2>/dev/null | head -c 2000)"
    checks_json="$(jq -cn --arg listing "$file_list" --arg preview "$file_summary" --arg file "$target_file" '[ "Project files: " + $listing, "Preview of " + $file + ": " + $preview ]')"
  else
    checks_json="$(jq -cn --arg listing "$file_list" '[ "Project files (by size): " + $listing ]')"
  fi
  build_payload "success" "Inspection step completed with file inventory." "Reviewed the current project files and collected actionable context for the next step." "$files_json" "$checks_json" "false"
}

fallback_coder() {
  case "$STEP_KIND" in
    inspect)
      inspect_fallback
      ;;
    verify)
      run_verification_fallback
      ;;
    *)
      implement_fallback
      ;;
  esac
}

provider_unavailable_coder() {
  local provider reason checks_json
  provider="$(current_exec_provider)"
  reason="$(provider_exec_failure_reason)"
  checks_json="$(jq -cn --arg provider "$provider" --arg reason "$reason" '[ "Selected provider " + $provider + " is unavailable: " + $reason ]')"
  build_payload "fail" "Selected provider is unavailable for coder execution." "Execution stopped before fallback because the assigned provider is unavailable." "[]" "$checks_json" "false"
}

before_fingerprint="$(project_fingerprint)"
EXISTING_FILES="$(find "$PROJECT_DIR" -maxdepth 2 -type f | sed "s|$ROOT_DIR/||" | sort | head -n 50)"
PROMPT="$(cat <<EOF
You are a coder agent in an autonomous system. Execute exactly ONE plan step by modifying files directly.

YOUR TASK FOR THIS STEP:
$STEP_TEXT

OVERALL TASK CONTEXT: $TASK
PROJECT DIRECTORY: $(relative_path "$PROJECT_DIR" "$ROOT_DIR")

FULL PLAN:
$PLAN_JSON

$(if [ -n "$MEMORY_TEXT" ] && [ "$MEMORY_TEXT" != "null" ]; then printf 'PROJECT MEMORY:\n%s\n' "$MEMORY_TEXT"; fi)

$(if [ -n "$CURRENT_TASK_GUIDANCE" ] && [ "$CURRENT_TASK_GUIDANCE" != "null" ]; then printf 'CURRENT TASK SHAPE:\n%s\n' "$CURRENT_TASK_GUIDANCE"; fi)

$(if [ "$FEEDBACK_TEXT" != "null" ] && [ -n "$FEEDBACK_TEXT" ]; then printf 'FEEDBACK FROM PRIOR ATTEMPT (fix the issues listed here):\n%s\n' "$FEEDBACK_TEXT"; fi)

$(if [ -n "$VERIFICATION_GUIDANCE" ] && [ "$VERIFICATION_GUIDANCE" != "null" ]; then printf 'VERIFICATION:\n%s\n' "$VERIFICATION_GUIDANCE"; fi)

$(if [ -n "$SOURCE_CONTEXT" ] && [ "$SOURCE_CONTEXT" != "null" ]; then printf 'RELEVANT SOURCE:\n%s\n' "$SOURCE_CONTEXT"; fi)

CURRENT FILES:
$EXISTING_FILES

$(if [ -n "${CODEX_DOCKER_DELEGATE:-}" ] && [ -x "${CODEX_DOCKER_DELEGATE:-}" ]; then cat <<DOCKER_INSTRUCTIONS
DOCKER ENVIRONMENT AVAILABLE:
This task requires a toolchain (Android SDK/JDK/Gradle) that is NOT installed natively.
A Docker wrapper is available at: $CODEX_DOCKER_DELEGATE
To run any gradle or android build command, prefix it with the wrapper script. Examples:
  $CODEX_DOCKER_DELEGATE ./gradlew assembleDebug
  $CODEX_DOCKER_DELEGATE ./gradlew test
  $CODEX_DOCKER_DELEGATE gradle build
Do NOT attempt to run gradle/gradlew directly — it will fail. Always use the wrapper.
DOCKER_INSTRUCTIONS
fi)

CRITICAL INSTRUCTIONS:
1. Read at least 2 existing files in the project FIRST to understand naming conventions, import patterns, and code style before any changes.
2. If the step mentions creating a new file, check first if a similar file already exists that should be modified instead.
3. Make the EXACT code change described in the step. NEVER create placeholder, stub, or skeleton implementations.
4. Every function must have real logic. If you cannot implement the full logic, return status="fail" and explain exactly what is missing.
5. Write clean, production-quality code that integrates with the existing codebase style.
6. If CURRENT TASK SHAPE lists editable files, do not edit outside those files. Treat frozen files and the frozen verification command as immutable context.
7. VALIDATE after every change:
   - Shell scripts: run "bash -n <file>" to check syntax
   - Python files: run "python3 -c \"import ast; ast.parse(open(\\\"<file>\\\").read())\""
   - JSON files: run "python3 -m json.tool <file> > /dev/null"
   - If validation fails, FIX the error before returning. Do not return status=success with broken code.
8. If the step involves running a command (verification step), actually run it and report the FULL output.
9. If you encounter an error you cannot fix, return status="fail" with a SPECIFIC error message including the exact error text. Never return a vague "failed" message.

Return JSON only:
{
  "status": "success" or "fail",
  "message": "short summary",
  "data": {
    "step": "$STEP_TEXT",
    "index": $STEP_INDEX,
    "kind": "$STEP_KIND",
    "summary": "what changed",
    "files": ["relative/path"],
    "checks": ["command or note"],
    "changed": true
  }
}
EOF
)"

if ! run_agent_exec coder "$PROJECT_DIR" "$TASK" "$PROMPT" "$OUTPUT_FILE"; then
  if provider_exec_requires_abort; then
    log_msg WARN coder "Selected provider $(current_exec_provider) is unavailable: $(provider_exec_failure_reason)"
    provider_unavailable_coder
  else
    fallback_coder
  fi
elif ! validate_agent_json "$OUTPUT_FILE"; then
  log_msg WARN coder "Coder output was not valid JSON; using fallback implementation"
  fallback_coder
elif ! jq -e '
  (.status == "success" or .status == "fail") and
  (.data | type == "object") and
  (.data.summary | type == "string") and
  (.data.files | type == "array") and
  (.data.checks | type == "array") and
  (.data.changed | type == "boolean")
' "$OUTPUT_FILE" >/dev/null 2>&1; then
  log_msg WARN coder "Coder output did not satisfy the deterministic schema; using fallback implementation"
  fallback_coder
fi

after_fingerprint="$(project_fingerprint)"
if [ "$STEP_KIND" = "implement" ] && [ "$before_fingerprint" = "$after_fingerprint" ]; then
  log_msg WARN coder "Implementation step produced no project file changes; using fallback implementation"
  fallback_coder
fi

log_msg INFO coder "Implementation summary saved to $(relative_path "$OUTPUT_FILE" "$ROOT_DIR")"
print_json_file "$OUTPUT_FILE"
