#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
QUEUE_PID=""

cleanup() {
  if [ -n "$QUEUE_PID" ]; then
    pkill -P "$QUEUE_PID" >/dev/null 2>&1 || true
    if kill -0 "$QUEUE_PID" 2>/dev/null; then
      kill "$QUEUE_PID" >/dev/null 2>&1 || true
      wait "$QUEUE_PID" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf "$TMP_DIR" >/dev/null 2>&1 || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects/reload-smoke"

QUEUE_STDOUT="$TMP_DIR/queue.stdout"
(
  cd "$TEST_ROOT"
  QUEUE_WORKERS=1 QUEUE_POLL_SECONDS=1 QUEUE_HOT_RELOAD_DEBOUNCE_SECONDS=2 \
    bash "$TEST_ROOT/scripts/multi-queue.sh" daemon >"$QUEUE_STDOUT" 2>&1
) &
QUEUE_PID="$!"

for _ in $(seq 1 20); do
  if grep -q 'Queue processor started in daemon mode' "$QUEUE_STDOUT" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

grep -q 'Queue processor started in daemon mode' "$QUEUE_STDOUT"

printf '\n# queue reload debounce test marker\n' >>"$TEST_ROOT/scripts/lib.sh"

sleep 1

if grep -q 'Hot reloading queue helpers in-place' "$QUEUE_STDOUT" 2>/dev/null; then
  echo "queue reloaded before helper drift was stable" >&2
  exit 1
fi

for _ in $(seq 1 10); do
  if grep -q 'Hot reloading queue helpers in-place' "$QUEUE_STDOUT" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

grep -q 'Hot reloading queue helpers in-place' "$QUEUE_STDOUT"

sleep 1

reload_count="$(grep -c 'Hot reloading queue helpers in-place' "$QUEUE_STDOUT")"
[ "$reload_count" -eq 1 ]

echo "queue helper reload debounce test passed"
