#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs/queue-retries" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-reapproval",
      "title": "inventory decision path",
      "project": "superheld",
      "status": "approved",
      "updated_at": "2026-03-29T23:35:28Z",
      "approved_at": "2026-03-29T23:35:28Z",
      "cumulative_attempts": 4,
      "execution": {
        "attempt": 4,
        "state": "approved",
        "result": "FAILURE"
      },
      "history": [
        {
          "at": "2026-03-29T23:30:45Z",
          "action": "execute_failure",
          "from_status": "running",
          "to_status": "failed",
          "project": "superheld",
          "queue_task": "inventory decision path",
          "note": "Queue execution failed after exhausting retries."
        },
        {
          "at": "2026-03-29T23:35:28Z",
          "action": "manual_requeue",
          "from_status": "failed",
          "to_status": "approved",
          "project": "superheld",
          "queue_task": "inventory decision path",
          "note": "Requeued after code fix."
        }
      ]
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  ensure_runtime_dirs

  if [ "$(get_task_retry_count "superheld" "inventory decision path")" != "4" ]; then
    echo "expected cumulative retry count to preserve historical attempts" >&2
    exit 1
  fi

  if [ "$(get_task_dispatch_retry_count "superheld" "inventory decision path")" != "0" ]; then
    echo "expected fresh approval cycle to dispatch with retry_count=0 when no retry file exists" >&2
    exit 1
  fi

  set_task_retry_count "superheld" "inventory decision path" "1"

  if [ "$(get_task_dispatch_retry_count "superheld" "inventory decision path")" != "1" ]; then
    echo "expected dispatch retry count to follow the queue retry file once a same-cycle retry exists" >&2
    exit 1
  fi
)

echo "retry dispatch count fresh approval cycle test passed"
