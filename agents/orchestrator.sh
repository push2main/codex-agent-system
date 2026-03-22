#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap orchestrator

PROJECT_DIR="${1:-}"
TASK="${2:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ]; then
  echo "usage: orchestrator.sh <project_dir> <task>" >&2
  exit 2
fi

require_command orchestrator jq
ensure_runtime_dirs
update_restart_needed_status_for_helper_scripts
mkdir -p "$PROJECT_DIR"

PROJECT_NAME="$(basename "$PROJECT_DIR")"
ensure_project_state "$PROJECT_NAME"
PROJECT_MEMORY_FILE="$(project_memory_file "$PROJECT_NAME")"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$RANDOM"
RUN_DIR="$RUNS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"

PLAN_FILE="$RUN_DIR/plan.json"
MEMORY_FILE="$RUN_DIR/memory.txt"
SUMMARY_FILE="$RUN_DIR/result.txt"
TASK_FILE="$RUN_DIR/task.txt"

printf '%s\n' "$TASK" >"$TASK_FILE"
write_status "running" "$PROJECT_NAME" "$TASK" "RUNNING" "run_id=$RUN_ID"
log_msg INFO orchestrator "Starting task for $PROJECT_NAME: $TASK"

START_TIME="$(date +%s)"
BRANCH=""
PR_URL=""
SCORE=0
ATTEMPTS=0
RESULT="FAILURE"
FAILED_STEP_INDEX=0
FAILED_STEP_TEXT=""
FAILURE_TIMESTAMP=""
STEP_COUNT=0
COMPLETED_STEPS=0
TOTAL_SCORE=0
TASK_PROVIDER="$(resolve_task_provider_info "$PROJECT_NAME" "$TASK" | sed -n '1p')"
TASK_PROVIDER="$(normalize_provider_name "$TASK_PROVIDER")"
[ -n "$TASK_PROVIDER" ] || TASK_PROVIDER="codex"

append_task_record() {
  local duration="$1"
  python3 - "$TASK_LOG" "$PROJECT_NAME" "$TASK" "$RESULT" "$ATTEMPTS" "$SCORE" "$BRANCH" "$PR_URL" "$RUN_ID" "$duration" "$TASK_PROVIDER" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, project, task, result, attempts, score, branch, pr_url, run_id, duration, provider = sys.argv[1:]
record = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "project": project,
    "task": task,
    "provider": provider,
    "result": result,
    "attempts": int(attempts or 0),
    "score": int(score or 0),
    "branch": branch,
    "pr_url": pr_url,
    "run_id": run_id,
    "duration_seconds": int(duration or 0),
}
with open(path, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
}

append_memory_notes() {
  local duration="$1"
  {
    printf -- '- %s | task=%s | result=%s | score=%s | attempts=%s | duration=%ss | run=%s\n' "$(now_utc)" "$TASK" "$RESULT" "$SCORE" "$ATTEMPTS" "$duration" "$RUN_ID"
    [ -n "$BRANCH" ] && printf '  branch: %s\n' "$BRANCH"
    [ -n "$PR_URL" ] && printf '  pr: %s\n' "$PR_URL"
    [ -n "$FAILED_STEP_TEXT" ] && printf '  failed_step: %s\n' "$FAILED_STEP_TEXT"
    printf '\n'
  } >>"$PROJECT_MEMORY_FILE"

  {
    printf -- '- %s | project=%s | result=%s | score=%s | attempts=%s | duration=%ss\n' "$(now_utc)" "$PROJECT_NAME" "$RESULT" "$SCORE" "$ATTEMPTS" "$duration"
    printf '  task: %s\n' "$TASK"
    [ -n "$FAILED_STEP_TEXT" ] && printf '  failed_step: %s\n' "$FAILED_STEP_TEXT"
    [ -n "$BRANCH" ] && printf '  branch: %s\n' "$BRANCH"
    [ -n "$PR_URL" ] && printf '  pr: %s\n' "$PR_URL"
    printf '\n'
  } >>"$DECISIONS_FILE"

  {
    printf -- '- %s | %s | %s\n' "$(now_utc)" "$PROJECT_NAME" "$TASK"
    printf '  result: %s\n' "$RESULT"
    printf '  run: %s\n' "$RUN_ID"
    printf '\n'
  } >>"$CONTEXT_FILE"
}

synthesize_agent_failure() {
  local role="$1"
  local output_file="$2"
  local message="$3"
  local status

  case "$role" in
    reviewer) status="retry" ;;
    *) status="fail" ;;
  esac

  write_json_file "$output_file" "$status" "$message" "$(jq -cn --arg role "$role" '{role:$role}')"
}

run_agent_script() {
  local role="$1"
  local script_path="$2"
  local stdout_file="$3"
  local output_file="$4"
  shift 4

  if "$script_path" "$@" >"$stdout_file" 2>&1; then
    if validate_agent_json "$output_file"; then
      return 0
    fi
    log_msg ERROR orchestrator "$role produced invalid JSON; synthesizing failure response"
  else
    local rc=$?
    log_msg ERROR orchestrator "$role exited with code $rc; synthesizing failure response"
  fi

  synthesize_agent_failure "$role" "$output_file" "$role failed unexpectedly."
  return 1
}

finalize_run() {
  local duration
  local final_state
  duration="$(( $(date +%s) - START_TIME ))"
  final_state="failed"

  if [ -n "$(git_repo_root "$PROJECT_DIR")" ]; then
    BRANCH="$(git -C "$(git_repo_root "$PROJECT_DIR")" branch --show-current 2>/dev/null || true)"
  fi

  if [ "$RESULT" = "SUCCESS" ]; then
    local repo_root project_path
    repo_root="$(git_repo_root "$PROJECT_DIR")"
    project_path=""
    if [ -n "$repo_root" ]; then
      project_path="$(relative_path "$PROJECT_DIR" "$repo_root")"
    fi

    if [ -z "$repo_root" ]; then
      log_msg INFO orchestrator "Project is not inside a git repository; skipping commit and push"
    elif commit_project_changes "$PROJECT_DIR" "$TASK"; then
      if [ -n "$BRANCH" ] && [ "$BRANCH" != "main" ] && [ "${AUTO_PUSH_PR:-0}" = "1" ]; then
        PR_URL="$(push_branch_and_create_pr "$PROJECT_DIR" "$BRANCH" "$TASK" || true)"
      else
        log_msg INFO orchestrator "Push and PR creation skipped for the current branch"
      fi
    elif git -C "$repo_root" status --porcelain -- "${project_path:-.}" | grep -q .; then
      RESULT="FAILURE"
      log_msg ERROR orchestrator "Task execution succeeded but git commit automation failed"
    else
      log_msg INFO orchestrator "No git changes remained after task completion"
    fi
  fi

  if [ "$RESULT" = "SUCCESS" ]; then
    final_state="completed"
    notify_ntfy "Codex task succeeded" "$PROJECT_NAME: $TASK" default white_check_mark
  else
    notify_ntfy "Codex task failed" "$PROJECT_NAME: $TASK" high warning
  fi

  append_task_record "$duration"
  compute_provider_stats || true
  append_memory_notes "$duration"
  if [ "$RESULT" = "FAILURE" ]; then
    if [ -z "$FAILURE_TIMESTAMP" ]; then
      FAILURE_TIMESTAMP="$(now_utc)"
    fi
    persist_task_run_context \
      "$PROJECT_NAME" \
      "$TASK" \
      "$RESULT" \
      "$RUN_ID" \
      "$ATTEMPTS" \
      "$SCORE" \
      "$duration" \
      "$STEP_COUNT" \
      "$COMPLETED_STEPS" \
      "$FAILED_STEP_INDEX" \
      "$FAILED_STEP_TEXT" \
      "$PLAN_FILE" \
      "$TASK_PROVIDER" \
      "$FAILURE_TIMESTAMP" || true
  else
    persist_task_run_context \
      "$PROJECT_NAME" \
      "$TASK" \
      "$RESULT" \
      "$RUN_ID" \
      "$ATTEMPTS" \
      "$SCORE" \
      "$duration" \
      "$STEP_COUNT" \
      "$COMPLETED_STEPS" \
      "0" \
      "" \
      "$PLAN_FILE" \
      "$TASK_PROVIDER" \
      "" || true
  fi
  "$ROOT_DIR/agents/learner.sh" "$ROOT_DIR" "$TASK" "$RESULT" "$RUN_DIR" "$PROMPT_RULES_FILE" "$RUN_DIR/learner.json" >"$RUN_DIR/learner.stdout" 2>&1 || log_msg WARN orchestrator "Learner step failed"
  "$ROOT_DIR/agents/safety.sh" "$PROMPT_RULES_FILE" "$RULES_FILE" "$RUN_DIR/safety.json" >"$RUN_DIR/safety.stdout" 2>&1 || log_msg WARN orchestrator "Safety step failed"
  run_memory_index || true

  cat >"$SUMMARY_FILE" <<EOF
result=$RESULT
project=$PROJECT_NAME
task=$TASK
steps=$STEP_COUNT
completed_steps=$COMPLETED_STEPS
attempts=$ATTEMPTS
score=$SCORE
branch=$BRANCH
pr_url=$PR_URL
failed_step_index=$FAILED_STEP_INDEX
run_dir=$(relative_path "$RUN_DIR" "$ROOT_DIR")
duration_seconds=$duration
EOF

  write_status "$final_state" "$PROJECT_NAME" "$TASK" "$RESULT" "run_id=$RUN_ID duration=${duration}s"
  log_msg INFO orchestrator "Completed task for $PROJECT_NAME with result=$RESULT score=$SCORE attempts=$ATTEMPTS steps=$COMPLETED_STEPS/$STEP_COUNT"
  cat "$SUMMARY_FILE"
}

read_memory_context "$PROJECT_NAME" >"$MEMORY_FILE"
run_agent_script planner "$ROOT_DIR/agents/planner.sh" "$RUN_DIR/planner.stdout" "$PLAN_FILE" "$PROJECT_DIR" "$TASK" "$PLAN_FILE" "$MEMORY_FILE" || true

if [ "$(json_get "$PLAN_FILE" '.status')" != "success" ]; then
  log_msg ERROR orchestrator "Planner did not return success; aborting task"
  RESULT="FAILURE"
  finalize_run
  exit 1
fi

STEP_COUNT="$(json_get "$PLAN_FILE" '.data.steps | length')"
if [ "$STEP_COUNT" -lt 1 ] || [ "$STEP_COUNT" -gt 8 ]; then
  log_msg ERROR orchestrator "Planner returned invalid step count: $STEP_COUNT"
  RESULT="FAILURE"
  finalize_run
  exit 1
fi

for index in $(seq 0 $((STEP_COUNT - 1))); do
  step_number=$((index + 1))
  step_text="$(jq -er --argjson idx "$index" '.data.steps[$idx]' "$PLAN_FILE")"
  step_file="$RUN_DIR/step-$step_number.json"
  jq -cn --argjson index "$step_number" --arg text "$step_text" '{index:$index,text:$text}' >"$step_file"

  feedback_file=""
  step_completed=0
  step_score=0

  for attempt in $(seq 1 "$MAX_AGENT_RETRIES"); do
    step_state="running"
    if [ "$attempt" -gt 1 ]; then
      step_state="retrying"
    fi
    ATTEMPTS=$((ATTEMPTS + 1))
    write_status "$step_state" "$PROJECT_NAME" "$TASK" "RUNNING" "step=$step_number/$STEP_COUNT attempt=$attempt"
    log_msg INFO orchestrator "Running step $step_number/$STEP_COUNT attempt $attempt: $step_text"

    coder_file="$RUN_DIR/step-$step_number-coder-$attempt.json"
    reviewer_file="$RUN_DIR/step-$step_number-reviewer-$attempt.json"
    evaluator_file="$RUN_DIR/step-$step_number-evaluator-$attempt.json"
    feedback_next="$RUN_DIR/step-$step_number-feedback-$attempt.json"

    run_agent_script coder "$ROOT_DIR/agents/coder.sh" "$RUN_DIR/step-$step_number-coder-$attempt.stdout" "$coder_file" "$PROJECT_DIR" "$TASK" "$step_file" "$PLAN_FILE" "$MEMORY_FILE" "$feedback_file" "$coder_file" || true
    run_agent_script reviewer "$ROOT_DIR/agents/reviewer.sh" "$RUN_DIR/step-$step_number-reviewer-$attempt.stdout" "$reviewer_file" "$PROJECT_DIR" "$TASK" "$step_file" "$PLAN_FILE" "$coder_file" "$reviewer_file" || true
    run_agent_script evaluator "$ROOT_DIR/agents/evaluator.sh" "$RUN_DIR/step-$step_number-evaluator-$attempt.stdout" "$evaluator_file" "$PROJECT_DIR" "$TASK" "$step_file" "$PLAN_FILE" "$reviewer_file" "$evaluator_file" || true

    jq -cn \
      --slurpfile coder "$coder_file" \
      --slurpfile review "$reviewer_file" \
      --slurpfile evaluation "$evaluator_file" \
      '{coder:$coder[0],review:$review[0],evaluation:$evaluation[0]}' >"$feedback_next"
    feedback_file="$feedback_next"

    coder_status="$(json_get "$coder_file" '.status')"
    review_status="$(json_get "$reviewer_file" '.status')"
    evaluation_status="$(json_get "$evaluator_file" '.status')"
    step_score="$(json_get "$evaluator_file" '.data.score // 0')"

    log_msg INFO orchestrator "Step $step_number attempt $attempt statuses: coder=$coder_status reviewer=$review_status evaluator=$evaluation_status score=$step_score"

    if [ "$review_status" != "approved" ]; then
      log_msg WARN orchestrator "Reviewer requested retry for step $step_number attempt $attempt"
      continue
    fi

    if [ "$evaluation_status" = "fail" ]; then
      log_msg WARN orchestrator "Evaluator failed step $step_number attempt $attempt"
      continue
    fi

    step_completed=1
    COMPLETED_STEPS=$((COMPLETED_STEPS + 1))
    TOTAL_SCORE=$((TOTAL_SCORE + step_score))
    break
  done

  if [ "$step_completed" -ne 1 ]; then
    FAILED_STEP_INDEX="$step_number"
    FAILED_STEP_TEXT="$step_text"
    FAILURE_TIMESTAMP="$(now_utc)"
    RESULT="FAILURE"
    log_msg ERROR orchestrator "Step $step_number failed after $MAX_AGENT_RETRIES attempt(s)"
    finalize_run
    exit 1
  fi
done

RESULT="SUCCESS"
if [ "$COMPLETED_STEPS" -gt 0 ]; then
  SCORE=$((TOTAL_SCORE / COMPLETED_STEPS))
fi

finalize_run
exit 0
