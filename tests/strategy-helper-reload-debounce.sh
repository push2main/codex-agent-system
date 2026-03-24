#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
STRATEGY_PID=""

cleanup() {
  if [ -n "$STRATEGY_PID" ]; then
    pkill -P "$STRATEGY_PID" >/dev/null 2>&1 || true
    if kill -0 "$STRATEGY_PID" 2>/dev/null; then
      kill "$STRATEGY_PID" >/dev/null 2>&1 || true
      wait "$STRATEGY_PID" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/queues" "$TEST_ROOT/projects" "$TEST_ROOT/codex-dashboard"

STRATEGY_STDOUT="$TMP_DIR/strategy.stdout"
(
  cd "$TEST_ROOT"
  STRATEGY_POLL_SECONDS=1 STRATEGY_HOT_RELOAD_DEBOUNCE_SECONDS=2 \
    bash "$TEST_ROOT/scripts/strategy-loop.sh" daemon codex-agent-system >"$STRATEGY_STDOUT" 2>&1
) &
STRATEGY_PID="$!"

for _ in $(seq 1 20); do
  if grep -q 'Strategy loop started in daemon mode' "$STRATEGY_STDOUT" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

grep -q 'Strategy loop started in daemon mode' "$STRATEGY_STDOUT"

printf '\n# strategy reload debounce test marker\n' >>"$TEST_ROOT/scripts/lib.sh"

sleep 1

if grep -q 'Hot reloading strategy loop in-place' "$STRATEGY_STDOUT" 2>/dev/null; then
  echo "strategy loop reloaded before helper drift was stable" >&2
  exit 1
fi

for _ in $(seq 1 10); do
  if grep -q 'Hot reloading strategy loop in-place' "$STRATEGY_STDOUT" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

grep -q 'Hot reloading strategy loop in-place' "$STRATEGY_STDOUT"

sleep 1

reload_count="$(grep -c 'Hot reloading strategy loop in-place' "$STRATEGY_STDOUT")"
[ "$reload_count" -eq 1 ]

echo "strategy helper reload debounce test passed"
