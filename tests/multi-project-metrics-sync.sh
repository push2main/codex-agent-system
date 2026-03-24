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
mkdir -p "$TEST_ROOT/codex-memory" "$TEST_ROOT/queues" "$TEST_ROOT/codex-logs" "$TEST_ROOT/codex-learning" "$TEST_ROOT/projects/superheld"
mkdir -p "$EXTERNAL_PROJECT_ROOT/.codex-agent"

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-root-pending",
      "title": "Review the next bounded experiment",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "score": 2.1,
      "created_at": "2026-03-24T08:00:00Z",
      "updated_at": "2026-03-24T08:00:00Z"
    }
  ]
}
EOF

cat >"$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<EOF
{
  "tasks": [
    {
      "id": "task-superheld-approved",
      "title": "Add Gradle wrapper",
      "project": "superheld",
      "status": "approved",
      "score": 1.4,
      "created_at": "2026-03-24T08:05:00Z",
      "updated_at": "2026-03-24T08:05:00Z",
      "approved_at": "2026-03-24T08:05:00Z",
      "queue_handoff": {
        "at": "2026-03-24T08:05:00Z",
        "project": "superheld",
        "task": "Add Gradle wrapper",
        "status": "queued",
        "provider": "codex"
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
  source "$TEST_ROOT/scripts/lib.sh"
  sync_task_artifacts
)

EXPECTED_PAYLOAD_BYTES="$(
  python3 - "$TEST_ROOT/codex-memory/tasks.json" "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
import os
import sys

print(sum(os.path.getsize(path) for path in sys.argv[1:]))
PY
)"

jq -e '
  .approved_tasks == 1 and
  .pending_approval_tasks == 1 and
  .task_registry_total == 2 and
  .analysis_runs == 2
' "$TEST_ROOT/codex-learning/metrics.json" >/dev/null

jq -e --argjson expected "$EXPECTED_PAYLOAD_BYTES" '
  .queue_starvation_detected == true and
  .task_registry_payload_bytes == $expected
' "$TEST_ROOT/codex-learning/metrics.json" >/dev/null

echo "multi-project metrics sync test passed"
