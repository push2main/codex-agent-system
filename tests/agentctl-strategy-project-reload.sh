#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
SESSION_NAME="agentctl-strategy-project-test-$$"
RUNTIME_FILE="$TEST_ROOT/codex-logs/agentctl-runtime-$SESSION_NAME.env"

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
  local port=4700
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
  AGENTCTL_SESSION_NAME="$SESSION_NAME" AGENTCTL_STRATEGY_PROJECT=superheld DASHBOARD_PORT="$RUNTIME_PORT" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 STRATEGY_POLL_SECONDS=60 bash scripts/agentctl.sh start >/dev/null
)

sleep 2

grep -qx 'strategy_project=superheld' "$RUNTIME_FILE"
grep -Fq 'Strategy loop started in daemon mode for superheld' "$TEST_ROOT/codex-logs/system.log"

printf '\n# reload fixture\n' >>"$TEST_ROOT/scripts/strategy-loop.sh"

RELOAD_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" DASHBOARD_PORT="$RUNTIME_PORT" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 STRATEGY_POLL_SECONDS=60 bash scripts/agentctl.sh reload
)"

printf '%s\n' "$RELOAD_OUTPUT" | grep -qx "reloaded tmux session $SESSION_NAME"
grep -qx 'strategy_project=superheld' "$RUNTIME_FILE"

if [ "$(grep -c 'Strategy loop started in daemon mode for superheld' "$TEST_ROOT/codex-logs/system.log")" -lt 2 ]; then
  echo "expected start and reload to both launch strategy-loop for superheld" >&2
  exit 1
fi

if grep -Fq 'Strategy loop started in daemon mode for codex-agent-system' "$TEST_ROOT/codex-logs/system.log"; then
  echo "strategy-loop unexpectedly fell back to codex-agent-system during reload" >&2
  exit 1
fi
