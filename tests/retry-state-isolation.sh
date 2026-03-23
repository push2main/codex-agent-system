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
      "id": "task-old-shared-title",
      "title": "shared retry title",
      "project": "codex-agent-system",
      "status": "failed",
      "updated_at": "2026-03-23T09:00:00Z",
      "execution": {
        "attempt": 2,
        "state": "failed",
        "result": "FAILURE"
      }
    },
    {
      "id": "task-new-shared-title",
      "title": "shared retry title",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "2026-03-23T10:00:00Z",
      "execution": {
        "attempt": 1,
        "state": "retrying",
        "result": "FAILURE"
      }
    }
  ]
}
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  ensure_runtime_dirs

  legacy_hashed_file="$QUEUE_RETRY_DIR/$(printf '%s::%s' 'codex-agent-system' 'shared retry title' | shasum -a 256 | awk '{ print $1 }').retry"
  scoped_hashed_file="$QUEUE_RETRY_DIR/$(printf '%s' 'task-id::codex-agent-system::task-new-shared-title' | shasum -a 256 | awk '{ print $1 }').retry"

  printf '2\n' >"$legacy_hashed_file"

  [ "$(get_task_retry_count "codex-agent-system" "shared retry title")" = "1" ]

  set_task_retry_count "codex-agent-system" "shared retry title" "1"

  grep -qx '1' "$scoped_hashed_file"
  test ! -e "$legacy_hashed_file"

  clear_task_retry_count "codex-agent-system" "shared retry title"

  test ! -e "$scoped_hashed_file"
)

echo "retry state isolation test passed"
