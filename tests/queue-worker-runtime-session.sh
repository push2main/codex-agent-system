#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/session-worker"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/projects" \
  "$TEST_ROOT/queues" \
  "$PROJECT_DIR"

cat >"$TEST_ROOT/agents/orchestrator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
project_dir="${1:-}"
printf 'worker-session\n' >"$project_dir/worker.txt"
exit 0
EOF
chmod +x "$TEST_ROOT/agents/orchestrator.sh"

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" checkout -q -b main
printf 'fixture\n' >"$PROJECT_DIR/README.md"
git -C "$PROJECT_DIR" add README.md
git -C "$PROJECT_DIR" -c user.name='Test User' -c user.email='test@example.com' commit -q -m 'initial'

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-worker-session",
      "title": "Persist queue-worker runtime session state",
      "project": "session-worker",
      "status": "approved",
      "created_at": "2026-04-01T11:00:00Z",
      "updated_at": "2026-04-01T11:00:00Z"
    }
  ]
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
: >"$TEST_ROOT/codex-learning/rules.md"
: >"$TEST_ROOT/codex-learning/prompt-rules.md"
: >"$TEST_ROOT/codex-memory/decisions.md"
: >"$TEST_ROOT/codex-memory/context.md"

(
  cd "$TEST_ROOT"
  NOTIFY_DISABLE=1 \
  TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json" \
  TASK_LOG="$TEST_ROOT/codex-memory/tasks.log" \
  RULES_FILE="$TEST_ROOT/codex-learning/rules.md" \
  PROMPT_RULES_FILE="$TEST_ROOT/codex-learning/prompt-rules.md" \
  DECISIONS_FILE="$TEST_ROOT/codex-memory/decisions.md" \
  CONTEXT_FILE="$TEST_ROOT/codex-memory/context.md" \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-7" \
    "$PROJECT_DIR" \
    "session-worker" \
    "Persist queue-worker runtime session state" \
    "0" \
    "codex" \
    "lease-session" \
    "task-worker-session" >/dev/null
)

python3 - "$TEST_ROOT/codex-logs/runtime-sessions/session-worker/task-worker-session.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

assert payload["task_id"] == "task-worker-session"
assert payload["state"] == "completed"
assert payload["result"] == "SUCCESS"
assert payload["visibility"] == "background"
assert payload["lane"] == "lane-7"
assert payload["provider"] == "codex"
assert payload["latest_activity"]["type"] == "execute_success"
PY

echo "queue worker runtime session test passed"
