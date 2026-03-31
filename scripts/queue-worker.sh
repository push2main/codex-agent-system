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

# --- Worktree Isolation ---
# When the project is a git repository and worktree isolation is enabled,
# execute the task in an isolated git worktree to prevent file conflicts
# between parallel workers. Falls back to direct execution if git is
# unavailable or the project is not a git repository.
USE_WORKTREE="${CODEX_USE_WORKTREE:-0}"
WORKTREE_DIR=""
WORKTREE_BRANCH=""
EFFECTIVE_PROJECT_DIR="$PROJECT_DIR"

setup_worktree() {
  local repo_root
  repo_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo_root" ] || return 1

  WORKTREE_BRANCH="worktree-${LANE_ID}-${TASK_ID:-$RANDOM}"
  WORKTREE_DIR="/tmp/codex-worktrees/$WORKTREE_BRANCH"

  mkdir -p "$(dirname "$WORKTREE_DIR")"
  if git -C "$repo_root" worktree add "$WORKTREE_DIR" -b "$WORKTREE_BRANCH" 2>/dev/null; then
    EFFECTIVE_PROJECT_DIR="$WORKTREE_DIR"
    log_msg INFO queue-worker "Created worktree at $WORKTREE_DIR for lane $LANE_ID"
    return 0
  else
    log_msg WARN queue-worker "Failed to create worktree; falling back to direct execution"
    WORKTREE_DIR=""
    return 1
  fi
}

cleanup_worktree() {
  [ -n "$WORKTREE_DIR" ] || return 0
  local repo_root
  repo_root="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo_root" ] || return 0

  # Check if worktree has changes worth merging
  if [ -d "$WORKTREE_DIR" ]; then
    local has_changes
    has_changes="$(git -C "$WORKTREE_DIR" status --porcelain 2>/dev/null | head -1 || true)"
    if [ -n "$has_changes" ]; then
      # Commit and merge changes back
      git -C "$WORKTREE_DIR" add -A 2>/dev/null || true
      git -C "$WORKTREE_DIR" commit -m "Worktree task: $TASK" --no-verify 2>/dev/null || true
      local current_branch
      current_branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || true)"
      if [ -n "$current_branch" ]; then
        git -C "$repo_root" merge "$WORKTREE_BRANCH" --no-edit 2>/dev/null || {
          log_msg WARN queue-worker "Worktree merge conflict for $WORKTREE_BRANCH — branch preserved for manual resolution"
          git -C "$repo_root" merge --abort 2>/dev/null || true
        }
      fi
    fi
  fi

  git -C "$repo_root" worktree remove "$WORKTREE_DIR" --force 2>/dev/null || true
  git -C "$repo_root" branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
  log_msg INFO queue-worker "Cleaned up worktree $WORKTREE_DIR"
}

# Setup worktree if enabled
if [ "$USE_WORKTREE" = "1" ]; then
  setup_worktree || true
fi

# Ensure cleanup on exit when using worktree
if [ -n "$WORKTREE_DIR" ]; then
  trap 'cleanup_worktree' EXIT
fi

resolved_timeout="$(resolve_task_timeout_seconds "$PROJECT_NAME" "$TASK" "$TASK_TIMEOUT_SECONDS" 2>/dev/null || printf '%s' "$TASK_TIMEOUT_SECONDS")"

task_log_project_title_failure_state() {
  local project_name="$1"
  local task_title="$2"

  python3 - "$project_name" "$task_title" "$TASK_LOG" <<'PY'
import json
import re
import sys


def normalize_text(value):
    return re.sub(r"\s+", " ", str(value or "").strip().lower())


project_key = normalize_text(sys.argv[1])
task_key = normalize_text(sys.argv[2])[:80]
task_log_path = sys.argv[3]
failure_count = 0
last_failure_kind = ""

try:
    with open(task_log_path, encoding="utf-8") as handle:
        for raw_line in handle:
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                record = json.loads(raw_line)
            except Exception:
                continue
            if normalize_text(record.get("project")) != project_key:
                continue
            if normalize_text(record.get("task"))[:80] != task_key:
                continue
            if normalize_text(record.get("result")) != "failure":
                continue
            failure_count += 1
            failure_kind = str(record.get("failure_kind") or "").strip()
            if failure_kind:
                last_failure_kind = failure_kind
except Exception:
    pass

print(f"{failure_count}\t{last_failure_kind}")
PY
}

task_failure_state="$(task_log_project_title_failure_state "$PROJECT_NAME" "$TASK")"
zombie_failure_count="$(printf '%s\n' "$task_failure_state" | awk -F '\t' 'NR==1 {print $1}')"
[ -n "$zombie_failure_count" ] || zombie_failure_count="0"
last_failure_kind="$(printf '%s\n' "$task_failure_state" | awk -F '\t' 'NR==1 {print $2}')"

# --- Zombie Task Guard ---
# If this task title has already failed 5+ times in tasks.log, shelve it immediately.
# This prevents wasting worker slots on tasks that repeatedly fail.
ZOMBIE_THRESHOLD=5
if [ "${zombie_failure_count:-0}" -ge "$ZOMBIE_THRESHOLD" ]; then
  log_msg WARN queue-worker "Zombie task detected on $LANE_ID: '$TASK' has $zombie_failure_count prior failures (threshold=$ZOMBIE_THRESHOLD) — shelving"
  persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "shelved" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
  append_runtime_session_blocker "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "zombie_guard" "Task shelved by zombie guard."
  append_runtime_session_event "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "execute_failure" "Queue execution blocked by zombie guard." "lane=$LANE_ID"
  clear_task_retry_count "$PROJECT_NAME" "$TASK"
  sync_task_registry_execution_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "shelved" \
    "zombie_guard" \
    "Task shelved by zombie guard: $zombie_failure_count prior failures exceed threshold of $ZOMBIE_THRESHOLD." \
    "$((RETRY_COUNT + 1))" \
    "$MAX_AGENT_RETRIES" \
    "$TASK_PROVIDER" \
    "$LANE_ID" \
    "" \
    "0" \
    "$TASK_ID" || true
  write_status "shelved" "$PROJECT_NAME" "$TASK" "ZOMBIE" "lane=$LANE_ID prior_failures=$zombie_failure_count"
  exit 1
fi

# --- Non-Retryable Failure Guard ---
# Prevent re-execution of tasks whose last failure is structurally ungrounded or
# historically near-zero yield on retry. These categories waste full worker slots.
if [ "${RETRY_COUNT:-0}" -gt 0 ]; then
  if [ "$last_failure_kind" = "timeout" ] || [ "$last_failure_kind" = "missing_environment" ] || [ "$last_failure_kind" = "missing_platform" ] || [ "$last_failure_kind" = "missing_source_file" ] || [ "$last_failure_kind" = "project_mismatch" ]; then
    log_msg WARN queue-worker "Non-retryable failure guard on $LANE_ID: '$TASK' last failed with $last_failure_kind — not retrying"
    persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "failed" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
    append_runtime_session_blocker "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "non_retryable_guard" "Last failure kind was $last_failure_kind."
    append_runtime_session_event "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "execute_failure" "Queue execution blocked by non-retryable guard." "failure_kind=$last_failure_kind"
    sync_task_registry_execution_state \
      "$PROJECT_NAME" \
      "$TASK" \
      "failed" \
      "non_retryable_guard" \
      "Task blocked by non-retryable failure guard: last failure was $last_failure_kind." \
      "$((RETRY_COUNT + 1))" \
      "$MAX_AGENT_RETRIES" \
      "$TASK_PROVIDER" \
      "$LANE_ID" \
      "" \
      "0" \
      "$TASK_ID" \
      "$last_failure_kind" || true
    write_status "failed" "$PROJECT_NAME" "$TASK" "FAILURE" "lane=$LANE_ID non_retryable=$last_failure_kind"
    exit 1
  fi
fi

# --- Pre-Execution Capability Envelope Guard (Iteration 8) ---
# Strategy only gates NEW task creation, but pre-existing approved tasks can bypass
# the capability envelope. Check here to catch tasks approved before envelope expansion.
envelope_blocked="$(python3 -c "
import re, sys
def normalize_text(v): return re.sub(r'\s+', ' ', str(v or '').strip()).lower()
t = normalize_text(sys.argv[1])
PLATFORM_KW = ['swiftui','jetpack compose','compose multiplatform','kotlin multiplatform','react native','flutter','docker compose','kubernetes']
SCOPE_AMP = ['migrate','redesign','overhaul','rewrite','comprehensive','end-to-end','end to end','full stack','all screens','complete rewrite']
INFRA_KW = ['kubernetes','deployment manifests','cloud hosting','docker','matter','zigbee','smart home','iot']
INTEGRATION_KW = ['websocket','real-time','deep linking','across all','end-to-end encrypted','e2e encrypted']
COMPLEXITY_KW = ['dashboard','multi-language','documentation site','education modules','gamified','haptic','micro-animations','leaderboard','compliance framework','transparency','cyber resilience','network scanner','telemetry','analytics']
ph = sum(1 for k in PLATFORM_KW if k in t)
sh2 = sum(1 for k in SCOPE_AMP if k in t)
ih = sum(1 for k in INFRA_KW if k in t)
igh = sum(1 for k in INTEGRATION_KW if k in t)
ch = sum(1 for k in COMPLEXITY_KW if k in t)
blocked = (ph>=2) or (ph>=1 and sh2>=1) or (sh2>=3) or (ih>=2) or (igh>=1 and (ch>=1 or ih>=1 or sh2>=1)) or (ch>=2) or (ih>=1 and (ch>=1 or sh2>=1))
print('yes' if blocked else 'no')
" "$TASK" 2>/dev/null || printf 'no')"

if [ "$envelope_blocked" = "yes" ]; then
  log_msg WARN queue-worker "Pre-execution capability envelope blocked task on $LANE_ID: '$TASK' — shelving"
  persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "shelved" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
  append_runtime_session_blocker "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "capability_envelope_blocked" "Task exceeds capability envelope at execution time."
  append_runtime_session_event "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "execute_failure" "Queue execution blocked by capability envelope." "lane=$LANE_ID"
  sync_task_registry_execution_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "shelved" \
    "capability_envelope_blocked" \
    "Task exceeds capability envelope at execution time (pre-existing approval predates filter)." \
    "$((RETRY_COUNT + 1))" \
    "$MAX_AGENT_RETRIES" \
    "$TASK_PROVIDER" \
    "$LANE_ID" \
    "" \
    "0" \
    "$TASK_ID" || true
  write_status "shelved" "$PROJECT_NAME" "$TASK" "ENVELOPE_BLOCKED" "lane=$LANE_ID"
  exit 1
fi

# Low-signal self-improve tasks burn scarce recovery capacity when the system is
# already stalled. Retire comment/documentation-only self-improve work before it
# reaches the agent loop so worker slots stay focused on behavioral fixes/tests.
low_signal_self_improve_check="$(detect_low_signal_self_improve_task "$TASK" "$PROJECT_NAME" "$TASK_ID" 2>/dev/null || printf '{"blocked":false}')"
low_signal_self_improve_blocked="$(printf '%s' "$low_signal_self_improve_check" | jq -r '.blocked // false' 2>/dev/null || printf 'false')"
if [ "$low_signal_self_improve_blocked" = "true" ]; then
  low_signal_reason="$(printf '%s' "$low_signal_self_improve_check" | jq -r '.reason // "Low-signal self-improve task."' 2>/dev/null || printf 'Low-signal self-improve task.')"
  log_msg WARN queue-worker "Low-signal self-improve guard blocked task on $LANE_ID: '$TASK' — shelving ($low_signal_reason)"
  persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "shelved" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
  append_runtime_session_blocker "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "low_signal_self_improve_guard" "$low_signal_reason"
  append_runtime_session_event "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "execute_failure" "Queue execution blocked by low-signal guard." "$low_signal_reason"
  clear_task_retry_count "$PROJECT_NAME" "$TASK"
  sync_task_registry_execution_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "shelved" \
    "low_signal_self_improve_guard" \
    "$low_signal_reason" \
    "$((RETRY_COUNT + 1))" \
    "$MAX_AGENT_RETRIES" \
    "$TASK_PROVIDER" \
    "$LANE_ID" \
    "" \
    "0" \
    "$TASK_ID" || true
  write_status "shelved" "$PROJECT_NAME" "$TASK" "LOW_SIGNAL_SELF_IMPROVE" "lane=$LANE_ID"
  exit 1
fi

write_status "running" "$PROJECT_NAME" "$TASK" "RUNNING" "lane=$LANE_ID retry=$RETRY_COUNT timeout=${resolved_timeout}s"
persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "running" "background" "$TASK_PROVIDER" "$LANE_ID" "RUNNING" "0" "0" "$TASK"
append_task_activity_event \
  "$PROJECT_NAME" \
  "$TASK_ID" \
  "$LANE_ID" \
  "execute_start" \
  "Queue execution started." \
  "retry=$RETRY_COUNT timeout=${resolved_timeout}s provider=$TASK_PROVIDER"

if PROJECT_NAME="$PROJECT_NAME" python3 "$ROOT_DIR/scripts/run-with-timeout.py" "$resolved_timeout" bash "$ROOT_DIR/agents/orchestrator.sh" "$EFFECTIVE_PROJECT_DIR" "$TASK" "$TASK_ID"; then
  clear_task_retry_count "$PROJECT_NAME" "$TASK"
  persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "completed" "background" "$TASK_PROVIDER" "$LANE_ID" "SUCCESS" "0" "0" "$TASK"
  append_runtime_session_event \
    "$PROJECT_NAME" \
    "$TASK_ID" \
    "${LEASE_ID:-$LANE_ID}" \
    "execute_success" \
    "Queue execution completed successfully." \
    "retry=$RETRY_COUNT provider=$TASK_PROVIDER"
  append_task_activity_event \
    "$PROJECT_NAME" \
    "$TASK_ID" \
    "$LANE_ID" \
    "execute_success" \
    "Queue execution completed successfully." \
    "retry=$RETRY_COUNT provider=$TASK_PROVIDER"
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
  terminal_outcome="$(await_task_registry_late_terminal_outcome "$PROJECT_NAME" "$TASK" "$TASK_ID" 2>/dev/null || true)"
  if [ "$terminal_outcome" = "SUCCESS" ]; then
    clear_task_retry_count "$PROJECT_NAME" "$TASK"
    sync_task_registry_execution_state \
      "$PROJECT_NAME" \
      "$TASK" \
      "completed" \
      "execute_success" \
      "Queue execution completed successfully after timeout because success evidence was already persisted." \
      "$next_retry" \
      "$MAX_AGENT_RETRIES" \
      "$TASK_PROVIDER" \
      "$LANE_ID" \
      "" \
      "0" \
      "$TASK_ID" || true
    log_msg WARN queue-worker "Task hit lane timeout after persisting success evidence on $LANE_ID for $PROJECT_NAME; preserving completed status"
    write_status "completed" "$PROJECT_NAME" "$TASK" "SUCCESS" "lane=$LANE_ID timeout_reconciled=1 retry=$RETRY_COUNT"
    exit 0
  elif [ "$terminal_outcome" = "FAILURE" ]; then
    log_msg WARN queue-worker "Task hit lane timeout after persisting failure evidence on $LANE_ID for $PROJECT_NAME; treating it as task failure"
    rc=1
  else
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
      "timeout" \
      "0" \
      "$TASK_ID" \
      "0" \
      "Outer timeout after ${resolved_timeout}s — task did not complete within queue-worker budget (zero steps executed)"
    compute_provider_stats || true
    log_msg ERROR queue-worker "Task timed out after ${resolved_timeout}s on $LANE_ID for $PROJECT_NAME"
    persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "failed" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
    append_runtime_session_blocker "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "timeout" "Task timed out after ${resolved_timeout}s."
    append_runtime_session_event \
      "$PROJECT_NAME" \
      "$TASK_ID" \
      "${LEASE_ID:-$LANE_ID}" \
      "execute_timeout" \
      "Queue execution timed out." \
      "timeout=${resolved_timeout}s provider=$TASK_PROVIDER"
    append_task_activity_event \
      "$PROJECT_NAME" \
      "$TASK_ID" \
      "$LANE_ID" \
      "execute_timeout" \
      "Queue execution timed out." \
      "timeout=${resolved_timeout}s provider=$TASK_PROVIDER"
    notify_ntfy "Codex task timed out" "$PROJECT_NAME: $TASK" high alarm_clock
    # Timeouts are non-retryable: retrying the same task at the same timeout
    # wastes a full worker slot and historically succeeds <2% of the time.
    # Mark as failed immediately instead of requeueing.
    clear_task_retry_count "$PROJECT_NAME" "$TASK"
    sync_task_registry_execution_state \
      "$PROJECT_NAME" \
      "$TASK" \
      "failed" \
      "execute_failure" \
      "Task timed out after ${resolved_timeout}s — timeout failures are non-retryable to prevent worker waste." \
      "$next_retry" \
      "$MAX_AGENT_RETRIES" \
      "$TASK_PROVIDER" \
      "$LANE_ID" \
      "" \
      "0" \
      "$TASK_ID" \
      "timeout" || true
    write_status "failed" "$PROJECT_NAME" "$TASK" "FAILURE" "lane=$LANE_ID timeout_non_retryable=1"
    exit 1
  fi
else
  log_msg ERROR queue-worker "Task failed on $LANE_ID for $PROJECT_NAME with exit code $rc"
fi

# Exit code 3 = non-retriable failure (e.g. missing environment, auth, syntax) — skip requeue
if [ "$rc" -eq 3 ]; then
  log_msg WARN queue-worker "Non-retriable failure (exit=3) on $LANE_ID for $PROJECT_NAME — skipping requeue"
  clear_task_retry_count "$PROJECT_NAME" "$TASK"
  persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "failed" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
  append_runtime_session_blocker "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "non_retriable_failure" "Task requires manual intervention."
  append_task_activity_event \
    "$PROJECT_NAME" \
    "$TASK_ID" \
    "$LANE_ID" \
    "execute_failure" \
    "Queue execution failed without retry." \
    "non_retriable=1 provider=$TASK_PROVIDER"
  sync_task_registry_execution_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "failed" \
    "execute_failure" \
    "Non-retriable failure detected — task requires manual intervention." \
    "$next_retry" \
    "$MAX_AGENT_RETRIES" \
    "$TASK_PROVIDER" \
    "$LANE_ID" \
    "" \
    "0" \
    "$TASK_ID" || true
  write_status "failed" "$PROJECT_NAME" "$TASK" "FAILURE" "lane=$LANE_ID non_retriable=1"
  exit 1
fi

# Check cumulative attempt count to prevent infinite retry churn from repeated re-approvals
# Cumulative limit is roughly 2x max_retries to account for re-approval cycles
cumulative_retry_limit=$((MAX_AGENT_RETRIES * 2))
cumulative_attempts="$(get_task_retry_count "$PROJECT_NAME" "$TASK")"

if [ "$next_retry" -lt "$MAX_AGENT_RETRIES" ] && [ "$cumulative_attempts" -lt "$cumulative_retry_limit" ]; then
  local_queue_file="$QUEUE_DIR/$PROJECT_NAME.txt"
  set_task_retry_count "$PROJECT_NAME" "$TASK" "$next_retry"
  printf '%s\n' "$TASK" >>"$local_queue_file"
  persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "retrying" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
  append_task_activity_event \
    "$PROJECT_NAME" \
    "$TASK_ID" \
    "$LANE_ID" \
    "execute_retry" \
    "Queue execution failed and was requeued." \
    "retry=$next_retry/$MAX_AGENT_RETRIES cumulative=$cumulative_attempts/$cumulative_retry_limit provider=$TASK_PROVIDER"
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
  log_msg WARN queue-worker "Requeued task on $LANE_ID for $PROJECT_NAME after failure (retry=$next_retry/$((MAX_AGENT_RETRIES - 1)) cumulative=$cumulative_attempts/$cumulative_retry_limit)"
  write_status "retrying" "$PROJECT_NAME" "$TASK" "FAILURE" "lane=$LANE_ID task_requeued=1 retry=$next_retry/$MAX_AGENT_RETRIES cumulative=$cumulative_attempts/$cumulative_retry_limit"
  exit 1
elif [ "$cumulative_attempts" -ge "$cumulative_retry_limit" ]; then
  log_msg WARN queue-worker "Retry exhausted on $LANE_ID for $PROJECT_NAME: cumulative_attempts=$cumulative_attempts >= limit=$cumulative_retry_limit"
  clear_task_retry_count "$PROJECT_NAME" "$TASK"
  persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "failed" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
  append_runtime_session_blocker "$PROJECT_NAME" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "retry_exhausted" "Retry exhausted after exceeding cumulative attempt limit."
  append_task_activity_event \
    "$PROJECT_NAME" \
    "$TASK_ID" \
    "$LANE_ID" \
    "execute_failure" \
    "Queue execution failed after retry exhaustion." \
    "cumulative=$cumulative_attempts/$cumulative_retry_limit provider=$TASK_PROVIDER"
  sync_task_registry_execution_state \
    "$PROJECT_NAME" \
    "$TASK" \
    "failed" \
    "execute_failure" \
    "Retry exhausted after exceeding cumulative attempt limit (repeated re-approvals detected)." \
    "$next_retry" \
    "$MAX_AGENT_RETRIES" \
    "$TASK_PROVIDER" \
    "$LANE_ID" \
    "" \
    "0" \
    "$TASK_ID" || true
  write_status "failed" "$PROJECT_NAME" "$TASK" "FAILURE" "lane=$LANE_ID retry_exhausted=1 cumulative=$cumulative_attempts/$cumulative_retry_limit"
  exit 1
fi

clear_task_retry_count "$PROJECT_NAME" "$TASK"
persist_runtime_session_state "$PROJECT_NAME" "$TASK" "$TASK_ID" "${LEASE_ID:-$LANE_ID}" "failed" "background" "$TASK_PROVIDER" "$LANE_ID" "FAILURE" "0" "0" "$TASK"
append_task_activity_event \
  "$PROJECT_NAME" \
  "$TASK_ID" \
  "$LANE_ID" \
  "execute_failure" \
  "Queue execution failed after exhausting retries." \
  "retry=$next_retry/$MAX_AGENT_RETRIES provider=$TASK_PROVIDER"
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
