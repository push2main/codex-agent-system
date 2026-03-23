#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap queue-worker

LANE_ID="${1:-}"
PROJECT_DIR="${2:-}"
PROJECT_NAME="${3:-}"
TASK="${4:-}"
RETRY_COUNT="${5:-0}"
TASK_PROVIDER="${6:-codex}"
LEASE_ID="${7:-}"
TASK_ID="${8:-}"

if [ -z "$LANE_ID" ] || [ -z "$PROJECT_DIR" ] || [ -z "$PROJECT_NAME" ] || [ -z "$TASK" ]; then
  echo "usage: queue-worker.sh <lane_id> <project_dir> <project_name> <task> [retry_count] [provider] [lease_id] [task_id]" >&2
  exit 2
fi

require_command queue-worker python3
ensure_runtime_dirs

resolved_timeout="$(resolve_task_timeout_seconds "$PROJECT_NAME" "$TASK" "$TASK_TIMEOUT_SECONDS" 2>/dev/null || printf '%s' "$TASK_TIMEOUT_SECONDS")"
write_status "running" "$PROJECT_NAME" "$TASK" "RUNNING" "lane=$LANE_ID retry=$RETRY_COUNT timeout=${resolved_timeout}s"

if python3 "$ROOT_DIR/scripts/run-with-timeout.py" "$resolved_timeout" bash "$ROOT_DIR/agents/orchestrator.sh" "$PROJECT_DIR" "$TASK" "$TASK_ID"; then
  clear_task_retry_count "$PROJECT_NAME" "$TASK"
  sync_task_registry_execution_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "completed" \
    "execute_success" \
    "Queue execution completed successfully." \
    "$((RETRY_COUNT + 1))" \
    "$MAX_AGENT_RETRIES" \
    "$TASK_PROVIDER" \
    "$LANE_ID" \
    "" \
    "0" \
    "$TASK_ID" || true
  log_msg INFO queue-worker "Task completed on $LANE_ID for $PROJECT_NAME"
  exit 0
else
  rc=$?
fi

next_retry=$((RETRY_COUNT + 1))
if [ "$rc" -eq 124 ]; then
  timeout_run_id="queue-timeout-${LANE_ID}-$(date -u +%Y%m%dT%H%M%SZ)"
  append_task_log_record \
    "$PROJECT_NAME" \
    "$TASK" \
    "FAILURE" \
    "$next_retry" \
    "0" \
    "" \
    "" \
    "$timeout_run_id" \
    "$resolved_timeout" \
    "$TASK_PROVIDER" \
    "timeout"
  compute_provider_stats || true
  log_msg ERROR queue-worker "Task timed out after ${resolved_timeout}s on $LANE_ID for $PROJECT_NAME"
  notify_ntfy "Codex task timed out" "$PROJECT_NAME: $TASK" high alarm_clock
else
  log_msg ERROR queue-worker "Task failed on $LANE_ID for $PROJECT_NAME with exit code $rc"
fi

if [ "$next_retry" -lt "$MAX_AGENT_RETRIES" ]; then
  local_queue_file="$QUEUE_DIR/$PROJECT_NAME.txt"
  set_task_retry_count "$PROJECT_NAME" "$TASK" "$next_retry"
  printf '%s\n' "$TASK" >>"$local_queue_file"
  sync_task_registry_execution_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "approved" \
    "execute_retry" \
    "Queue execution failed and was requeued for another attempt." \
    "$next_retry" \
    "$MAX_AGENT_RETRIES" \
    "$TASK_PROVIDER" \
    "$LANE_ID" \
    "" \
    "0" \
    "$TASK_ID" || true
  log_msg WARN queue-worker "Requeued task on $LANE_ID for $PROJECT_NAME after failure (retry=$next_retry/$((MAX_AGENT_RETRIES - 1)))"
  write_status "retrying" "$PROJECT_NAME" "$TASK" "FAILURE" "lane=$LANE_ID task_requeued=1 retry=$next_retry/$MAX_AGENT_RETRIES"
  exit 1
fi

clear_task_retry_count "$PROJECT_NAME" "$TASK"
sync_task_registry_execution_state \
  "$PROJECT_NAME" \
  "$TASK" \
  "failed" \
  "execute_failure" \
  "Queue execution failed after exhausting retries." \
  "$next_retry" \
  "$MAX_AGENT_RETRIES" \
  "$TASK_PROVIDER" \
  "$LANE_ID" \
  "" \
  "0" \
  "$TASK_ID" || true
log_msg ERROR queue-worker "Skipping task on $LANE_ID for $PROJECT_NAME after exhausting queue retries"
write_status "failed" "$PROJECT_NAME" "$TASK" "FAILURE" "lane=$LANE_ID task_skipped=1 retries=$next_retry/$MAX_AGENT_RETRIES"
exit 1
