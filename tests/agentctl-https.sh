#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
SESSION_NAME="agentctl-https-test-$$"
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
  local port=4400
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

HTTPS_PORT="$(find_free_port)"

START_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" DASHBOARD_PORT="$HTTPS_PORT" DASHBOARD_HTTPS=1 CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 bash scripts/agentctl.sh start
)"

printf '%s\n' "$START_OUTPUT" | grep -qx "dashboard_url=https://localhost:$HTTPS_PORT"
[ -s "$TEST_ROOT/codex-logs/dashboard-tls/dashboard-key.pem" ]
[ -s "$TEST_ROOT/codex-logs/dashboard-tls/dashboard-cert.pem" ]

STATUS_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" DASHBOARD_PORT="$HTTPS_PORT" DASHBOARD_HTTPS=1 bash scripts/agentctl.sh status
)"

printf '%s\n' "$STATUS_OUTPUT" | grep -qx "session=$SESSION_NAME"
printf '%s\n' "$STATUS_OUTPUT" | grep -qx "dashboard_url=https://localhost:$HTTPS_PORT"
printf '%s\n' "$STATUS_OUTPUT" | grep -qx "dashboard_window=running"

[ "$(awk -F= '$1=="dashboard_scheme" { print $2 }' "$RUNTIME_FILE")" = "https" ]

(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" bash scripts/agentctl.sh stop >/dev/null
)

RESTART_OUTPUT="$(
  cd "$TEST_ROOT"
  AGENTCTL_SESSION_NAME="$SESSION_NAME" CODEX_DISABLE=1 QUEUE_POLL_SECONDS=60 bash scripts/agentctl.sh start
)"

printf '%s\n' "$RESTART_OUTPUT" | grep -qx "dashboard_url=https://localhost:$HTTPS_PORT"

python3 - "$HTTPS_PORT" <<'PY'
import json
import ssl
import sys
import urllib.request

port = sys.argv[1]
context = ssl._create_unverified_context()
with urllib.request.urlopen(f"https://127.0.0.1:{port}/api/status", timeout=2, context=context) as response:
    payload = json.load(response)

assert payload["port"] == int(port)
assert payload["protocol"] == "https"
PY
