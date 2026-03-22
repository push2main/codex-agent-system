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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-manual-fast",
      "title": "Manual high-value small task",
      "project": "priority-smoke",
      "status": "approved",
      "score": 4.2,
      "effort": 2,
      "confidence": 0.9,
      "task_intent": {
        "source": "manual_board_task"
      }
    },
    {
      "id": "task-prompt-intake",
      "title": "Prompt-derived generic task",
      "project": "priority-smoke",
      "status": "approved",
      "score": 4.8,
      "effort": 1,
      "confidence": 0.95,
      "task_intent": {
        "source": "dashboard_prompt_intake"
      }
    },
    {
      "id": "task-manual-slower",
      "title": "Manual bigger task",
      "project": "priority-smoke",
      "status": "approved",
      "score": 4.9,
      "effort": 4,
      "confidence": 0.88,
      "task_intent": {
        "source": "manual_board_task"
      }
    },
    {
      "id": "task-manual-broad",
      "title": "Analyze system weaknesses and opportunities",
      "project": "priority-smoke",
      "status": "approved",
      "score": 5.0,
      "effort": 2,
      "confidence": 0.95,
      "task_intent": {
        "source": "manual_board_task"
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/queues/priority-smoke.txt" <<'EOF'
Prompt-derived generic task
Analyze system weaknesses and opportunities
Manual bigger task
Manual high-value small task
EOF

(
  cd "$TEST_ROOT"
  source "$TEST_ROOT/scripts/lib.sh"
  selected="$(next_task_from_queue "$TEST_ROOT/queues/priority-smoke.txt")"
  [ "$selected" = "Manual high-value small task" ]
  remove_first_task_from_queue "$TEST_ROOT/queues/priority-smoke.txt" "$selected"
  remaining="$(cat "$TEST_ROOT/queues/priority-smoke.txt")"
  printf '%s\n' "$remaining" | grep -qx 'Prompt-derived generic task' || exit 1
  printf '%s\n' "$remaining" | grep -qx 'Analyze system weaknesses and opportunities' || exit 1
  printf '%s\n' "$remaining" | grep -qx 'Manual bigger task' || exit 1
)

echo "queue priority selection test passed"
