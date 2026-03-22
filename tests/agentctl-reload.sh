#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
SESSION_NAME="agentctl-reload-test-$$"

cleanup() {
  if [ -d "$TEST_ROOT" ]; then
    (
      cd "$TEST_ROOT"
      AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh stop >/dev/null 2>&1 || true
    )
  fi
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

port_in_use() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

find_free_port() {
  local port=4600
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/codex-dashboard" "$TEST_ROOT/codex-dashboard"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
cp -R "$ROOT_DIR/tests" "$TEST_ROOT/tests"
cp -R "$ROOT_DIR/codex-memory" "$TEST_ROOT/codex-memory"
cp -R "$ROOT_DIR/codex-learning" "$TEST_ROOT/codex-learning"
cp -R "$ROOT_DIR/projects" "$TEST_ROOT/projects"
cp -R "$ROOT_DIR/queues" "$TEST_ROOT/queues"
cp "$ROOT_DIR/README.md" "$TEST_ROOT/README.md"
cp "$ROOT_DIR/AGENTS.md" "$TEST_ROOT/AGENTS.md"
cp "$ROOT_DIR/TASK_RESPONSE.md" "$TEST_ROOT/TASK_RESPONSE.md"
cp "$ROOT_DIR/system-rules.md" "$TEST_ROOT/system-rules.md"

rm -rf "$TEST_ROOT/queues"
mkdir -p "$TEST_ROOT/queues"

RUNTIME_PORT="$(find_free_port)"

(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" DASHBOARD_PORT="$RUNTIME_PORT" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 bash scripts/agentctl.sh start >/dev/null
)

printf '\n# reload fixture\n' >>"$TEST_ROOT/scripts/strategy-loop.sh"

RELOAD_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" DASHBOARD_PORT="$RUNTIME_PORT" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 bash scripts/agentctl.sh reload
)"

printf '%s\n' "$RELOAD_OUTPUT" | grep -qx "reloaded tmux session $SESSION_NAME"
printf '%s\n' "$RELOAD_OUTPUT" | grep -qx "dashboard_url=http://localhost:$RUNTIME_PORT"
printf '%s\n' "$RELOAD_OUTPUT" | grep -Eq '^queue_reload=(immediate|deferred)$'
printf '%s\n' "$RELOAD_OUTPUT" | grep -qx "queue_runtime_helpers=current"
