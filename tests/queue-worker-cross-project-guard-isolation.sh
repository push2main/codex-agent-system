#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
PROJECT_DIR="$TEST_ROOT/projects/project-a"

cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
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

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-local-zombie",
      "title": "shared title zombie",
      "project": "project-a",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-25T10:00:00Z",
      "updated_at": "2026-03-25T10:00:00Z",
      "history": []
    },
    {
      "id": "task-local-retry",
      "title": "shared title retry",
      "project": "project-a",
      "status": "approved",
      "execution_provider": "codex",
      "created_at": "2026-03-25T10:01:00Z",
      "updated_at": "2026-03-25T10:01:00Z",
      "history": []
    }
  ]
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T09:00:00Z","project":"other-project","task":"shared title zombie","result":"FAILURE","failure_kind":"execution_failure","task_id":"other-zombie-1"}
{"timestamp":"2026-03-25T09:01:00Z","project":"other-project","task":"shared title zombie","result":"FAILURE","failure_kind":"execution_failure","task_id":"other-zombie-2"}
{"timestamp":"2026-03-25T09:02:00Z","project":"other-project","task":"shared title zombie","result":"FAILURE","failure_kind":"execution_failure","task_id":"other-zombie-3"}
{"timestamp":"2026-03-25T09:03:00Z","project":"other-project","task":"shared title zombie","result":"FAILURE","failure_kind":"execution_failure","task_id":"other-zombie-4"}
{"timestamp":"2026-03-25T09:04:00Z","project":"other-project","task":"shared title zombie","result":"FAILURE","failure_kind":"execution_failure","task_id":"other-zombie-5"}
{"timestamp":"2026-03-25T09:05:00Z","project":"other-project","task":"shared title retry","result":"FAILURE","failure_kind":"timeout","task_id":"other-retry-1"}
EOF

cat >"$TEST_ROOT/agents/orchestrator.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF
chmod +x "$TEST_ROOT/agents/orchestrator.sh"

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-1" \
    "$PROJECT_DIR" \
    "project-a" \
    "shared title zombie" \
    "0" \
    "codex" \
    "lease-local-zombie" \
    "task-local-zombie"
)

(
  cd "$TEST_ROOT"
  CODEX_DISABLE=1 \
  bash "$TEST_ROOT/scripts/queue-worker.sh" \
    "lane-2" \
    "$PROJECT_DIR" \
    "project-a" \
    "shared title retry" \
    "1" \
    "codex" \
    "lease-local-retry" \
    "task-local-retry"
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text())
tasks = {task["id"]: task for task in payload["tasks"]}

zombie_task = tasks["task-local-zombie"]
retry_task = tasks["task-local-retry"]

assert zombie_task["status"] == "completed", zombie_task
assert zombie_task["execution"]["result"] == "SUCCESS", zombie_task
assert zombie_task["history"][-1]["action"] == "execute_success", zombie_task["history"][-1]

assert retry_task["status"] == "completed", retry_task
assert retry_task["execution"]["result"] == "SUCCESS", retry_task
assert retry_task["history"][-1]["action"] == "execute_success", retry_task["history"][-1]
PY

echo "queue worker cross-project guard isolation test passed"
