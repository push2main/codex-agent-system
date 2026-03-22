#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
QUEUE_PID=""

cleanup() {
  if [ -n "$QUEUE_PID" ] && kill -0 "$QUEUE_PID" 2>/dev/null; then
    kill "$QUEUE_PID" >/dev/null 2>&1 || true
    wait "$QUEUE_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects/reload-smoke"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-one",
      "title": "First queued task",
      "project": "reload-smoke",
      "status": "approved",
      "effort": 1,
      "confidence": 0.9,
      "category": "ui"
    },
    {
      "id": "task-two",
      "title": "Second queued task",
      "project": "reload-smoke",
      "status": "approved",
      "effort": 1,
      "confidence": 0.9,
      "category": "ui"
    }
  ]
}
EOF

cat >"$TEST_ROOT/queues/reload-smoke.txt" <<'EOF'
First queued task
Second queued task
EOF

cat >"$TEST_ROOT/scripts/queue-worker.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/lib.sh"

LANE_ID="${1:-}"
PROJECT_DIR="${2:-}"
PROJECT_NAME="${3:-}"
TASK="${4:-}"
RETRY_COUNT="${5:-0}"
TASK_PROVIDER="${6:-codex}"

write_status "running" "$PROJECT_NAME" "$TASK" "RUNNING" "lane=$LANE_ID retry=$RETRY_COUNT"
sleep 3
sync_task_registry_execution_state \
  "$PROJECT_NAME" \
  "$TASK" \
  "completed" \
  "execute_success" \
  "Queue execution completed successfully." \
  "$((RETRY_COUNT + 1))" \
  "$MAX_AGENT_RETRIES" \
  "$TASK_PROVIDER" \
  "$LANE_ID" >/dev/null || true
exit 0
EOF
chmod +x "$TEST_ROOT/scripts/queue-worker.sh"

QUEUE_STDOUT="$TMP_DIR/queue.stdout"
(
  cd "$TEST_ROOT"
  QUEUE_WORKERS=1 QUEUE_POLL_SECONDS=1 bash "$TEST_ROOT/scripts/multi-queue.sh" daemon >"$QUEUE_STDOUT" 2>&1
) &
QUEUE_PID="$!"

for _ in $(seq 1 20); do
  if ! grep -q '^First queued task$' "$TEST_ROOT/queues/reload-smoke.txt" 2>/dev/null; then
    break
  fi
  sleep 0.2
done

grep -q '^Second queued task$' "$TEST_ROOT/queues/reload-smoke.txt"

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  request_queue_hot_reload "queue_hot_reload_drain_test"
)

sleep 1

grep -q '^Second queued task$' "$TEST_ROOT/queues/reload-smoke.txt"

for _ in $(seq 1 20); do
  if grep -q 'Hot reloading queue helpers in-place' "$QUEUE_STDOUT" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

grep -q 'Hot reloading queue helpers in-place' "$QUEUE_STDOUT"

echo "queue hot reload drain test passed"
