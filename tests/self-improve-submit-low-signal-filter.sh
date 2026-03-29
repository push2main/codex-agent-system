#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p \
  "$REPO_ROOT/scripts" \
  "$REPO_ROOT/codex-memory" \
  "$REPO_ROOT/codex-learning" \
  "$REPO_ROOT/codex-logs" \
  "$REPO_ROOT/queues" \
  "$REPO_ROOT/projects"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.13,
  "recent_success_rate": 0.0,
  "pipeline_stale": true,
  "self_improve_paused": false
}
EOF

cat >"$REPO_ROOT/codex-learning/provider-routing.json" <<'EOF'
{}
EOF

cat >"$REPO_ROOT/codex-learning/provider-stats.json" <<'EOF'
{}
EOF

cat >"$REPO_ROOT/improvements.json" <<'EOF'
{
  "status": "success",
  "data": {
    "improvements": [
      {
        "title": "In agents/planner.sh, add a comment documenting the MAX_STEP_CHARS=600 gate",
        "category": "stability",
        "reason": "Documentation-only clarification for the existing planner gate.",
        "priority": "high",
        "target_files": ["agents/planner.sh"]
      },
      {
        "title": "Break retry churn",
        "category": "stability",
        "reason": "3 tasks consumed 8 extra step attempts without resolution. Implement exponential backoff on retries and skip tasks that fail with identical errors.",
        "priority": "high",
        "target_files": ["agents/orchestrator.sh"]
      }
    ],
    "metrics_snapshot": {
      "success_rate": 0.13,
      "recent_success_rate": 0.0,
      "pipeline_stale": true,
      "self_improve_paused": false
    }
  }
}
EOF

sed '/^# Main execution/,$d' "$REPO_ROOT/scripts/self-improve.sh" >"$REPO_ROOT/scripts/self-improve-functions.sh"

(
  cd "$REPO_ROOT"
  source "$REPO_ROOT/scripts/self-improve-functions.sh"
  submit_result="$(submit_improvement_tasks "$(cat "$REPO_ROOT/improvements.json")")"
  printf '%s\n' "$submit_result" >"$REPO_ROOT/submit-result.json"
)

python3 - "$REPO_ROOT/codex-memory/tasks.json" "$REPO_ROOT/submit-result.json" <<'PY'
import json
import sys
from pathlib import Path

tasks_payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
submit_payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

tasks = tasks_payload.get("tasks", [])
assert len(tasks) == 1, tasks
task = tasks[0]

assert task["title"] == "Break retry churn", task
assert task["status"] == "pending_approval", task
assert task["task_intent"]["source"] == "self-improve", task
assert task["task_intent"]["affected_files"] == ["agents/orchestrator.sh"], task

assert submit_payload["submitted"] == 1, submit_payload
assert submit_payload["submitted_titles"] == ["Break retry churn"], submit_payload
assert submit_payload["max_submit"] == 1, submit_payload
assert submit_payload["skipped_low_signal"] == 1, submit_payload
PY

echo "self improve submit low-signal filter test passed"
