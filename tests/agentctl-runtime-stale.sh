#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
SESSION_NAME="agentctl-runtime-stale-$$"
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
  local port=4500
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

[ -n "$(awk -F= '$1=="queue_helper_fingerprint" { print $2 }' "$RUNTIME_FILE")" ]

CURRENT_STATUS="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh status
)"

printf '%s\n' "$CURRENT_STATUS" | grep -qx "queue_runtime_helpers=current"

printf '\n# stale runtime helper fixture\n' >>"$TEST_ROOT/scripts/lib.sh"

STALE_STATUS="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh status
)"

printf '%s\n' "$STALE_STATUS" | grep -qx "queue_runtime_helpers=stale"
printf '%s\n' "$STALE_STATUS" | grep -qx "queue_runtime_warning=restart required to load updated queue helpers"
