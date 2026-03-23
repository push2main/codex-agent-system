#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
mkdir -p "$TEST_ROOT/codex-memory"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-ui-medium",
      "title": "medium ui task",
      "project": "timeout-smoke",
      "category": "ui",
      "effort": 2,
      "status": "approved",
      "created_at": "2026-03-23T08:00:00Z",
      "updated_at": "2026-03-23T08:00:00Z"
    },
    {
      "id": "task-manual-heavy",
      "title": "manual heavy task",
      "project": "timeout-smoke",
      "category": "stability",
      "effort": 3,
      "status": "approved",
      "task_intent": {"source": "manual_assessment"},
      "created_at": "2026-03-23T08:00:01Z",
      "updated_at": "2026-03-23T08:00:01Z"
    },
    {
      "id": "task-project-xlarge",
      "title": "project xlarge task",
      "project": "timeout-smoke",
      "category": "project",
      "effort": 4,
      "status": "approved",
      "created_at": "2026-03-23T08:00:02Z",
      "updated_at": "2026-03-23T08:00:02Z"
    }
  ]
}
EOF

assert_timeout() {
  local task_name="$1"
  local base_timeout="$2"
  local expected="$3"
  local actual

  actual="$(
    cd "$TEST_ROOT" &&
    TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
    TASK_TIMEOUT_SECONDS="$base_timeout" \
    bash -lc "source '$TEST_ROOT/scripts/lib.sh'; resolve_task_timeout_seconds 'timeout-smoke' '$task_name' '$base_timeout'"
  )"

  if [ "$actual" != "$expected" ]; then
    printf 'expected timeout %s for %s but got %s\n' "$expected" "$task_name" "$actual" >&2
    exit 1
  fi
}

assert_timeout "medium ui task" 300 420
assert_timeout "manual heavy task" 300 720
assert_timeout "project xlarge task" 300 900
assert_timeout "missing task" 1500 1200

echo "queue timeout resolution test passed"
