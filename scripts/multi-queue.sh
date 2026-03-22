#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap queue

MODE="${1:-daemon}"
POLL_SECONDS="${QUEUE_POLL_SECONDS:-3}"
QUEUE_WORKERS_VALUE="${QUEUE_WORKERS:-2}"

if [ "$QUEUE_WORKERS_VALUE" -lt 1 ] 2>/dev/null; then
  QUEUE_WORKERS_VALUE=1
elif [ "$QUEUE_WORKERS_VALUE" -gt 2 ] 2>/dev/null; then
  QUEUE_WORKERS_VALUE=2
fi

require_command queue python3
ensure_runtime_dirs
sync_task_artifacts >/dev/null 2>&1 || log_msg WARN queue "Task artifact sync failed before queue processing"
log_msg INFO queue "Queue processor started in $MODE mode"
WORKER_LANE_1_PID=""
WORKER_LANE_1_PROJECT=""
WORKER_LANE_1_TASK=""
WORKER_LANE_1_STDOUT=""
WORKER_LANE_2_PID=""
WORKER_LANE_2_PROJECT=""
WORKER_LANE_2_TASK=""
WORKER_LANE_2_STDOUT=""

current_last_result() {
  awk -F= '$1=="last_result" { print $2 }' "$STATUS_FILE" 2>/dev/null || true
}

status_field_value() {
  local field_name="$1"
  awk -v field_name="$field_name" '
    index($0, field_name "=") == 1 {
      print substr($0, length(field_name) + 2)
      exit
    }
  ' "$STATUS_FILE" 2>/dev/null || true
}

pause_for_codex_auth_failure() {
  local failure_file reason pause_note current_state current_note
  failure_file="$(codex_auth_failure_file)"

  if [ "$(codex_auth_failure_cooldown_active "$failure_file")" != "1" ]; then
    return 1
  fi

  reason="$(read_codex_auth_failure_reason "$failure_file" || true)"
  if recover_codex_runtime_auth_if_available "$failure_file" "$reason"; then
    log_msg INFO queue "Recovered Codex runtime auth from shared home; resuming queue execution"
    return 1
  fi

  pause_note="waiting_for_codex_auth"
  if [ -n "$reason" ]; then
    pause_note="$pause_note reason: $reason"
  fi

  current_state="$(status_field_value "state")"
  current_note="$(status_field_value "note")"
  if [ "$current_state" != "blocked" ] || [ "$current_note" != "$pause_note" ]; then
    log_msg WARN queue "Queue execution paused because Codex authentication is unavailable${reason:+: $reason}"
    write_status "blocked" "" "" "DEGRADED" "$pause_note"
  fi

  return 0
}

lane_pid() {
  case "${1:-}" in
    lane-1) printf '%s\n' "$WORKER_LANE_1_PID" ;;
    lane-2) printf '%s\n' "$WORKER_LANE_2_PID" ;;
    *) printf '\n' ;;
  esac
}

set_lane_state() {
  local lane_id="$1"
  local pid="$2"
  local project="$3"
  local task="$4"
  local stdout_file="$5"
  case "$lane_id" in
    lane-1)
      WORKER_LANE_1_PID="$pid"
      WORKER_LANE_1_PROJECT="$project"
      WORKER_LANE_1_TASK="$task"
      WORKER_LANE_1_STDOUT="$stdout_file"
      ;;
    lane-2)
      WORKER_LANE_2_PID="$pid"
      WORKER_LANE_2_PROJECT="$project"
      WORKER_LANE_2_TASK="$task"
      WORKER_LANE_2_STDOUT="$stdout_file"
      ;;
  esac
}

lane_project() {
  case "${1:-}" in
    lane-1) printf '%s\n' "$WORKER_LANE_1_PROJECT" ;;
    lane-2) printf '%s\n' "$WORKER_LANE_2_PROJECT" ;;
    *) printf '\n' ;;
  esac
}

lane_task() {
  case "${1:-}" in
    lane-1) printf '%s\n' "$WORKER_LANE_1_TASK" ;;
    lane-2) printf '%s\n' "$WORKER_LANE_2_TASK" ;;
    *) printf '\n' ;;
  esac
}

clear_lane_state() {
  case "${1:-}" in
    lane-1)
      WORKER_LANE_1_PID=""
      WORKER_LANE_1_PROJECT=""
      WORKER_LANE_1_TASK=""
      WORKER_LANE_1_STDOUT=""
      ;;
    lane-2)
      WORKER_LANE_2_PID=""
      WORKER_LANE_2_PROJECT=""
      WORKER_LANE_2_TASK=""
      WORKER_LANE_2_STDOUT=""
      ;;
  esac
}

claim_and_launch_task() {
  local lane_id="$1"
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
    ensure_project_state "$project_name"
    local project_dir
    project_dir="$(resolve_project_workspace "$project_name")"
    local retry_count
    retry_count="$(get_task_retry_count "$project_name" "$task")"
    local task_provider
    task_provider="$(resolve_task_provider_info "$project_name" "$task" | sed -n '1p')"
    task_provider="$(normalize_provider_name "$task_provider")"
    [ -n "$task_provider" ] || task_provider="codex"
    mkdir -p "$project_dir"

    # Attempt to claim a lease for this task on the target lane
    local lease_json lease_id
    if ! lease_json="$(claim_task_lease "$project_name" "$task" "$lane_id" 2>/dev/null)"; then
      log_msg INFO queue "Lease conflict for $project_name on $lane_id, skipping: $task"
      continue
    fi
    lease_id="$(printf '%s' "$lease_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("lease_id",""))')"
    if [ -z "$lease_id" ]; then
      log_msg WARN queue "Lease claim returned empty lease_id for $project_name on $lane_id, skipping: $task"
      continue
    fi

    remove_first_task_from_queue "$queue_file"
    write_status "running" "$project_name" "$task" "RUNNING" "lane=$lane_id queue_file=$(basename "$queue_file") retry=$retry_count lease_id=$lease_id"
    log_msg INFO queue "Dequeued task for $project_name on $lane_id: $task (retry=$retry_count lease_id=$lease_id)"
    sync_task_registry_execution_state \
      "$project_name" \
      "$task" \
      "running" \
      "execute_start" \
      "Queue execution started." \
      "$((retry_count + 1))" \
      "$MAX_AGENT_RETRIES" \
      "$task_provider" \
      "$lane_id" || true

    local stdout_file
    stdout_file="$LOG_DIR/queue-worker-$lane_id.stdout"
    : >"$stdout_file"
    bash "$ROOT_DIR/scripts/queue-worker.sh" \
      "$lane_id" \
      "$project_dir" \
      "$project_name" \
      "$task" \
      "$retry_count" \
      "$task_provider" \
      "$lease_id" >"$stdout_file" 2>&1 &
    set_lane_state "$lane_id" "$!" "$project_name" "$task" "$stdout_file"
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

process_next_task_once() {
  local lane_id="lane-1"
  if ! claim_and_launch_task "$lane_id"; then
    return 1
  fi
  wait "$(lane_pid "$lane_id")" || true
  sync_task_artifacts >/dev/null 2>&1 || log_msg WARN queue "Task artifact sync failed after processing $(lane_project "$lane_id"): $(lane_task "$lane_id")"
  clear_lane_state "$lane_id"
  return 0
}

active_worker_count() {
  local count=0 lane_id pid
  for lane_id in "lane-1" "lane-2"; do
    pid="$(lane_pid "$lane_id")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

reap_finished_workers() {
  local lane_id pid
  for lane_id in "lane-1" "lane-2"; do
    pid="$(lane_pid "$lane_id")"
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    wait "$pid" || true
    sync_task_artifacts >/dev/null 2>&1 || log_msg WARN queue "Task artifact sync failed after processing $(lane_project "$lane_id"): $(lane_task "$lane_id")"
    clear_lane_state "$lane_id"
  done
}

fill_available_worker_lanes() {
  local spawned=0 lane_id
  for lane_id in "lane-1" "lane-2"; do
    [ "$lane_id" = "lane-2" ] && [ "$QUEUE_WORKERS_VALUE" -lt 2 ] && continue
    if [ -n "$(lane_pid "$lane_id")" ] && kill -0 "$(lane_pid "$lane_id")" 2>/dev/null; then
      continue
    fi
    if claim_and_launch_task "$lane_id"; then
      spawned=1
    fi
  done
  if [ "$spawned" -eq 1 ]; then
    return 0
  fi
  return 1
}

while true; do
  reap_finished_workers

  if pause_for_codex_auth_failure; then
    if [ "$MODE" = "--once" ]; then
      break
    fi
    sleep "$POLL_SECONDS"
    continue
  fi

  if [ "$MODE" = "--once" ]; then
    if process_next_task_once; then
      :
    else
      write_status "idle" "" "" "$(current_last_result | sed 's/^$/NONE/')" "waiting_for_tasks=1"
    fi
  elif fill_available_worker_lanes; then
    :
  else
    if [ "$(active_worker_count)" -eq 0 ]; then
      write_status "idle" "" "" "$(current_last_result | sed 's/^$/NONE/')" "waiting_for_tasks=1"
    fi
    sleep "$POLL_SECONDS"
  fi

  if [ "$MODE" = "--once" ]; then
    break
  fi
done
