#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
SESSION_NAME="agentctl-port-test-$$"
DUMMY_PID=""
RUNTIME_FILE="$TEST_ROOT/codex-logs/agentctl-runtime-$SESSION_NAME.env"

cleanup() {
  if [ -d "$TEST_ROOT" ]; then
    (
      cd "$TEST_ROOT"
      AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh stop >/dev/null 2>&1 || true
    )
  fi
  if [ -n "$DUMMY_PID" ]; then
    kill "$DUMMY_PID" >/dev/null 2>&1 || true
    wait "$DUMMY_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

find_free_port() {
  local port=4300
  while port_in_use "$port"; do
    port=$((port + 1))
  done
  printf '%s\n' "$port"
}

port_in_use() {
  local port="$1"
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
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

FIXED_PORT="$(find_free_port)"

START_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" DASHBOARD_PORT="$FIXED_PORT" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 bash scripts/agentctl.sh start
)"

printf '%s\n' "$START_OUTPUT" | grep -qx "dashboard_url=http://localhost:$FIXED_PORT"

STATUS_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" DASHBOARD_PORT="$FIXED_PORT" bash scripts/agentctl.sh status
)"

printf '%s\n' "$STATUS_OUTPUT" | grep -qx "session=$SESSION_NAME"
printf '%s\n' "$STATUS_OUTPUT" | grep -qx "dashboard_url=http://localhost:$FIXED_PORT"
printf '%s\n' "$STATUS_OUTPUT" | grep -qx "dashboard_window=running"

(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh stop >/dev/null
)

RESTART_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 bash scripts/agentctl.sh start
)"

printf '%s\n' "$RESTART_OUTPUT" | grep -qx "dashboard_url=http://localhost:$FIXED_PORT"

SECOND_START_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh start
)"

printf '%s\n' "$SECOND_START_OUTPUT" | grep -qx "session=$SESSION_NAME"
printf '%s\n' "$SECOND_START_OUTPUT" | grep -qx "dashboard_url=http://localhost:$FIXED_PORT"

RUNTIME_PORT="$(awk -F= '$1=="dashboard_port" { print $2 }' "$RUNTIME_FILE")"
[ "$RUNTIME_PORT" = "$FIXED_PORT" ]

python3 - "$FIXED_PORT" <<'PY'
import json
import sys
import urllib.request

port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/status", timeout=2) as response:
    payload = json.load(response)

assert payload["port"] == int(port)
PY

(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh stop >/dev/null
)

python3 -m http.server "$FIXED_PORT" --bind 127.0.0.1 >"$TMP_DIR/occupied-port.log" 2>&1 &
DUMMY_PID=$!

for _ in $(seq 1 20); do
  if port_in_use "$FIXED_PORT"; then
    break
  fi
  sleep 0.1
done

if ! port_in_use "$FIXED_PORT"; then
  echo "failed to reserve occupied port $FIXED_PORT" >&2
  exit 1
fi

FAILED_START_OUTPUT="$(
  cd "$TEST_ROOT"
  set +e
  AGENTCTL_SESSION_NAME="$SESSION_NAME" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 bash scripts/agentctl.sh start 2>&1
  rc=$?
  printf '__RC=%s\n' "$rc"
)"

printf '%s\n' "$FAILED_START_OUTPUT" | grep -Fqx "dashboard port $FIXED_PORT is already in use"
printf '%s\n' "$FAILED_START_OUTPUT" | grep -qx "__RC=1"
