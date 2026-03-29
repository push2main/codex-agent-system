#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"
EXTERNAL_PROJECT_ROOT="$TMP_DIR/superheld"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"
cp -R "$ROOT_DIR/agents" "$TEST_ROOT/agents"
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects/superheld" "$TEST_ROOT/queues"
mkdir -p "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$TEST_ROOT/codex-memory/priority.json" <<'EOF'
{
  "categories": {
    "stability": { "weight": 1.8, "success_rate": 0.76 },
    "ui": { "weight": 1.35, "success_rate": 0.81 },
    "performance": { "weight": 1.1, "success_rate": 0.7 },
    "code_quality": { "weight": 1.05, "success_rate": 0.79 }
  }
}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-root-pending",
      "title": "Inspect the current local queue gate",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "category": "stability",
      "impact": 4,
      "effort": 1,
      "confidence": 0.8,
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z"
    }
  ]
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-approved-1",
      "title": "Keep Android release signing deterministic",
      "project": "superheld",
      "category": "stability",
      "status": "approved",
      "score": 1.8,
      "created_at": "2026-03-24T08:10:00Z",
      "updated_at": "2026-03-24T08:10:00Z"
    },
    {
      "id": "task-superheld-approved-2",
      "title": "Document Gradle build cache ownership",
      "project": "superheld",
      "category": "code_quality",
      "status": "approved",
      "score": 1.6,
      "created_at": "2026-03-24T08:15:00Z",
      "updated_at": "2026-03-24T08:15:00Z"
    }
  ]
}
EOF

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_PROJECT_ROOT",
  "repo_url": "https://github.com/push2main/superheld",
  "memory_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
}
EOF

: >"$TEST_ROOT/codex-memory/tasks.log"
cat >"$TEST_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "approved_tasks": 0,
  "approved_tasks_cross_project": 0,
  "pending_approval_tasks": 0,
  "task_registry_total": 0,
  "queue_starvation_detected": false
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-cross-project-approved-scope.json" >/dev/null
)

jq -e '
  .approved_tasks == 0 and
  .approved_tasks_cross_project == 2 and
  .pending_approval_tasks >= 1 and
  .task_registry_total >= 3
' "$TEST_ROOT/codex-learning/metrics.json" >/dev/null

echo "strategy cross-project approved scope test passed"
