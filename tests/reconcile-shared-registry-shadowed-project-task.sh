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
mkdir -p \
  "$TEST_ROOT/codex-memory" \
  "$TEST_ROOT/codex-learning" \
  "$TEST_ROOT/codex-logs" \
  "$TEST_ROOT/queues" \
  "$TEST_ROOT/projects/superheld" \
  "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-shared-approved",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
      "execution_task": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
      "project": "superheld",
      "status": "approved",
      "created_at": "2026-03-29T20:11:38Z",
      "updated_at": "2026-03-29T20:12:12Z",
      "execution_provider": "claude",
      "queue_handoff": {
        "at": "2026-03-29T20:12:12Z",
        "project": "superheld",
        "task": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
        "status": "queued"
      }
    }
  ]
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-superheld-project-running",
      "title": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
      "execution_task": "[self-improve:high] Reduce timeout rate -- Tasks are timing out at 47%",
      "project": "superheld",
      "status": "running",
      "updated_at": "2026-03-29T20:29:54Z",
      "execution": {
        "state": "running",
        "lease_state": "claimed",
        "lane": "lane-1"
      }
    }
  ]
}
EOF

cat >"$TEST_ROOT/projects/superheld/project.json" <<EOF
{
  "project": "superheld",
  "project_id": "superheld",
  "workspace": "$EXTERNAL_PROJECT_ROOT",
  "repo_url": "https://example.invalid/superheld",
  "memory_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/memory.md",
  "spec_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/spec.md",
  "policy_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/policy.json",
  "task_registry_file": "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json"
}
EOF

(
  cd "$TEST_ROOT"
  bash -lc 'source scripts/lib.sh && ensure_runtime_dirs && reconcile_approved_registry_tasks_to_queue >/dev/null'
)

if [ -s "$TEST_ROOT/queues/superheld.txt" ]; then
  echo "expected shared approved task to be skipped when project registry already owns the same task" >&2
  exit 1
fi

shadowed_summary="$(
  jq -r '
    .tasks[]
    | select(.id == "task-superheld-shared-approved")
    | [
        .status,
        (.shelved_reason // ""),
        (.queue_handoff.status // ""),
        (.execution.state // ""),
        (.history[-1].action // ""),
        (.history[-1].note // "")
      ]
    | @tsv
  ' "$TEST_ROOT/codex-memory/tasks.json"
)"

if [ "$shadowed_summary" != $'shelved\tauto-shelved: project registry already owns the same execution task\tshadowed_by_project_registry\t\tauto_shelve\tTask was automatically retired because the project registry already owns the same execution task (task-superheld-project-running / running).' ]; then
  echo "expected shared shadow task to be auto-shelved, got: $shadowed_summary" >&2
  exit 1
fi

echo "reconcile shared registry shadowed project task test passed"
