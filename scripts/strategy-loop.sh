#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap strategy-loop

MODE="${1:-daemon}"
PROJECT_NAME="${2:-codex-agent-system}"
POLL_SECONDS="${STRATEGY_POLL_SECONDS:-60}"
OUTPUT_FILE="$LOG_DIR/strategy-latest.json"
STRATEGY_BACKLOG_OVERLOAD_THRESHOLD="${STRATEGY_BACKLOG_OVERLOAD_THRESHOLD:-8}"
STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS_DEFAULT="${STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS:-2}"
STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS="$STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS_DEFAULT"
STRATEGY_HOT_RELOAD_STATE_FILE="$LOG_DIR/strategy-hot-reload.state"
TIMEOUT_COOLDOWN_FILE="$LOG_DIR/strategy-timeout-cooldown"
TIMEOUT_COOLDOWN_STATE_FILE="$LOG_DIR/strategy-timeout-cooldown.state"

normalize_strategy_hot_reload_debounce_seconds() {
  local value="${1:-$STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS_DEFAULT}"
  case "$value" in
    ''|*[!0-9]*)
      value="$STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS_DEFAULT"
      ;;
  esac
  if [ "$value" -lt 0 ] 2>/dev/null; then
    value=0
  elif [ "$value" -gt 10 ] 2>/dev/null; then
    value=10
  fi
  printf '%s\n' "$value"
}

read_strategy_hot_reload_state_field() {
  local field_name="$1"
  awk -F= -v key="$field_name" '$1==key { print substr($0, length(key) + 2); exit }' "$STRATEGY_HOT_RELOAD_STATE_FILE" 2>/dev/null || true
}

persist_strategy_hot_reload_state() {
  local marker="$1"
  local detected_at="$2"
  cat >"$STRATEGY_HOT_RELOAD_STATE_FILE" <<EOF
marker=$marker
detected_at=$detected_at
EOF
}

clear_strategy_hot_reload_state() {
  rm -f "$STRATEGY_HOT_RELOAD_STATE_FILE" 2>/dev/null || true
}

read_strategy_timeout_cooldown_state_field() {
  local field_name="$1"
  awk -F= -v key="$field_name" '$1==key { print substr($0, length(key) + 2); exit }' "$TIMEOUT_COOLDOWN_STATE_FILE" 2>/dev/null || true
}

persist_strategy_timeout_cooldown_state() {
  local last_timeout_marker="$1"
  cat >"$TIMEOUT_COOLDOWN_STATE_FILE" <<EOF
last_timeout_marker=$last_timeout_marker
EOF
}

strategy_hot_reload_debounce_elapsed() {
  local detected_at="$1"
  python3 - "$detected_at" "$STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS" <<'PY'
from datetime import datetime, timezone
import sys

detected_at = sys.argv[1].strip()
try:
    debounce_seconds = int(sys.argv[2])
except ValueError:
    debounce_seconds = 0

if debounce_seconds <= 0:
    print("1")
    raise SystemExit

if not detected_at:
    print("0")
    raise SystemExit

try:
    detected_dt = datetime.fromisoformat(detected_at.replace("Z", "+00:00")).astimezone(timezone.utc)
except ValueError:
    print("0")
    raise SystemExit

elapsed = (datetime.now(timezone.utc) - detected_dt).total_seconds()
print("1" if elapsed >= debounce_seconds else "0")
PY
}

require_command strategy-loop jq
require_command strategy-loop python3
ensure_runtime_dirs
STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS="$(
  normalize_strategy_hot_reload_debounce_seconds "$STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS"
)"
log_msg INFO strategy-loop "Strategy loop started in $MODE mode for $PROJECT_NAME"

PROCESS_HELPER_MARKER="${STRATEGY_PROCESS_HELPER_MARKER:-$(helper_scripts_marker)}"

# ── Iteration 19+20 fix: FUNCTION-BASED CRASH RESILIENCE + EXTERNAL PYTHON ──
# Problem 63 (iter 19): Moved loop body from ( ) subshell to function.
# Problem 66 (iter 20): Function fix was INSUFFICIENT — the real bash 3.2
# parsing bug trigger is <<'MARKER' inside $() command substitutions, NOT
# the outer () vs {} context. Crash loop continued 3+ hours after iter 19.
# Final fix: ALL inline Python heredocs extracted to separate .py files
# (strategy-auto-approve.py, strategy-timeout-snapshot.py, strategy-reconcile.py,
# strategy-chronic-tasks.py). Zero <<'MARKER' inside $() now.
_strategy_loop_body() {
  while IFS=$'\t' read -r _legacy_action _legacy_project _legacy_queue _legacy_count; do
    [ -n "${_legacy_action:-}" ] || continue
    case "$_legacy_action" in
      pruned)
        log_msg INFO strategy-loop "Legacy queue mirror pruned $_legacy_count stale entr$( [ "${_legacy_count:-0}" = "1" ] && printf 'y' || printf 'ies' ) for $_legacy_project from $_legacy_queue"
        ;;
      copied)
        log_msg WARN strategy-loop "Legacy queue mirror restored $_legacy_count approved entr$( [ "${_legacy_count:-0}" = "1" ] && printf 'y' || printf 'ies' ) for $_legacy_project from $_legacy_queue"
        ;;
    esac
  done < <(sync_legacy_queue_mirror)

  # Compact task registry if it exceeds size threshold
  bash "$ROOT_DIR/scripts/compact-registry.sh" 2>/dev/null || true
  sync_task_artifacts >/dev/null 2>&1 || log_msg WARN strategy-loop "Task artifact sync failed before strategy decisions"

  # ── Iteration 16 fix: UNCONDITIONAL AUTO-APPROVAL ──────────────────────────
  # Problem 54: Auto-approval was only reachable inside the cooldown block
  # (lines 196-322). When no cooldown was active (no recent timeouts), the
  # auto-approval code never ran. This created a 22+ hour deadlock with 4
  # pending_approval tasks that nobody could approve. The reconcile in
  # multi-queue has auto-approval too, but it races with strategy-loop's
  # registry writes (compact-registry, self-improve), causing the auto-
  # approval to be silently overwritten before it can take effect.
  #
  # Fix: Run auto-approval as the FIRST action in every strategy-loop cycle,
  # immediately after compact-registry (which is read-only when below threshold).
  # This ensures a single sequential process handles approval without races.
  # Also: route away from broken providers (claude has 1045+ failures).
  # ── Iteration 20 fix: Python extracted to external files ──────────────────
  # Problem 66: Iteration 19 moved loop body from subshell to function, but
  # the REAL bash 3.2 parsing bug trigger is <<'MARKER' inside $() — NOT
  # the outer () vs {} context. The crash loop continued for 3+ hours after
  # iteration 19 "fix" because heredocs with single-quoted delimiters inside
  # command substitutions still confuse bash 3.2's quote tracker.
  # Fix: Extract ALL inline Python heredocs to separate .py files.
  _auto_approve_result="$(python3 "$ROOT_DIR/scripts/strategy-auto-approve.py" "$TASK_REGISTRY_FILE" "$METRICS_FILE" "$TASK_LOG" 2>/dev/null || true)"
  if [ -n "$_auto_approve_result" ]; then
    log_msg INFO strategy-loop "Unconditional auto-approval: $_auto_approve_result"
  fi

  # Cooldown: skip strategy run if recent consecutive timeouts detected
  # Iteration 14 fix: only count timeouts from the LAST 30 MINUTES, not the entire
  # system.log history. The previous grep -c counted ALL 196+ historical timeouts,
  # which always exceeded the threshold (3), triggering a 30-minute cooldown on EVERY
  # strategy-loop iteration — a permanent cooldown that could never expire because
  # it was re-activated immediately on the next cycle.
  recent_timeout_snapshot="$(python3 "$ROOT_DIR/scripts/strategy-timeout-snapshot.py" "$LOG_DIR/system.log" 2>/dev/null || printf '0\t')"
  recent_timeouts="$(printf '%s\n' "$recent_timeout_snapshot" | awk -F '\t' 'NR==1 {print $1}')"
  latest_recent_timeout_marker="$(printf '%s\n' "$recent_timeout_snapshot" | awk -F '\t' 'NR==1 {print $2}')"
  case "$recent_timeouts" in
    ''|*[!0-9]*)
      recent_timeouts='0'
      ;;
  esac
  if [ -f "$TIMEOUT_COOLDOWN_FILE" ]; then
    cooldown_until="$(cat "$TIMEOUT_COOLDOWN_FILE" 2>/dev/null || printf '0')"
    now_epoch="$(date +%s)"
    # ── Iteration 15 fix: CAP COOLDOWN DURING DEEP STALLS ──────────────────
    # Problem 53: When pipeline has been stale >12h, a 30-min cooldown only
    # delays recovery further. Cap remaining cooldown to 5 minutes so the
    # system can attempt recovery sooner. The cooldown still provides a brief
    # pause to avoid busy-looping after timeouts.
    _deep_stale_cooldown_cap=0
    if [ "$now_epoch" -lt "$cooldown_until" ]; then
      _deep_stale_cooldown_cap="$(python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
try:
    m = json.load(open(sys.argv[1]))
    since = m.get('pipeline_stale_since', '')
    if not since:
        print('0')
        raise SystemExit
    ts = datetime.fromisoformat(since.replace('Z', '+00:00'))
    hours = (datetime.now(timezone.utc) - ts).total_seconds() / 3600
    print('1' if hours > 12 else '0')
except Exception:
    print('0')
" "$METRICS_FILE" 2>/dev/null || printf '0')"
      if [ "$_deep_stale_cooldown_cap" = "1" ]; then
        _max_cooldown=$(( now_epoch + 300 ))  # 5 minutes from now
        if [ "$cooldown_until" -gt "$_max_cooldown" ]; then
          printf '%s' "$_max_cooldown" > "$TIMEOUT_COOLDOWN_FILE"
          cooldown_until="$_max_cooldown"
          log_msg WARN strategy-loop "Deep stall detected (>12h) — capping cooldown to 5 minutes"
        fi
      fi
    fi
    if [ "$now_epoch" -lt "$cooldown_until" ]; then
      # ── Iteration 15 fix: RUN AUTO-APPROVAL EVEN DURING COOLDOWN ────────
      # Problem 52: When multi-queue crashes, auto-approval (which lives in
      # reconcile_approved_registry_tasks_to_queue) never runs. Previously,
      # the cooldown 'continue' skipped everything. Now we run reconcile
      # during cooldown so pending tasks can be auto-approved even if
      # multi-queue is down. This is safe because reconcile is idempotent
      # and only modifies pending_approval → approved state.
      python3 "$ROOT_DIR/scripts/strategy-reconcile.py" "$TASK_REGISTRY_FILE" "$METRICS_FILE" 2>/dev/null || true
      _auto_result="$(python3 -c "
import json
try:
    r = json.loads(open('$TASK_REGISTRY_FILE').read())
    approved = [t for t in r.get('tasks',[]) if isinstance(t,dict) and str(t.get('status','')).strip().lower()=='approved']
    if approved:
        print(f'auto-approved {len(approved)} task(s): {approved[0].get(\"title\",\"?\")}')
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null || true)"
      if [ -n "$_auto_result" ]; then
        log_msg INFO strategy-loop "Cooldown reconcile: $_auto_result"
      fi
      log_msg INFO strategy-loop "Cooldown active — skipping strategy run (resumes at $(date -d "@$cooldown_until" 2>/dev/null || date -r "$cooldown_until" 2>/dev/null || echo "$cooldown_until"))"
      sleep "$POLL_SECONDS"
      continue
    else
      rm -f "$TIMEOUT_COOLDOWN_FILE" 2>/dev/null || true
    fi
  fi

  # Check for consecutive timeout pattern and activate cooldown
  # Iteration 13 fix: when pending_approval tasks exist and pipeline is stale,
  # extend cooldown to 30 minutes instead of 5 — the short cycle just wastes
  # compute generating nothing new while waiting for approvals.
  if [ "$recent_timeouts" -ge 3 ]; then
    last_trigger_timeout_marker="$(read_strategy_timeout_cooldown_state_field "last_timeout_marker")"
    if [ -n "$latest_recent_timeout_marker" ] && [ "$latest_recent_timeout_marker" = "$last_trigger_timeout_marker" ]; then
      log_msg INFO strategy-loop "Recent timeout window unchanged since last cooldown trigger — allowing recovery without re-arming cooldown"
    else
      pending_count="$(project_task_registry_status_count "$PROJECT_NAME" pending_approval 2>/dev/null || printf '0')"
      case "$pending_count" in ''|*[!0-9]*) pending_count=0 ;; esac
      _pipeline_stale_flag="$(python3 -c "import json,sys; m=json.load(open('$METRICS_FILE')); print('1' if m.get('pipeline_stale') else '0')" 2>/dev/null || printf '0')"
      if [ "$pending_count" -ge 2 ] && [ "$_pipeline_stale_flag" = "1" ]; then
        cooldown_epoch="$(( $(date +%s) + 1800 ))"
        printf '%s' "$cooldown_epoch" > "$TIMEOUT_COOLDOWN_FILE"
        persist_strategy_timeout_cooldown_state "$latest_recent_timeout_marker"
        log_msg WARN strategy-loop "3+ timeouts + ${pending_count} pending approvals + pipeline stale — extended 30-minute cooldown (auto-approve will handle pending tasks)"
      else
        cooldown_epoch="$(( $(date +%s) + 300 ))"
        printf '%s' "$cooldown_epoch" > "$TIMEOUT_COOLDOWN_FILE"
        persist_strategy_timeout_cooldown_state "$latest_recent_timeout_marker"
        log_msg WARN strategy-loop "3+ recent timeouts detected — activating 5-minute strategy cooldown"
      fi
    fi
  fi

  # Run autonomous self-improvement analysis (has its own 30-min cooldown)
  bash "$ROOT_DIR/scripts/self-improve.sh" "$PROJECT_NAME" 2>/dev/null || true

  # --- Mark chronically failing tasks as permanently failed ---
  # Tasks that have failed 3+ times with the same error pattern are wasting cycles.
  # Mark them as failed so they stop being retried.
  python3 "$ROOT_DIR/scripts/strategy-chronic-tasks.py" "$TASK_REGISTRY_FILE" 2>/dev/null || true

  # Gate: block new task generation when system health is poor
  strategy_health_state="$(project_strategy_health_state "$PROJECT_NAME" "$METRICS_FILE" 2>/dev/null || printf '0.00\t0\tfalse\tfalse\t0.00\t0\tfalse\tfalse\tmetrics_fallback')"
  current_success_rate="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $1}')"
  current_success_rate_records="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $2}')"
  retry_churn="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $3}')"
  loop_effort="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $4}')"
  global_success_rate="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $5}')"
  global_success_rate_records="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $6}')"
  global_retry_churn="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $7}')"
  global_loop_effort="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $8}')"
  strategy_health_scope="$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $9}')"
  current_queue_size="$(project_task_registry_status_count "$PROJECT_NAME" approved 2>/dev/null || printf -- '-1')"
  queue_size_source="task_registry"
  case "$current_queue_size" in
    ''|*[!0-9]*)
      current_queue_size='-1'
      ;;
  esac
  if [ "$current_queue_size" -lt 0 ]; then
    current_queue_size="$(jq -r '.approved_tasks // 0' "$METRICS_FILE" 2>/dev/null || printf '0')"
    queue_size_source="metrics"
  fi
  case "$current_success_rate_records" in
    ''|*[!0-9]*)
      current_success_rate_records='0'
      ;;
  esac
  queue_gate_active=0
  # Aggressive gate: block strategy when success rate < 30% and backlog exists, but
  # only when persisted metrics contain real execution evidence. A zero-record snapshot
  # should not freeze strategy just because success_rate falls back to 0. Still block
  # on clearly overloaded live backlogs even without evidence, and always honor the
  # systemic health flags.
  registry_pressure_state="$(project_task_registry_pressure_state "$PROJECT_NAME" "$METRICS_FILE" 2>/dev/null || printf 'false\tfalse\tlookup_failed\t0\t0\t')"
  raw_registry_pressure="$(printf '%s\n' "$registry_pressure_state" | awk -F '\t' 'NR==1 {print $1}')"
  registry_pressure="$(printf '%s\n' "$registry_pressure_state" | awk -F '\t' 'NR==1 {print $2}')"
  registry_pressure_reason="$(printf '%s\n' "$registry_pressure_state" | awk -F '\t' 'NR==1 {print $3}')"
  registry_pressure_global_bytes="$(printf '%s\n' "$registry_pressure_state" | awk -F '\t' 'NR==1 {print $4}')"
  registry_pressure_local_bytes="$(printf '%s\n' "$registry_pressure_state" | awk -F '\t' 'NR==1 {print $5}')"
  registry_pressure_dominant_project="$(printf '%s\n' "$registry_pressure_state" | awk -F '\t' 'NR==1 {print $6}')"
  strategy_saturation="$(jq -r '.strategy_saturation_detected // false' "$METRICS_FILE" 2>/dev/null || printf 'false')"
  if [ "$raw_registry_pressure" = "true" ] && [ "$registry_pressure" != "true" ] && [ "$registry_pressure_reason" = "cross_project_registry_pressure" ]; then
    log_msg INFO strategy-loop "Ignoring shared registry pressure for $PROJECT_NAME: dominant_project=${registry_pressure_dominant_project:-unknown} global_bytes=${registry_pressure_global_bytes:-0} local_bytes=${registry_pressure_local_bytes:-0}"
  fi
  shared_health_suppressed=0
  if [ "${strategy_health_scope:-metrics_fallback}" = "project_local" ]; then
    if [ "$global_retry_churn" = "true" ] && [ "$retry_churn" != "true" ]; then
      shared_health_suppressed=1
    fi
    if [ "$global_loop_effort" = "true" ] && [ "$loop_effort" != "true" ]; then
      shared_health_suppressed=1
    fi
    if [ "$global_success_rate_records" -gt 0 ] && [ "$current_success_rate_records" -eq 0 ]; then
      shared_health_suppressed=1
    fi
  fi
  if [ "$shared_health_suppressed" -eq 1 ]; then
    log_msg INFO strategy-loop "Ignoring shared board-health metrics for $PROJECT_NAME: global_success_rate=${global_success_rate:-0} local_success_rate=${current_success_rate:-0} global_total_tasks=${global_success_rate_records:-0} local_total_tasks=${current_success_rate_records:-0} global_retry_churn=${global_retry_churn:-false} local_retry_churn=${retry_churn:-false} global_loop_effort=${global_loop_effort:-false} local_loop_effort=${loop_effort:-false}"
  fi
  # Iteration 10 fix: When health scope is project_local and shared flags differ
  # from local flags, suppress the shared flags to prevent cross-project deadlocks.
  # Also add staleness escape: if no tasks executed in >6 hours, override health
  # flags to allow strategy to run and generate recovery tasks.
  effective_pressure="$registry_pressure"
  effective_loop="$loop_effort"
  effective_churn="$retry_churn"
  effective_queue_size="$current_queue_size"
  if [ "$shared_health_suppressed" -eq 1 ]; then
    if [ "$retry_churn" = "true" ] && [ "$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $3}')" != "true" ]; then
      effective_churn="false"
      log_msg INFO strategy-loop "Suppressed shared retry_churn for local project $PROJECT_NAME"
    fi
    if [ "$loop_effort" = "true" ] && [ "$(printf '%s\n' "$strategy_health_state" | awk -F '\t' 'NR==1 {print $4}')" != "true" ]; then
      effective_loop="false"
      log_msg INFO strategy-loop "Suppressed shared loop_effort for local project $PROJECT_NAME"
    fi
  fi
  # Iteration 10: Cross-project registry pressure suppression — if pressure is from
  # another project and local registry is small, don't block local strategy
  if [ "$registry_pressure" = "true" ] && [ "${registry_pressure_reason:-}" = "cross_project_registry_pressure" ]; then
    effective_pressure="false"
    log_msg INFO strategy-loop "Suppressed cross-project registry pressure for local project $PROJECT_NAME (dominant=${registry_pressure_dominant_project:-unknown})"
  fi
  # Iteration 10: Queue size should reflect LOCAL project, not global approved count
  # When metrics report 12 approved but local registry has 0, use local count
  local_approved_count="$(python3 -c "
import json, sys
try:
    registry = json.loads(open(sys.argv[1]).read())
    tasks = registry.get('tasks', [])
    count = sum(1 for t in tasks if str(t.get('status','')).strip().lower() in ('approved','queued'))
    print(count)
except Exception:
    print(sys.argv[2])
" "$TASK_REGISTRY_FILE" "$current_queue_size" 2>/dev/null || printf '%s' "$current_queue_size")"
  if [ "$local_approved_count" != "$current_queue_size" ]; then
    log_msg INFO strategy-loop "Using local approved count ($local_approved_count) instead of global ($current_queue_size) for queue gate"
    effective_queue_size="$local_approved_count"
  fi
  # Iteration 10: Staleness escape hatch — if no tasks have been logged in >6 hours,
  # force all health flags to false to allow pipeline recovery. A dead pipeline
  # that blocks recovery is worse than a pipeline that generates some risky tasks.
  pipeline_stale="$(python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
try:
    records = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
    if not records:
        print('true')
        raise SystemExit
    last = records[-1]
    # Iteration 18 fix: also fall back to 'timestamp' field
    ts_str = last.get('completed_at') or last.get('updated_at') or last.get('created_at') or last.get('timestamp') or ''
    if not ts_str:
        print('true')
        raise SystemExit
    ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
    stale = (datetime.now(timezone.utc) - ts) > timedelta(hours=6)
    print('true' if stale else 'false')
except Exception:
    print('true')
" "$TASK_LOG" 2>/dev/null || printf 'false')"
  if [ "$pipeline_stale" = "true" ]; then
    effective_pressure="false"
    effective_loop="false"
    effective_churn="false"
    log_msg WARN strategy-loop "Pipeline stale (>6h since last task) — overriding health flags to allow recovery"
  fi
  # ── Iteration 21 fix: ZERO-QUEUE ESCAPE HATCH ──────────────────────────────
  # Problem 70: Queue gate deadlock. When queue_size=0 AND running_tasks=0,
  # health flags (retry_churn, loop_effort) block new task generation forever.
  # No tasks run → no new successes → flags never clear → permanent deadlock.
  # The staleness escape only fires after 6h, creating a long dead zone after
  # the last failure. Fix: if no work exists anywhere (0 approved, 0 queued,
  # 0 running), override health flags to allow recovery immediately.
  _running_count="$(python3 -c "
import json, sys
try:
    r = json.loads(open(sys.argv[1]).read())
    active = sum(1 for t in r.get('tasks',[]) if isinstance(t,dict) and str(t.get('status','')).strip().lower() in ('running','queued'))
    print(active)
except Exception:
    print('0')
" "$TASK_REGISTRY_FILE" 2>/dev/null || printf '0')"
  case "$_running_count" in ''|*[!0-9]*) _running_count='0' ;; esac
  if [ "$effective_queue_size" -eq 0 ] && [ "$_running_count" -eq 0 ]; then
    effective_pressure="false"
    effective_loop="false"
    effective_churn="false"
    log_msg INFO strategy-loop "Zero-queue escape: 0 approved + 0 running — overriding health flags to allow task generation"
  fi
  if python3 -c "
import sys
sr = float(sys.argv[1])
success_records = int(sys.argv[2])
qs = int(sys.argv[3])
pressure = sys.argv[4] == 'true'
saturation = sys.argv[5] == 'true'
loop = sys.argv[6] == 'true'
churn = sys.argv[7] == 'true'
backlog_overload_threshold = int(sys.argv[8])
has_success_evidence = success_records > 0
# Block if: low success with evidence + live backlog, OR overloaded live backlog, OR any system health flag is raised
block = (
    (has_success_evidence and sr < 0.30 and qs >= 2)
    or qs >= backlog_overload_threshold
    or pressure
    or saturation
    or loop
    or churn
)
sys.exit(0 if block else 1)
" "$current_success_rate" "$current_success_rate_records" "$effective_queue_size" "$effective_pressure" "$strategy_saturation" "$effective_loop" "$effective_churn" "$STRATEGY_BACKLOG_OVERLOAD_THRESHOLD" 2>/dev/null; then
    queue_gate_active=1
    log_msg WARN strategy-loop "Queue gate active: success_rate=$current_success_rate queue_size=$effective_queue_size(local)/$current_queue_size(global) pressure=$effective_pressure saturation=$strategy_saturation source=$queue_size_source loop_effort=$effective_loop retry_churn=$effective_churn total_tasks=$current_success_rate_records pressure_reason=${registry_pressure_reason:-unknown} health_scope=${strategy_health_scope:-unknown} pipeline_stale=$pipeline_stale — skipping strategy run"
  fi

  if [ "$queue_gate_active" -eq 0 ]; then
    if bash "$ROOT_DIR/agents/strategy.sh" "$PROJECT_NAME" "$OUTPUT_FILE" >/dev/null; then
      board_count="$(jq -er '(.data.board_updates // .data.board_tasks // []) | length' "$OUTPUT_FILE" 2>/dev/null || printf '0')"
      if [ "$board_count" -gt 0 ]; then
        log_msg INFO strategy-loop "Applied $board_count board task update(s) for $PROJECT_NAME"
      fi
    else
      log_msg ERROR strategy-loop "Strategy run failed for $PROJECT_NAME"
    fi
  fi

  if [ "$MODE" = "--once" ]; then
    break
  fi
  if process_helper_reload_required "$PROCESS_HELPER_MARKER"; then
    current_marker="$(helper_scripts_marker)"
    pending_marker="$(read_strategy_hot_reload_state_field "marker")"
    detected_at="$(read_strategy_hot_reload_state_field "detected_at")"
    if [ "$pending_marker" != "$current_marker" ] || [ -z "$detected_at" ]; then
      persist_strategy_hot_reload_state "$current_marker" "$(now_utc)"
      detected_at="$(read_strategy_hot_reload_state_field "detected_at")"
    fi
    if [ "$(strategy_hot_reload_debounce_elapsed "${detected_at:-}")" != "1" ]; then
      sleep "$POLL_SECONDS"
      continue
    fi
    # Iteration 19: pre-reload syntax validation guard
    # Never exec into a script that fails bash -n — this caused the 22h crash loop
    if ! bash -n "$ROOT_DIR/scripts/strategy-loop.sh" 2>/dev/null; then
      log_msg ERROR strategy-loop "SYNTAX CHECK FAILED — refusing to hot-reload broken script. Run: bash -n scripts/strategy-loop.sh"
      sleep "$POLL_SECONDS"
      continue
    fi
    PROCESS_HELPER_MARKER="$current_marker"
    clear_strategy_hot_reload_state
    log_msg INFO strategy-loop "Hot reloading strategy loop in-place (syntax validated)"
    exec env \
      STRATEGY_PROCESS_HELPER_MARKER="$PROCESS_HELPER_MARKER" \
      STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS="$STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS" \
      bash "$ROOT_DIR/scripts/strategy-loop.sh" "$MODE" "$PROJECT_NAME"
  fi
  clear_strategy_hot_reload_state

  # ── Iteration 15 fix: MUTUAL WATCHDOG ──────────────────────────────────────
  # Multi-queue watches strategy-loop (iteration 12) but nothing watched multi-queue.
  # When multi-queue crashed at 03:11:48Z (4 rapid hot-reloads then silence), both
  # the queue worker AND auto-approval logic died. Strategy-loop now watches the
  # multi-queue tmux window and restarts it if missing. Combined with multi-queue's
  # existing strategy-loop watchdog, this creates mutual process supervision.
  STRATEGY_WATCHDOG_COUNTER="${STRATEGY_WATCHDOG_COUNTER:-0}"
  STRATEGY_WATCHDOG_COUNTER=$((STRATEGY_WATCHDOG_COUNTER + 1))
  if [ "$STRATEGY_WATCHDOG_COUNTER" -ge 30 ]; then
    STRATEGY_WATCHDOG_COUNTER=0
    if command -v tmux >/dev/null 2>&1; then
      _session="${AGENTCTL_SESSION_NAME:-codex-agent-system}"
      if tmux has-session -t "$_session" 2>/dev/null; then
        if ! tmux list-windows -t "$_session" -F '#{window_name}' 2>/dev/null | grep -qx 'queue'; then
          log_msg WARN strategy-loop "Watchdog: queue window missing — attempting recovery"
          _queue_cmd="bash $ROOT_DIR/scripts/multi-queue.sh 2>&1 | tee -a $LOG_DIR/queue-worker.log"
          tmux new-window -t "$_session" -n queue "$_queue_cmd" 2>/dev/null \
            && log_msg INFO strategy-loop "Watchdog: queue window recreated" \
            || log_msg WARN strategy-loop "Watchdog: failed to recreate queue window"
        fi
      fi
    fi
  fi

}

while true; do
  _strategy_loop_body || log_msg ERROR strategy-loop "Loop body crashed with exit code $? — recovering (iteration 19 function-based crash resilience)"

  sleep "$POLL_SECONDS"
done
