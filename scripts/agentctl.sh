#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap agentctl

SESSION_NAME="codex-agent-system"
COMMAND="${1:-status}"
DASHBOARD_PORT="${DASHBOARD_PORT:-3000}"
CODEX_DISABLE_VALUE="${CODEX_DISABLE:-0}"
QUEUE_POLL_SECONDS_VALUE="${QUEUE_POLL_SECONDS:-3}"
AUTO_PUSH_PR_VALUE="${AUTO_PUSH_PR:-0}"
RUNTIME_FILE="$LOG_DIR/agentctl-runtime.env"

port_in_use() {
  lsof -nP -iTCP:"$DASHBOARD_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

dashboard_window_running() {
  tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qx 'dashboard'
}

start_session() {
  require_command agentctl tmux
  require_command agentctl node
  require_command agentctl lsof

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    log_msg INFO agentctl "tmux session $SESSION_NAME is already running"
    echo "tmux session $SESSION_NAME is already running"
    exit 0
  fi

  if port_in_use; then
    log_msg ERROR agentctl "Dashboard port $DASHBOARD_PORT is already in use"
    echo "dashboard port $DASHBOARD_PORT is already in use"
    exit 1
  fi

  tmux new-session -d -s "$SESSION_NAME" -n queue "cd '$ROOT_DIR' && CODEX_DISABLE='$CODEX_DISABLE_VALUE' QUEUE_POLL_SECONDS='$QUEUE_POLL_SECONDS_VALUE' AUTO_PUSH_PR='$AUTO_PUSH_PR_VALUE' bash '$ROOT_DIR/scripts/multi-queue.sh'"
  tmux new-window -t "$SESSION_NAME" -n dashboard "cd '$ROOT_DIR' && DASHBOARD_PORT='$DASHBOARD_PORT' node '$ROOT_DIR/codex-dashboard/server.js'"
  sleep 1
  if ! dashboard_window_running; then
    tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
    log_msg ERROR agentctl "Dashboard window failed to stay up on port $DASHBOARD_PORT"
    echo "dashboard failed to start on port $DASHBOARD_PORT"
    exit 1
  fi
  cat >"$RUNTIME_FILE" <<EOF
dashboard_port=$DASHBOARD_PORT
session_name=$SESSION_NAME
updated_at=$(now_utc)
EOF
  log_msg INFO agentctl "Started tmux session $SESSION_NAME on dashboard port $DASHBOARD_PORT"
  echo "started tmux session $SESSION_NAME"
}

stop_session() {
  require_command agentctl tmux

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux kill-session -t "$SESSION_NAME"
    rm -f "$RUNTIME_FILE"
    log_msg INFO agentctl "Stopped tmux session $SESSION_NAME"
    echo "stopped tmux session $SESSION_NAME"
    exit 0
  fi

  log_msg WARN agentctl "tmux session $SESSION_NAME is not running"
  echo "tmux session $SESSION_NAME is not running"
}

show_status() {
  require_command agentctl tmux
  ensure_runtime_dirs
  local runtime_port
  runtime_port="$(awk -F= '$1=="dashboard_port" { print $2 }' "$RUNTIME_FILE" 2>/dev/null || true)"
  runtime_port="${runtime_port:-$DASHBOARD_PORT}"

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "session=$SESSION_NAME"
    echo "dashboard_url=http://localhost:$runtime_port"
    echo "dashboard_window=$(dashboard_window_running && echo running || echo missing)"
    echo "tmux_panes:"
    tmux list-panes -t "$SESSION_NAME" -a -F '  #{session_name}:#{window_name}: pid=#{pane_pid} cmd=#{pane_current_command} dead=#{pane_dead}'
    echo "status_file:"
    sed 's/^/  /' "$STATUS_FILE"
    exit 0
  fi

  echo "session=$SESSION_NAME"
  echo "state=stopped"
  echo "dashboard_url=http://localhost:$runtime_port"
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
