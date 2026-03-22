#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap queue

MODE="${1:-daemon}"
QUEUE_POLL_SECONDS_DEFAULT="${QUEUE_POLL_SECONDS:-1}"
QUEUE_WORKERS_DEFAULT="${QUEUE_WORKERS:-4}"
POLL_SECONDS="$QUEUE_POLL_SECONDS_DEFAULT"
QUEUE_WORKERS_VALUE="$QUEUE_WORKERS_DEFAULT"

normalize_queue_poll_seconds() {
  local value="${1:-$QUEUE_POLL_SECONDS_DEFAULT}"
  case "$value" in
    ''|*[!0-9]*)
      value="$QUEUE_POLL_SECONDS_DEFAULT"
      ;;
  esac
  if [ "$value" -lt 1 ] 2>/dev/null; then
    value=1
  elif [ "$value" -gt 10 ] 2>/dev/null; then
    value=10
  fi
  printf '%s\n' "$value"
}

normalize_queue_workers() {
  local value="${1:-$QUEUE_WORKERS_DEFAULT}"
  case "$value" in
    ''|*[!0-9]*)
      value="$QUEUE_WORKERS_DEFAULT"
      ;;
  esac
  if [ "$value" -lt 1 ] 2>/dev/null; then
    value=1
  elif [ "$value" -gt 4 ] 2>/dev/null; then
    value=4
  fi
  printf '%s\n' "$value"
}

refresh_runtime_queue_settings() {
  local configured_poll_seconds configured_queue_workers
  configured_poll_seconds="$(read_helper_runtime_state_field "queue_poll_seconds")"
  configured_queue_workers="$(read_helper_runtime_state_field "queue_workers")"
  POLL_SECONDS="$(normalize_queue_poll_seconds "${configured_poll_seconds:-$QUEUE_POLL_SECONDS_DEFAULT}")"
  QUEUE_WORKERS_VALUE="$(normalize_queue_workers "${configured_queue_workers:-$QUEUE_WORKERS_DEFAULT}")"
}

require_command queue python3
ensure_runtime_dirs
refresh_runtime_queue_settings
sync_task_artifacts >/dev/null 2>&1 || log_msg WARN queue "Task artifact sync failed before queue processing"
while IFS=$'\t' read -r project_name task_name reason; do
  [ -n "${project_name:-}" ] || continue
  log_msg WARN queue "Recovered stale running task for $project_name: $task_name ($reason)"
done < <(reclaim_stale_running_registry_tasks)
while IFS=$'\t' read -r project_name task_name reason; do
  [ -n "${project_name:-}" ] || continue
  log_msg INFO queue "Pruned actionable task for $project_name: $task_name ($reason)"
done < <(prune_invalid_actionable_registry_tasks)
while IFS=$'\t' read -r project_name task_name; do
  [ -n "${project_name:-}" ] || continue
  log_msg INFO queue "Rehydrated approved task into queue for $project_name: $task_name"
done < <(reconcile_approved_registry_tasks_to_queue)
finalize_queue_hot_reload
log_msg INFO queue "Queue processor started in $MODE mode"
WORKER_LANE_1_PID=""
WORKER_LANE_1_PROJECT=""
WORKER_LANE_1_TASK=""
WORKER_LANE_1_STDOUT=""
WORKER_LANE_1_PROVIDER=""
WORKER_LANE_2_PID=""
WORKER_LANE_2_PROJECT=""
WORKER_LANE_2_TASK=""
WORKER_LANE_2_STDOUT=""
WORKER_LANE_2_PROVIDER=""
WORKER_LANE_3_PID=""
WORKER_LANE_3_PROJECT=""
WORKER_LANE_3_TASK=""
WORKER_LANE_3_STDOUT=""
WORKER_LANE_3_PROVIDER=""
WORKER_LANE_4_PID=""
WORKER_LANE_4_PROJECT=""
WORKER_LANE_4_TASK=""
WORKER_LANE_4_STDOUT=""
WORKER_LANE_4_PROVIDER=""

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
    lane-3) printf '%s\n' "$WORKER_LANE_3_PID" ;;
    lane-4) printf '%s\n' "$WORKER_LANE_4_PID" ;;
    *) printf '\n' ;;
  esac
}

set_lane_state() {
  local lane_id="$1"
  local pid="$2"
  local project="$3"
  local task="$4"
  local stdout_file="$5"
  local provider="${6:-}"
  case "$lane_id" in
    lane-1)
      WORKER_LANE_1_PID="$pid"
      WORKER_LANE_1_PROJECT="$project"
      WORKER_LANE_1_TASK="$task"
      WORKER_LANE_1_STDOUT="$stdout_file"
      WORKER_LANE_1_PROVIDER="$provider"
      ;;
    lane-2)
      WORKER_LANE_2_PID="$pid"
      WORKER_LANE_2_PROJECT="$project"
      WORKER_LANE_2_TASK="$task"
      WORKER_LANE_2_STDOUT="$stdout_file"
      WORKER_LANE_2_PROVIDER="$provider"
      ;;
    lane-3)
      WORKER_LANE_3_PID="$pid"
      WORKER_LANE_3_PROJECT="$project"
      WORKER_LANE_3_TASK="$task"
      WORKER_LANE_3_STDOUT="$stdout_file"
      WORKER_LANE_3_PROVIDER="$provider"
      ;;
    lane-4)
      WORKER_LANE_4_PID="$pid"
      WORKER_LANE_4_PROJECT="$project"
      WORKER_LANE_4_TASK="$task"
      WORKER_LANE_4_STDOUT="$stdout_file"
      WORKER_LANE_4_PROVIDER="$provider"
      ;;
  esac
}

lane_project() {
  case "${1:-}" in
    lane-1) printf '%s\n' "$WORKER_LANE_1_PROJECT" ;;
    lane-2) printf '%s\n' "$WORKER_LANE_2_PROJECT" ;;
    lane-3) printf '%s\n' "$WORKER_LANE_3_PROJECT" ;;
    lane-4) printf '%s\n' "$WORKER_LANE_4_PROJECT" ;;
    *) printf '\n' ;;
  esac
}

lane_task() {
  case "${1:-}" in
    lane-1) printf '%s\n' "$WORKER_LANE_1_TASK" ;;
    lane-2) printf '%s\n' "$WORKER_LANE_2_TASK" ;;
    lane-3) printf '%s\n' "$WORKER_LANE_3_TASK" ;;
    lane-4) printf '%s\n' "$WORKER_LANE_4_TASK" ;;
    *) printf '\n' ;;
  esac
}

lane_provider() {
  case "${1:-}" in
    lane-1) printf '%s\n' "$WORKER_LANE_1_PROVIDER" ;;
    lane-2) printf '%s\n' "$WORKER_LANE_2_PROVIDER" ;;
    lane-3) printf '%s\n' "$WORKER_LANE_3_PROVIDER" ;;
    lane-4) printf '%s\n' "$WORKER_LANE_4_PROVIDER" ;;
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
      WORKER_LANE_1_PROVIDER=""
      ;;
    lane-2)
      WORKER_LANE_2_PID=""
      WORKER_LANE_2_PROJECT=""
      WORKER_LANE_2_TASK=""
      WORKER_LANE_2_STDOUT=""
      WORKER_LANE_2_PROVIDER=""
      ;;
    lane-3)
      WORKER_LANE_3_PID=""
      WORKER_LANE_3_PROJECT=""
      WORKER_LANE_3_TASK=""
      WORKER_LANE_3_STDOUT=""
      WORKER_LANE_3_PROVIDER=""
      ;;
    lane-4)
      WORKER_LANE_4_PID=""
      WORKER_LANE_4_PROJECT=""
      WORKER_LANE_4_TASK=""
      WORKER_LANE_4_STDOUT=""
      WORKER_LANE_4_PROVIDER=""
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
    local provider_selection_info task_provider
    provider_selection_info="$(select_queue_provider_for_lane "$project_name" "$task" "$lane_id")"
    provider_selection_info="$(
      select_balanced_queue_provider_info \
        "$project_name" \
        "$task" \
        "$(printf '%s\n' "$provider_selection_info" | sed -n '1p')" \
        "$(printf '%s\n' "$provider_selection_info" | sed -n '2p')" \
        "$(printf '%s\n' "$provider_selection_info" | sed -n '3p')" \
        "$(active_provider_count "codex")" \
        "$(active_provider_count "claude")"
    )"
    task_provider="$(printf '%s\n' "$provider_selection_info" | sed -n '1p')"
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
    QUEUE_TASK_PROVIDER_OVERRIDE="$task_provider" \
    QUEUE_TASK_PROVIDER_REASON_OVERRIDE="$(printf '%s\n' "$provider_selection_info" | sed -n '2p')" \
    QUEUE_TASK_PROVIDER_SOURCE_OVERRIDE="$(printf '%s\n' "$provider_selection_info" | sed -n '3p')" \
    QUEUE_TASK_PROJECT_OVERRIDE="$project_name" \
    QUEUE_TASK_TEXT_OVERRIDE="$task" \
    bash "$ROOT_DIR/scripts/queue-worker.sh" \
      "$lane_id" \
      "$project_dir" \
      "$project_name" \
      "$task" \
      "$retry_count" \
      "$task_provider" \
      "$lease_id" >"$stdout_file" 2>&1 &
    set_lane_state "$lane_id" "$!" "$project_name" "$task" "$stdout_file" "$task_provider"
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
  for lane_id in "lane-1" "lane-2" "lane-3" "lane-4"; do
    pid="$(lane_pid "$lane_id")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

active_provider_count() {
  local provider_name="${1:-}"
  local count=0 lane_id pid lane_task_provider
  for lane_id in "lane-1" "lane-2" "lane-3" "lane-4"; do
    pid="$(lane_pid "$lane_id")"
    [ -n "$pid" ] || continue
    if ! kill -0 "$pid" 2>/dev/null; then
      continue
    fi
    lane_task_provider="$(normalize_provider_name "$(lane_provider "$lane_id")")"
    if [ "$lane_task_provider" = "$provider_name" ]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

reap_finished_workers() {
  local lane_id pid
  for lane_id in "lane-1" "lane-2" "lane-3" "lane-4"; do
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
  for lane_id in "lane-1" "lane-2" "lane-3" "lane-4"; do
    [ "$lane_id" = "lane-2" ] && [ "$QUEUE_WORKERS_VALUE" -lt 2 ] && continue
    [ "$lane_id" = "lane-3" ] && [ "$QUEUE_WORKERS_VALUE" -lt 3 ] && continue
    [ "$lane_id" = "lane-4" ] && [ "$QUEUE_WORKERS_VALUE" -lt 4 ] && continue
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

maybe_hot_reload_queue() {
  [ "$MODE" = "--once" ] && return 1

  if ! queue_hot_reload_requested && ! helper_scripts_reload_required; then
    return 1
  fi

  if [ "$(active_worker_count)" -gt 0 ]; then
    write_status \
      "$(read_status_field_default "state" "running")" \
      "$(read_status_field_default "project" "")" \
      "$(read_status_field_default "task" "")" \
      "$(current_last_result | sed 's/^$/RUNNING/')" \
      "draining_for_hot_reload=1 active_workers=$(active_worker_count)"
    return 0
  fi

  log_msg INFO queue "Hot reloading queue helpers in-place"
  finalize_queue_hot_reload
  exec bash "$ROOT_DIR/scripts/multi-queue.sh" "$MODE"
}

while true; do
  refresh_runtime_queue_settings
  reap_finished_workers
  while IFS=$'\t' read -r project_name task_name reason; do
    [ -n "${project_name:-}" ] || continue
    log_msg WARN queue "Recovered stale running task for $project_name: $task_name ($reason)"
  done < <(reclaim_stale_running_registry_tasks)
  while IFS=$'\t' read -r project_name task_name reason; do
    [ -n "${project_name:-}" ] || continue
    log_msg INFO queue "Pruned actionable task for $project_name: $task_name ($reason)"
  done < <(prune_invalid_actionable_registry_tasks)
  while IFS=$'\t' read -r project_name task_name; do
    [ -n "${project_name:-}" ] || continue
    log_msg INFO queue "Rehydrated approved task into queue for $project_name: $task_name"
  done < <(reconcile_approved_registry_tasks_to_queue)
  if maybe_hot_reload_queue; then
    sleep "$POLL_SECONDS"
    continue
  fi

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
