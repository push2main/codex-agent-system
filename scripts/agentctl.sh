#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"
install_error_trap agentctl

SESSION_NAME="${AGENTCTL_SESSION_NAME:-codex-agent-system}"
COMMAND="${1:-status}"
DASHBOARD_PORT_INPUT="${DASHBOARD_PORT:-}"
DASHBOARD_PORT_EXPLICIT=0
if [ "${DASHBOARD_PORT+x}" = "x" ] && [ -n "$DASHBOARD_PORT_INPUT" ]; then
  DASHBOARD_PORT_EXPLICIT=1
fi
DASHBOARD_HTTPS_INPUT="${DASHBOARD_HTTPS:-}"
DASHBOARD_HTTPS_EXPLICIT=0
if [ "${DASHBOARD_HTTPS+x}" = "x" ] && [ -n "$DASHBOARD_HTTPS_INPUT" ]; then
  DASHBOARD_HTTPS_EXPLICIT=1
fi
CODEX_DISABLE_VALUE="${CODEX_DISABLE:-0}"
QUEUE_POLL_SECONDS_VALUE="${QUEUE_POLL_SECONDS:-1}"
QUEUE_WORKERS_VALUE="${QUEUE_WORKERS:-4}"
STRATEGY_POLL_SECONDS_VALUE="${STRATEGY_POLL_SECONDS:-60}"
AUTO_PUSH_PR_VALUE="${AUTO_PUSH_PR:-0}"
SESSION_SLUG="$(printf '%s' "$SESSION_NAME" | tr -c '[:alnum:]._-' '-')"
if [ "$SESSION_NAME" = "codex-agent-system" ]; then
  RUNTIME_FILE="$LOG_DIR/agentctl-runtime.env"
else
  RUNTIME_FILE="$LOG_DIR/agentctl-runtime-$SESSION_SLUG.env"
fi
DASHBOARD_TLS_DIR="${DASHBOARD_TLS_DIR:-$LOG_DIR/dashboard-tls}"
DASHBOARD_TLS_KEY_FILE_VALUE="${DASHBOARD_TLS_KEY_FILE:-$DASHBOARD_TLS_DIR/dashboard-key.pem}"
DASHBOARD_TLS_CERT_FILE_VALUE="${DASHBOARD_TLS_CERT_FILE:-$DASHBOARD_TLS_DIR/dashboard-cert.pem}"
RUNTIME_HELPER_FILES=("${TRACKED_HELPER_SCRIPTS[@]}")

dashboard_url() {
  local scheme="$1"
  local port="$2"
  printf '%s://localhost:%s\n' "$scheme" "$port"
}

read_persisted_runtime_port() {
  awk -F= '$1=="dashboard_port" { print $2 }' "$RUNTIME_FILE" 2>/dev/null || true
}

read_persisted_runtime_scheme() {
  awk -F= '$1=="dashboard_scheme" { print $2 }' "$RUNTIME_FILE" 2>/dev/null || true
}

read_persisted_queue_helper_fingerprint() {
  read_helper_runtime_state_field "queue_helper_fingerprint"
}

queue_helper_fingerprint() {
  python3 - "$ROOT_DIR" "${RUNTIME_HELPER_FILES[@]}" <<'PY'
import hashlib
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
paths = [pathlib.Path(path) for path in sys.argv[2:]]
digest = hashlib.sha256()

for relative_path in paths:
    digest.update(relative_path.as_posix().encode("utf-8"))
    digest.update(b"\0")
    digest.update((root / relative_path).read_bytes())
    digest.update(b"\0")

print(digest.hexdigest())
PY
}

queue_helper_status() {
  local persisted_fingerprint current_fingerprint
  persisted_fingerprint="$(read_persisted_queue_helper_fingerprint)"
  if [ -z "$persisted_fingerprint" ]; then
    printf 'unknown\n'
    return 0
  fi

  current_fingerprint="$(queue_helper_fingerprint)"
  if [ "$persisted_fingerprint" = "$current_fingerprint" ]; then
    printf 'current\n'
  else
    printf 'stale\n'
  fi
}

queue_helper_warning() {
  local status="${1:-}"
  case "$status" in
    stale)
      printf '%s\n' "hot reload pending for updated runtime helpers"
      ;;
    unknown)
      printf '%s\n' "start or reload once to capture runtime helper fingerprint"
      ;;
  esac
}

queue_window_command() {
  printf "cd '%s' && AGENTCTL_RUNTIME_FILE='%s' CODEX_DISABLE='%s' QUEUE_POLL_SECONDS='%s' QUEUE_WORKERS='%s' AUTO_PUSH_PR='%s' bash '%s/scripts/multi-queue.sh'" \
    "$ROOT_DIR" "$RUNTIME_FILE" "$CODEX_DISABLE_VALUE" "$QUEUE_POLL_SECONDS_VALUE" "$QUEUE_WORKERS_VALUE" "$AUTO_PUSH_PR_VALUE" "$ROOT_DIR"
}

dashboard_window_command() {
  printf "cd '%s' && DASHBOARD_PORT='%s' DASHBOARD_HTTPS='%s' DASHBOARD_TLS_KEY_FILE='%s' DASHBOARD_TLS_CERT_FILE='%s' node '%s/codex-dashboard/server.js'" \
    "$ROOT_DIR" "$DASHBOARD_PORT" "$DASHBOARD_HTTPS_VALUE" "$DASHBOARD_TLS_KEY_FILE_VALUE" "$DASHBOARD_TLS_CERT_FILE_VALUE" "$ROOT_DIR"
}

strategy_window_command() {
  printf "cd '%s' && STRATEGY_POLL_SECONDS='%s' bash '%s/scripts/strategy-loop.sh'" \
    "$ROOT_DIR" "$STRATEGY_POLL_SECONDS_VALUE" "$ROOT_DIR"
}

ensure_window_command() {
  local window_name="$1"
  local window_command="$2"
  if tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qx "$window_name"; then
    tmux respawn-window -k -t "$SESSION_NAME:$window_name" "$window_command"
  else
    tmux new-window -t "$SESSION_NAME" -n "$window_name" "$window_command"
  fi
}

print_queue_helper_status() {
  local status="${1:-}"
  local warning
  if [ -z "$status" ]; then
    status="$(queue_helper_status)"
  fi
  printf 'queue_runtime_helpers=%s\n' "$status"
  warning="$(queue_helper_warning "$status")"
  if [ -n "$warning" ]; then
    printf 'queue_runtime_warning=%s\n' "$warning"
  fi
}

resolve_dashboard_port() {
  local runtime_port
  if [ "$DASHBOARD_PORT_EXPLICIT" -eq 1 ]; then
    printf '%s\n' "$DASHBOARD_PORT_INPUT"
    return 0
  fi

  runtime_port="$(read_persisted_runtime_port)"
  printf '%s\n' "${runtime_port:-3000}"
}

resolve_dashboard_scheme() {
  local runtime_scheme
  if [ "$DASHBOARD_HTTPS_EXPLICIT" -eq 1 ]; then
    if [ "$DASHBOARD_HTTPS_INPUT" = "1" ]; then
      printf 'https\n'
    else
      printf 'http\n'
    fi
    return 0
  fi

  runtime_scheme="$(read_persisted_runtime_scheme)"
  printf '%s\n' "${runtime_scheme:-http}"
}

DASHBOARD_PORT="$(resolve_dashboard_port)"
DASHBOARD_SCHEME="$(resolve_dashboard_scheme)"
DASHBOARD_HTTPS_VALUE=0
if [ "$DASHBOARD_SCHEME" = "https" ]; then
  DASHBOARD_HTTPS_VALUE=1
fi

port_in_use() {
  local port="${1:-$DASHBOARD_PORT}"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

read_runtime_port() {
  local runtime_port
  runtime_port="$(read_persisted_runtime_port)"
  printf '%s\n' "${runtime_port:-$DASHBOARD_PORT}"
}

read_runtime_scheme() {
  local runtime_scheme
  runtime_scheme="$(read_persisted_runtime_scheme)"
  printf '%s\n' "${runtime_scheme:-$DASHBOARD_SCHEME}"
}

ensure_tls_assets() {
  [ "$DASHBOARD_HTTPS_VALUE" = "1" ] || return 0

  require_command agentctl openssl
  if [ -s "$DASHBOARD_TLS_KEY_FILE_VALUE" ] && [ -s "$DASHBOARD_TLS_CERT_FILE_VALUE" ]; then
    return 0
  fi

  mkdir -p "$DASHBOARD_TLS_DIR" "$(dirname "$DASHBOARD_TLS_KEY_FILE_VALUE")" "$(dirname "$DASHBOARD_TLS_CERT_FILE_VALUE")"

  local tls_config ip_list ip_index
  tls_config="$DASHBOARD_TLS_DIR/dashboard-openssl.cnf"
  ip_list="$(
    node - <<'EOF'
const os = require("os");
const ips = [];
for (const entries of Object.values(os.networkInterfaces())) {
  for (const entry of entries || []) {
    if (entry && entry.family === "IPv4" && !entry.internal) {
      ips.push(entry.address);
    }
  }
}
process.stdout.write([...new Set(ips)].sort().join("\n"));
EOF
  )"

  cat >"$tls_config" <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
x509_extensions = v3_req

[dn]
CN = localhost

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
EOF

  ip_index=2
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    printf 'IP.%s = %s\n' "$ip_index" "$ip" >>"$tls_config"
    ip_index=$((ip_index + 1))
  done <<EOF
$ip_list
EOF

  openssl req \
    -x509 \
    -nodes \
    -newkey rsa:2048 \
    -keyout "$DASHBOARD_TLS_KEY_FILE_VALUE" \
    -out "$DASHBOARD_TLS_CERT_FILE_VALUE" \
    -days 365 \
    -config "$tls_config" >/dev/null 2>&1

  chmod 600 "$DASHBOARD_TLS_KEY_FILE_VALUE"
  log_msg INFO agentctl "Generated self-signed dashboard certificate at $DASHBOARD_TLS_CERT_FILE_VALUE"
}

dashboard_window_running() {
  tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qx 'dashboard'
}

strategy_window_running() {
  tmux list-windows -t "$SESSION_NAME" -F '#{window_name}' 2>/dev/null | grep -qx 'strategy'
}

start_session() {
  require_command agentctl tmux
  require_command agentctl node
  require_command agentctl lsof
  require_command agentctl python3

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    local runtime_port
    local runtime_scheme
    local queue_runtime_status
    update_restart_needed_status_for_helper_scripts
    runtime_port="$(read_runtime_port)"
    runtime_scheme="$(read_runtime_scheme)"
    queue_runtime_status="$(queue_helper_status)"
    log_msg INFO agentctl "tmux session $SESSION_NAME is already running on dashboard port $runtime_port"
    echo "session=$SESSION_NAME"
    echo "dashboard_url=$(dashboard_url "$runtime_scheme" "$runtime_port")"
    print_queue_helper_status "$queue_runtime_status"
    exit 0
  fi

  ensure_tls_assets
  if port_in_use "$DASHBOARD_PORT"; then
    log_msg ERROR agentctl "Dashboard port $DASHBOARD_PORT is already in use"
    echo "dashboard port $DASHBOARD_PORT is already in use"
    exit 1
  fi

  tmux new-session -d -s "$SESSION_NAME" -n queue "$(queue_window_command)"
  tmux new-window -t "$SESSION_NAME" -n dashboard "$(dashboard_window_command)"
  tmux new-window -t "$SESSION_NAME" -n strategy "$(strategy_window_command)"
  sleep 1
  if ! dashboard_window_running || ! strategy_window_running; then
    tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || true
    log_msg ERROR agentctl "Dashboard or strategy window failed to stay up on port $DASHBOARD_PORT"
    echo "dashboard or strategy failed to start on port $DASHBOARD_PORT"
    exit 1
  fi
  cat >"$RUNTIME_FILE" <<EOF
dashboard_port=$DASHBOARD_PORT
dashboard_scheme=$DASHBOARD_SCHEME
queue_helper_fingerprint=$(queue_helper_fingerprint)
queue_poll_seconds=$QUEUE_POLL_SECONDS_VALUE
queue_workers=$QUEUE_WORKERS_VALUE
session_name=$SESSION_NAME
updated_at=$(now_utc)
EOF
  persist_queue_runtime_config "$QUEUE_POLL_SECONDS_VALUE" "$QUEUE_WORKERS_VALUE"
  clear_restart_needed_status
  log_msg INFO agentctl "Started tmux session $SESSION_NAME on $DASHBOARD_SCHEME port $DASHBOARD_PORT"
  echo "started tmux session $SESSION_NAME"
  echo "dashboard_url=$(dashboard_url "$DASHBOARD_SCHEME" "$DASHBOARD_PORT")"
}

stop_session() {
  require_command agentctl tmux

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    tmux kill-session -t "$SESSION_NAME"
    log_msg INFO agentctl "Stopped tmux session $SESSION_NAME"
    echo "stopped tmux session $SESSION_NAME"
    exit 0
  fi

  log_msg WARN agentctl "tmux session $SESSION_NAME is not running"
  echo "tmux session $SESSION_NAME is not running"
}

show_status() {
  require_command agentctl tmux
  require_command agentctl python3
  ensure_runtime_dirs
  update_restart_needed_status_for_helper_scripts
  local runtime_port
  local runtime_scheme
  runtime_port="$(read_runtime_port)"
  runtime_scheme="$(read_runtime_scheme)"

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "session=$SESSION_NAME"
    echo "dashboard_url=$(dashboard_url "$runtime_scheme" "$runtime_port")"
    echo "dashboard_window=$(dashboard_window_running && echo running || echo missing)"
    echo "strategy_window=$(strategy_window_running && echo running || echo missing)"
    print_queue_helper_status
    echo "tmux_panes:"
    tmux list-panes -t "$SESSION_NAME" -a -F '  #{session_name}:#{window_name}: pid=#{pane_pid} cmd=#{pane_current_command} dead=#{pane_dead}'
    echo "status_file:"
    sed 's/^/  /' "$STATUS_FILE"
    exit 0
  fi

  echo "session=$SESSION_NAME"
  echo "state=stopped"
  echo "dashboard_url=$(dashboard_url "$runtime_scheme" "$runtime_port")"
}

show_logs() {
  ensure_runtime_dirs
  tail -n "${2:-200}" "$SYSTEM_LOG"
}

queue_reload_safe_now() {
  local state
  state="$(read_status_field_default "state" "idle")"
  case "$state" in
    running|retrying)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

reload_session() {
  require_command agentctl tmux
  require_command agentctl node
  require_command agentctl lsof
  require_command agentctl python3

  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    start_session
    return 0
  fi

  ensure_tls_assets
  ensure_window_command "dashboard" "$(dashboard_window_command)"
  ensure_window_command "strategy" "$(strategy_window_command)"

  local queue_reload_mode="deferred"
  if queue_reload_safe_now; then
    ensure_window_command "queue" "$(queue_window_command)"
    clear_restart_needed_status
    queue_reload_mode="immediate"
  else
    request_queue_hot_reload "agentctl_reload"
    update_restart_needed_status_for_helper_scripts
  fi

  cat >"$RUNTIME_FILE" <<EOF
dashboard_port=$DASHBOARD_PORT
dashboard_scheme=$DASHBOARD_SCHEME
queue_helper_fingerprint=$(queue_helper_fingerprint)
queue_poll_seconds=$QUEUE_POLL_SECONDS_VALUE
queue_workers=$QUEUE_WORKERS_VALUE
session_name=$SESSION_NAME
updated_at=$(now_utc)
EOF
  persist_queue_runtime_config "$QUEUE_POLL_SECONDS_VALUE" "$QUEUE_WORKERS_VALUE"

  sleep 1
  if ! dashboard_window_running || ! strategy_window_running; then
    log_msg ERROR agentctl "Dashboard or strategy window failed to stay up during reload"
    echo "dashboard or strategy failed to reload"
    exit 1
  fi

  echo "reloaded tmux session $SESSION_NAME"
  echo "dashboard_url=$(dashboard_url "$DASHBOARD_SCHEME" "$DASHBOARD_PORT")"
  echo "queue_reload=$queue_reload_mode"
  print_queue_helper_status
}

case "$COMMAND" in
  start)
    start_session
    ;;
  reload)
    reload_session
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
    echo "usage: agentctl.sh {start|reload|stop|status|logs}" >&2
    exit 2
    ;;
esac
