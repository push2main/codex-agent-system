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
  "$REPO_ROOT/projects/superheld/repo/.codex-agent"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": []
}
EOF

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$REPO_ROOT/projects/superheld/repo",
  "task_registry_file": "$REPO_ROOT/projects/superheld/repo/.codex-agent/tasks.json"
}
EOF

cat >"$REPO_ROOT/projects/superheld/repo/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-running",
      "title": "Project-local running task must survive validation",
      "project": "superheld",
      "status": "running",
      "updated_at": "2026-03-30T00:00:00Z"
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 0,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 0,
  "queue_starvation_detected": true,
  "pending_approval_blocked_detected": false,
  "retry_churn_detected": false
}
EOF

(
  cd "$REPO_ROOT"
  METRICS_FILE="$REPO_ROOT/codex-learning/metrics.json" \
  REGISTRY_FILE="$REPO_ROOT/projects/superheld/repo/.codex-agent/tasks.json" \
  bash scripts/validate-metrics.sh >/dev/null
)

actual_summary="$(
  python3 - "$REPO_ROOT/codex-learning/metrics.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    metrics = json.load(handle)

print(
    "\t".join(
        [
            str(metrics.get("task_registry_total")),
            str(metrics.get("running_tasks")),
        ]
    )
)
PY
)"

if [ "$actual_summary" != $'1\t1' ]; then
  echo "expected project-registry override to preserve running task counts, got: $actual_summary" >&2
  exit 1
fi

echo "validate metrics project registry override test passed"
