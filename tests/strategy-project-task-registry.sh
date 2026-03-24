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
  "tasks": []
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-failed",
      "title": "Fix flaky Android build step",
      "project": "superheld",
      "category": "stability",
      "status": "failed",
      "reason": "The last attempt still bundled too much Android build work into one retry.",
      "impact": 7,
      "effort": 4,
      "confidence": 0.78,
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:05:00Z",
      "failed_at": "2026-03-24T08:05:00Z",
      "execution_context": {
        "failed_step": "Limit the follow-up fix strictly to the flaky Gradle cache invalidation path before touching deployment flow. Run `bash tests/android-build.sh` as the single deterministic verification command.",
        "step_count": 4
      }
    },
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
  "pending_approval_tasks": 0,
  "task_registry_total": 0,
  "queue_starvation_detected": false
}
EOF

(
  cd "$TEST_ROOT"
  bash agents/strategy.sh superheld "$TMP_DIR/strategy-project-task-registry.json" >/dev/null
)

python3 - "$TEST_ROOT/codex-memory/tasks.json" "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" "$TMP_DIR/strategy-project-task-registry.json" <<'PY'
import json
import sys

root_registry_path, external_registry_path, output_path = sys.argv[1:]

with open(root_registry_path, "r", encoding="utf-8") as handle:
    root_registry = json.load(handle)
with open(external_registry_path, "r", encoding="utf-8") as handle:
    external_registry = json.load(handle)
with open(output_path, "r", encoding="utf-8") as handle:
    output_payload = json.load(handle)

root_tasks = root_registry.get("tasks", [])
external_tasks = external_registry.get("tasks", [])

assert root_tasks == [], root_tasks
assert len(external_tasks) == 4, external_tasks

created_tasks = [
    task for task in external_tasks
    if task.get("status") == "pending_approval" and task.get("source_task_id") == "task-superheld-failed"
]
assert len(created_tasks) == 1, created_tasks
created_task = created_tasks[0]

assert created_task["project"] == "superheld"
assert created_task["strategy_template"] == "bounded_failed_step_child"
assert created_task["root_source_task_id"] == "task-superheld-failed"
assert created_task["original_failed_root_id"] == "task-superheld-failed"
assert created_task["task_intent"]["project"] == "superheld"

assert output_payload["status"] == "success"
assert output_payload["message"] == "Applied 1 strategy board update(s) for superheld."
assert output_payload["data"]["board_updates"] == [
    {
        "id": created_task["id"],
        "action": "created",
        "source_task_id": "task-superheld-failed",
    }
]
PY

jq -e '
  .approved_tasks == 2 and
  .pending_approval_tasks == 1 and
  .task_registry_total == 4 and
  .analysis_runs == 4
' "$TEST_ROOT/codex-learning/metrics.json" >/dev/null

echo "strategy project task registry test passed"
