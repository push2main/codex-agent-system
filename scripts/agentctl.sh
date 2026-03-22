#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

SESSION_NAME="codex-agent-system"
COMMAND="${1:-status}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3000}"
CODEX_DISABLE_VALUE="${CODEX_DISABLE:-0}"

start_session() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "tmux session $SESSION_NAME is already running"
    exit 0
  fi

  tmux new-session -d -s "$SESSION_NAME" -n queue "cd '$ROOT_DIR' && CODEX_DISABLE='$CODEX_DISABLE_VALUE' bash '$ROOT_DIR/scripts/multi-queue.sh'"
  tmux new-window -t "$SESSION_NAME" -n dashboard "cd '$ROOT_DIR' && DASHBOARD_PORT='$DASHBOARD_PORT' node '$ROOT_DIR/codex-dashboard/server.js'"
  echo "started tmux session $SESSION_NAME"
}

stop_session() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux kill-session -t "$SESSION_NAME"
    echo "stopped tmux session $SESSION_NAME"
    exit 0
  fi
  echo "tmux session $SESSION_NAME is not running"
}

show_status() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux list-windows -t "$SESSION_NAME"
    exit 0
  fi
  echo "tmux session $SESSION_NAME is not running"
}

show_logs() {
  ensure_runtime_dirs
  tail -n "${2:-200}" "$SYSTEM_LOG"
}

case "$COMMAND" in
  start)
    start_session
    ;;
  stop)
    stop_session
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs "$@"
    ;;
  *)
    echo "usage: agentctl.sh {start|stop|status|logs}" >&2
    exit 2
    ;;
esac
