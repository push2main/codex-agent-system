#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

make_repo() {
  local repo_root="$1"
  mkdir -p "$repo_root/scripts" "$repo_root/agents" "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/projects" "$repo_root/queues"
  cp "$ROOT_DIR/scripts/lib.sh" "$repo_root/scripts/lib.sh"
  cp "$ROOT_DIR/scripts/strategy-loop.sh" "$repo_root/scripts/strategy-loop.sh"
  cp "$ROOT_DIR/scripts/sync-task-artifacts.py" "$repo_root/scripts/sync-task-artifacts.py"
  cp "$ROOT_DIR/scripts/task_metrics.py" "$repo_root/scripts/task_metrics.py"

  cat >"$repo_root/scripts/self-improve.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

  cat >"$repo_root/scripts/compact-registry.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exit 0
EOF

  cat >"$repo_root/agents/strategy.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project_name="${1:-}"
output_file="${2:-}"
printf '%s\n' "$project_name" >>"$ROOT_DIR/strategy-invocations.log"
cat >"$output_file" <<'JSON'
{
  "status": "success",
  "data": {
    "board_tasks": []
  }
}
JSON
EOF

  chmod +x "$repo_root/scripts/self-improve.sh" "$repo_root/scripts/compact-registry.sh" "$repo_root/agents/strategy.sh"
}

run_once() {
  local repo_root="$1"
  (
    cd "$repo_root"
    bash scripts/strategy-loop.sh --once codex-agent-system >/dev/null
  )
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "remote-approved-1",
      "title": "Remote approved task 1",
      "project": "superheld",
      "status": "approved",
      "updated_at": "2026-03-25T11:05:00Z"
    },
    {
      "id": "remote-approved-2",
      "title": "Remote approved task 2",
      "project": "superheld",
      "status": "approved",
      "updated_at": "2026-03-25T11:06:00Z"
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-25T11:10:00Z","project":"codex-agent-system","task":"Local failed task","task_id":"local-failed-task","result":"FAILURE","attempts":1,"score":0}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.0,
  "total_tasks": 1,
  "approved_tasks": 0,
  "retry_churn_detected": false,
  "loop_effort_detected": false
}
EOF

run_once "$REPO_ROOT"

if [ ! -f "$REPO_ROOT/strategy-invocations.log" ]; then
  echo "expected strategy run when only cross-project approved tasks exist in the shared registry" >&2
  exit 1
fi

if grep -q "Queue gate active" "$REPO_ROOT/codex-logs/system.log"; then
  echo "queue gate should not activate from cross-project approved tasks in the shared registry" >&2
  exit 1
fi

if grep -q "Using local approved count (2) instead of global (0)" "$REPO_ROOT/codex-logs/system.log"; then
  echo "expected project-local queue count to ignore cross-project approved tasks" >&2
  exit 1
fi

if ! grep -q "Zero-queue escape: 0 approved + 0 running" "$REPO_ROOT/codex-logs/system.log"; then
  echo "expected zero-queue escape once project-local approved and running counts are both zero" >&2
  exit 1
fi

echo "strategy cross-project approved queue gate test passed"
