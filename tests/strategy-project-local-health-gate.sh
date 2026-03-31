#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

iso_now_minus_minutes() {
  python3 - "$1" <<'PY'
from datetime import datetime, timedelta, timezone
import sys

minutes = int(sys.argv[1])
print((datetime.now(timezone.utc) - timedelta(minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

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

REPO_CROSS="$TMP_DIR/repo-cross-project"
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"
LOCAL_SUCCESS_TS="$(iso_now_minus_minutes 25)"
REMOTE_RETRY_TS="$(iso_now_minus_minutes 20)"
LOCAL_RETRY_TS="$(iso_now_minus_minutes 15)"
make_repo "$REPO_CROSS"
mkdir -p "$EXTERNAL_PROJECT_ROOT/.codex-agent" "$REPO_CROSS/projects/superheld"

cat >"$REPO_CROSS/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "local-success-task",
      "title": "Local success task",
      "project": "codex-agent-system",
      "status": "completed",
      "updated_at": "$LOCAL_SUCCESS_TS",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "max_retries": 2,
        "result": "SUCCESS",
        "updated_at": "$LOCAL_SUCCESS_TS"
      }
    }
  ]
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "remote-retrying-task",
      "title": "Remote retrying task",
      "project": "superheld",
      "status": "approved",
      "updated_at": "$REMOTE_RETRY_TS",
      "execution": {
        "state": "retrying",
        "attempt": 2,
        "max_retries": 2,
        "updated_at": "$REMOTE_RETRY_TS"
      },
      "execution_context": {
        "total_step_attempts": 5
      }
    }
  ]
}
EOF

cat >"$REPO_CROSS/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_PROJECT_ROOT",
  "task_registry_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
}
EOF

cat >"$REPO_CROSS/codex-memory/tasks.log" <<EOF
{"timestamp":"$LOCAL_SUCCESS_TS","project":"codex-agent-system","task":"Local success task","task_id":"local-success-task","result":"SUCCESS","attempts":1,"score":7}
EOF

cat >"$REPO_CROSS/codex-learning/metrics.json" <<'EOF'
{
  "approved_tasks": 0
}
EOF

run_once "$REPO_CROSS"

if [ ! -f "$REPO_CROSS/strategy-invocations.log" ]; then
  echo "expected strategy run when only shared board-health metrics are degraded" >&2
  exit 1
fi

if grep -q "Queue gate active" "$REPO_CROSS/codex-logs/system.log"; then
  echo "queue gate should not activate for cross-project board-health signals" >&2
  exit 1
fi

if ! grep -q "Ignoring shared board-health metrics for codex-agent-system" "$REPO_CROSS/codex-logs/system.log"; then
  echo "expected strategy loop to log shared board-health suppression" >&2
  exit 1
fi

REPO_LOCAL="$TMP_DIR/repo-local-health"
make_repo "$REPO_LOCAL"

cat >"$REPO_LOCAL/codex-memory/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "local-retrying-task",
      "title": "Local retrying task",
      "project": "codex-agent-system",
      "status": "approved",
      "updated_at": "$LOCAL_RETRY_TS",
      "execution": {
        "state": "retrying",
        "attempt": 2,
        "max_retries": 2,
        "updated_at": "$LOCAL_RETRY_TS"
      }
    }
  ]
}
EOF

cat >"$REPO_LOCAL/codex-memory/tasks.log" <<EOF
{"timestamp":"$LOCAL_RETRY_TS","project":"codex-agent-system","task":"Local retrying task","task_id":"local-retrying-task","result":"FAILURE","attempts":2,"score":0}
EOF

cat >"$REPO_LOCAL/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 1.0,
  "total_tasks": 1,
  "retry_churn_detected": false,
  "loop_effort_detected": false,
  "approved_tasks": 1
}
EOF

run_once "$REPO_LOCAL"

if [ -f "$REPO_LOCAL/strategy-invocations.log" ]; then
  echo "expected local retry churn to keep strategy gated" >&2
  exit 1
fi

if ! grep -Eq "Queue gate active: success_rate=0 queue_size=1\(local\)/1\(global\) .*loop_effort=false retry_churn=true .*health_scope=project_local pipeline_stale=false" "$REPO_LOCAL/codex-logs/system.log"; then
  echo "expected queue gate to use project-local retry churn state" >&2
  exit 1
fi

if ! grep -q "health_scope=project_local" "$REPO_LOCAL/codex-logs/system.log"; then
  echo "expected queue gate log to describe project-local health scope" >&2
  exit 1
fi

echo "strategy project-local health gate test passed"
