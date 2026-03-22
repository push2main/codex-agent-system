#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap queue

MODE="${1:-daemon}"
POLL_SECONDS="${QUEUE_POLL_SECONDS:-3}"

require_command queue python3
ensure_runtime_dirs
log_msg INFO queue "Queue processor started in $MODE mode"

current_last_result() {
  awk -F= '$1=="last_result" { print $2 }' "$STATUS_FILE" 2>/dev/null || true
}

process_next_task() {
  local queue_file
  local total
  total="$(queue_task_count)"
  if [ "$total" -gt "$QUEUE_LIMIT" ]; then
    log_msg WARN queue "Queue size $total exceeds configured limit $QUEUE_LIMIT; continuing to drain the backlog"
  fi

  shopt -s nullglob
  for queue_file in "$QUEUE_DIR"/*.txt; do
    dedupe_queue_file "$queue_file"
    local task
    task="$(next_task_from_queue "$queue_file")"
    [ -n "$task" ] || continue

    local project_name
    project_name="$(basename "$queue_file" .txt)"
    local project_dir="$PROJECTS_DIR/$project_name"
    mkdir -p "$project_dir"

    remove_first_task_from_queue "$queue_file"
    write_status "RUNNING" "$project_name" "$task" "RUNNING" "queue_file=$(basename "$queue_file")"
    log_msg INFO queue "Dequeued task for $project_name: $task"

    if python3 "$ROOT_DIR/scripts/run-with-timeout.py" "$TASK_TIMEOUT_SECONDS" bash "$ROOT_DIR/agents/orchestrator.sh" "$project_dir" "$task"; then
      log_msg INFO queue "Task completed for $project_name"
    else
      local rc=$?
      if [ "$rc" -eq 124 ]; then
        log_msg ERROR queue "Task timed out after ${TASK_TIMEOUT_SECONDS}s for $project_name"
        notify_ntfy "Codex task timed out" "$project_name: $task" high alarm_clock
      else
        log_msg ERROR queue "Task failed for $project_name with exit code $rc"
      fi
      write_status "IDLE" "$project_name" "" "FAILURE" "last_task_failed=1"
    fi

    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

while true; do
  if process_next_task; then
    :
  else
    write_status "IDLE" "" "" "$(current_last_result | sed 's/^$/IDLE/')" "waiting_for_tasks=1"
    if [ "$MODE" = "--once" ]; then
      break
    fi
    sleep "$POLL_SECONDS"
  fi

  if [ "$MODE" = "--once" ]; then
    break
  fi
done
