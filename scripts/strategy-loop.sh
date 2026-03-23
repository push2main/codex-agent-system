#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap strategy-loop

MODE="${1:-daemon}"
PROJECT_NAME="${2:-codex-agent-system}"
POLL_SECONDS="${STRATEGY_POLL_SECONDS:-60}"
OUTPUT_FILE="$LOG_DIR/strategy-latest.json"

require_command strategy-loop jq
ensure_runtime_dirs
log_msg INFO strategy-loop "Strategy loop started in $MODE mode for $PROJECT_NAME"

PROCESS_HELPER_MARKER="${STRATEGY_PROCESS_HELPER_MARKER:-$(helper_scripts_marker)}"

while true; do
  if bash "$ROOT_DIR/agents/strategy.sh" "$PROJECT_NAME" "$OUTPUT_FILE" >/dev/null; then
    board_count="$(jq -er '.data.board_tasks | length' "$OUTPUT_FILE" 2>/dev/null || printf '0')"
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
    PROCESS_HELPER_MARKER="$(helper_scripts_marker)"
    log_msg INFO strategy-loop "Hot reloading strategy loop in-place"
    exec env STRATEGY_PROCESS_HELPER_MARKER="$PROCESS_HELPER_MARKER" bash "$ROOT_DIR/scripts/strategy-loop.sh" "$MODE" "$PROJECT_NAME"
  fi
  sleep "$POLL_SECONDS"
done
