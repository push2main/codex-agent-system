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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-queue" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-approved",
      "title": "Approved registry task",
      "project": "codex-agent-system",
      "status": "approved"
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-queue/task-approved.json" <<'EOF'
{
  "id": "task-approved",
  "task": "Approved registry task",
  "title": "Approved registry task",
  "project": "codex-agent-system",
  "status": "queued"
}
EOF

cat >"$TEST_ROOT/codex-queue/task-stale.json" <<'EOF'
{
  "id": "task-stale",
  "task": "Stale legacy queue task",
  "title": "Stale legacy queue task",
  "project": "codex-agent-system",
  "status": "queued"
}
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  sync_legacy_queue_mirror >/dev/null
)

test -f "$TEST_ROOT/codex-queue/task-approved.json"
test ! -f "$TEST_ROOT/codex-queue/task-stale.json"

echo "legacy queue json prune test passed"
