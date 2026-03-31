#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
REPO_ROOT="$TMP_DIR/repo"
EXTERNAL_WORKSPACE="$TMP_DIR/superheld-repo"

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
  "$REPO_ROOT/projects/superheld" \
  "$EXTERNAL_WORKSPACE/.codex-agent" \
  "$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts"
cp -R "$ROOT_DIR/scripts/." "$REPO_ROOT/scripts"

cat >"$REPO_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_WORKSPACE",
  "repo_url": "https://example.invalid/superheld",
  "task_registry_file": "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
}
EOF

cat >"$EXTERNAL_WORKSPACE/apps/cloud-brain/scripts/smoke.mjs" <<'EOF'
console.log("credential recovery routing smoke passed")
EOF

cat >"$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-running",
      "title": "Running task",
      "execution_task": "Running task",
      "project": "superheld",
      "status": "running",
      "created_at": "2026-03-31T10:00:00Z",
      "updated_at": "2026-03-31T10:00:00Z",
      "task_intent": {
        "source": "self-improve",
        "objective": "Running task",
        "project": "superheld",
        "category": "stability",
        "affected_files": ["apps/cloud-brain/scripts/smoke.mjs"]
      },
      "target_files": ["apps/cloud-brain/scripts/smoke.mjs"],
      "strategy_template": "self_improvement",
      "execution": {
        "state": "running"
      }
    },
    {
      "id": "task-pending",
      "title": "Verify dashboard incident payload coverage in smoke flow",
      "execution_task": "Verify dashboard incident payload coverage in smoke flow",
      "project": "superheld",
      "status": "pending_approval",
      "score": 5.1,
      "created_at": "2026-03-31T10:01:00Z",
      "updated_at": "2026-03-31T10:01:00Z",
      "reason": "Smoke flow should verify dashboard incident payload coverage.",
      "task_intent": {
        "source": "self-improve",
        "objective": "Verify dashboard incident payload coverage in smoke flow",
        "project": "superheld",
        "category": "stability",
        "affected_files": ["apps/cloud-brain/scripts/smoke.mjs"]
      },
      "target_files": ["apps/cloud-brain/scripts/smoke.mjs"],
      "strategy_template": "self_improvement",
      "task_shape": {
        "verification_command": ""
      }
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "pipeline_stale": false,
  "pending_approval_tasks": 1,
  "approved_tasks": 0,
  "running_tasks": 1,
  "queued_tasks": 0,
  "task_registry_total": 2
}
EOF

: >"$REPO_ROOT/codex-memory/tasks.log"

(
  cd "$REPO_ROOT"
  python3 scripts/strategy-auto-approve.py \
    "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json" \
    codex-learning/metrics.json \
    codex-memory/tasks.log >/dev/null
)

pending_status="$(
  jq -r '.tasks[] | select(.id == "task-pending") | .status' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
pending_verification="$(
  jq -r '.tasks[] | select(.id == "task-pending") | .task_shape.verification_command' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"
repair_action_count="$(
  jq -r '[.tasks[] | select(.id == "task-pending") | .history[]? | select(.action == "auto_repair_verification_command")] | length' "$EXTERNAL_WORKSPACE/.codex-agent/tasks.json"
)"

if [ "$pending_status" != "pending_approval" ]; then
  echo "expected active-work repair to keep pending task unapproved, got: $pending_status" >&2
  exit 1
fi

if [ "$pending_verification" != "node apps/cloud-brain/scripts/smoke.mjs --verify-credential-recovery-routing" ]; then
  echo "expected smoke verification command repair to persist, got: $pending_verification" >&2
  exit 1
fi

if [ "$repair_action_count" != "1" ]; then
  echo "expected verification repair history to be persisted, got count: $repair_action_count" >&2
  exit 1
fi

echo "strategy auto-approve running project repair persists test passed"
