#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

PROJECT_DIR="${1:-}"
TASK="${2:-}"

if [ -z "$PROJECT_DIR" ] || [ -z "$TASK" ]; then
  echo "usage: orchestrator.sh <project_dir> <task>" >&2
  exit 2
fi

ensure_runtime_dirs
mkdir -p "$PROJECT_DIR"

PROJECT_NAME="$(basename "$PROJECT_DIR")"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$RANDOM"
RUN_DIR="$RUNS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"

PLAN_FILE="$RUN_DIR/plan.txt"
MEMORY_FILE="$RUN_DIR/memory.txt"
SUMMARY_FILE="$RUN_DIR/result.txt"
TASK_FILE="$RUN_DIR/task.txt"

printf '%s\n' "$TASK" >"$TASK_FILE"
write_status "RUNNING" "$PROJECT_NAME" "$TASK" "RUNNING" "run_id=$RUN_ID"
log_msg INFO orchestrator "Starting task for $PROJECT_NAME: $TASK"

START_TIME="$(date +%s)"
BRANCH=""
PR_URL=""
SCORE=0
ATTEMPTS=0
RESULT="FAILURE"

append_task_record() {
  local duration="$1"
  python3 - "$TASK_LOG" "$PROJECT_NAME" "$TASK" "$RESULT" "$ATTEMPTS" "$SCORE" "$BRANCH" "$PR_URL" "$RUN_ID" "$duration" <<'PY'
import json
import sys
from datetime import datetime, timezone

path, project, task, result, attempts, score, branch, pr_url, run_id, duration = sys.argv[1:]
record = {
    "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "project": project,
    "task": task,
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
    printf -- '- %s | project=%s | result=%s | score=%s | attempts=%s | duration=%ss\n' "$(now_utc)" "$PROJECT_NAME" "$RESULT" "$SCORE" "$ATTEMPTS" "$duration"
    printf '  task: %s\n' "$TASK"
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

if [ -n "$(git_repo_root "$PROJECT_DIR")" ]; then
  BRANCH="$(ensure_task_branch "$PROJECT_DIR" || true)"
fi

run_memory_query "$TASK" 3 >"$MEMORY_FILE" || true
"$ROOT_DIR/agents/planner.sh" "$PROJECT_DIR" "$TASK" "$PLAN_FILE" "$MEMORY_FILE" >"$RUN_DIR/planner.stdout" 2>&1

FEEDBACK_FILE=""
for attempt in 1 2 3; do
  ATTEMPTS="$attempt"
  CODER_FILE="$RUN_DIR/coder-$attempt.txt"
  REVIEW_FILE="$RUN_DIR/reviewer-$attempt.txt"
  EVALUATION_FILE="$RUN_DIR/evaluator-$attempt.txt"
  FEEDBACK_NEXT="$RUN_DIR/feedback-$attempt.txt"

  "$ROOT_DIR/agents/coder.sh" "$PROJECT_DIR" "$TASK" "$PLAN_FILE" "$MEMORY_FILE" "$FEEDBACK_FILE" "$CODER_FILE" >"$RUN_DIR/coder-$attempt.stdout" 2>&1
  "$ROOT_DIR/agents/reviewer.sh" "$PROJECT_DIR" "$TASK" "$PLAN_FILE" "$CODER_FILE" "$REVIEW_FILE" >"$RUN_DIR/reviewer-$attempt.stdout" 2>&1
  "$ROOT_DIR/agents/evaluator.sh" "$PROJECT_DIR" "$TASK" "$PLAN_FILE" "$REVIEW_FILE" "$EVALUATION_FILE" >"$RUN_DIR/evaluator-$attempt.stdout" 2>&1

  cat "$REVIEW_FILE" "$EVALUATION_FILE" >"$FEEDBACK_NEXT"
  FEEDBACK_FILE="$FEEDBACK_NEXT"

  SCORE="$(awk -F': ' '/^SCORE:/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$EVALUATION_FILE")"
  SCORE="${SCORE:-0}"

  if grep -q '^APPROVED' "$REVIEW_FILE" && grep -q '^VERDICT: GOOD' "$EVALUATION_FILE"; then
    RESULT="SUCCESS"
    break
  fi

  log_msg WARN orchestrator "Attempt $attempt failed review or evaluation for $PROJECT_NAME"
done

if [ "$RESULT" = "SUCCESS" ]; then
  if commit_project_changes "$PROJECT_DIR" "$TASK"; then
    if [ -n "$BRANCH" ]; then
      PR_URL="$(push_branch_and_create_pr "$PROJECT_DIR" "$BRANCH" "$TASK" || true)"
    fi
  fi
  notify_ntfy "Codex task succeeded" "$PROJECT_NAME: $TASK" default white_check_mark
else
  notify_ntfy "Codex task failed" "$PROJECT_NAME: $TASK" high warning
fi

DURATION="$(( $(date +%s) - START_TIME ))"
append_task_record "$DURATION"
append_memory_notes "$DURATION"
"$ROOT_DIR/agents/learner.sh" "$ROOT_DIR" "$TASK" "$RESULT" "$RUN_DIR" "$RULES_CANDIDATE_FILE" >"$RUN_DIR/learner.stdout" 2>&1 || true
"$ROOT_DIR/agents/safety.sh" "$RULES_CANDIDATE_FILE" "$RULES_FILE" >"$RUN_DIR/safety.stdout" 2>&1 || true
run_memory_index

cat >"$SUMMARY_FILE" <<EOF
result=$RESULT
project=$PROJECT_NAME
task=$TASK
attempts=$ATTEMPTS
score=$SCORE
branch=$BRANCH
pr_url=$PR_URL
run_dir=$(relative_path "$RUN_DIR" "$ROOT_DIR")
duration_seconds=$DURATION
EOF

write_status "IDLE" "$PROJECT_NAME" "" "$RESULT" "run_id=$RUN_ID duration=${DURATION}s"
log_msg INFO orchestrator "Completed task for $PROJECT_NAME with result=$RESULT score=$SCORE attempts=$ATTEMPTS"
cat "$SUMMARY_FILE"

if [ "$RESULT" = "SUCCESS" ]; then
  exit 0
fi

exit 1
