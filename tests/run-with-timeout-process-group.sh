#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
PID_FILE="$TMP_DIR/child.pid"
SPAWNER="$TMP_DIR/spawn-child.sh"

cleanup() {
  if [ -f "$PID_FILE" ]; then
    child_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${child_pid:-}" ]; then
      kill "$child_pid" 2>/dev/null || true
    fi
  fi
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

cat >"$SPAWNER" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

pid_file="$1"
sleep 30 &
child_pid=$!
printf '%s\n' "$child_pid" >"$pid_file"
wait "$child_pid"
EOF
chmod +x "$SPAWNER"

set +e
stderr_output="$(
  python3 "$ROOT_DIR/scripts/run-with-timeout.py" 1 bash "$SPAWNER" "$PID_FILE" 2>&1
)"
status=$?
set -e

if [ "$status" -ne 124 ]; then
  echo "expected run-with-timeout.py to return 124 on timeout, got $status" >&2
  exit 1
fi

if [[ "$stderr_output" != TIMEOUT\ after\ 1\ seconds:* ]]; then
  echo "expected timeout banner on stderr, got: $stderr_output" >&2
  exit 1
fi

if [ ! -f "$PID_FILE" ]; then
  echo "expected child pid file to be written before timeout" >&2
  exit 1
fi

child_pid="$(cat "$PID_FILE")"
sleep 0.2
if kill -0 "$child_pid" 2>/dev/null; then
  echo "expected timed out child process tree to be terminated, but pid $child_pid is still alive" >&2
  exit 1
fi

echo "run-with-timeout process-group cleanup test passed"
