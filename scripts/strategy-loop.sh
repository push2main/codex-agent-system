#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap strategy-loop

MODE="${1:-daemon}"
PROJECT_NAME="${2:-codex-agent-system}"
POLL_SECONDS="${STRATEGY_POLL_SECONDS:-60}"
OUTPUT_FILE="$LOG_DIR/strategy-latest.json"
STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS_DEFAULT="${STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS:-2}"
STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS="$STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS_DEFAULT"
STRATEGY_HOT_RELOAD_STATE_FILE="$LOG_DIR/strategy-hot-reload.state"

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
  rm -f "$STRATEGY_HOT_RELOAD_STATE_FILE"
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

while true; do
  if bash "$ROOT_DIR/agents/strategy.sh" "$PROJECT_NAME" "$OUTPUT_FILE" >/dev/null; then
    board_count="$(jq -er '(.data.board_updates // .data.board_tasks // []) | length' "$OUTPUT_FILE" 2>/dev/null || printf '0')"
    if [ "$board_count" -gt 0 ]; then
      log_msg INFO strategy-loop "Applied $board_count board task update(s) for $PROJECT_NAME"
    fi
  else
    log_msg ERROR strategy-loop "Strategy run failed for $PROJECT_NAME"
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
    PROCESS_HELPER_MARKER="$current_marker"
    clear_strategy_hot_reload_state
    log_msg INFO strategy-loop "Hot reloading strategy loop in-place"
    exec env \
      STRATEGY_PROCESS_HELPER_MARKER="$PROCESS_HELPER_MARKER" \
      STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS="$STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS" \
      bash "$ROOT_DIR/scripts/strategy-loop.sh" "$MODE" "$PROJECT_NAME"
  fi
  clear_strategy_hot_reload_state
  sleep "$POLL_SECONDS"
done
