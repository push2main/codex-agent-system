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
      "title": "Review the next bounded experiment",
      "project": "codex-agent-system",
      "category": "stability",
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
      "category": "stability",
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
  bash agents/strategy.sh codex-agent-system "$TMP_DIR/strategy-multi-project-metrics.json" >/dev/null
)

EXPECTED_PAYLOAD_BYTES="$(
  python3 - "$TEST_ROOT/codex-memory/tasks.json" "$EXTERNAL_PROJECT_ROOT/.codex-agent/tasks.json" <<'PY'
import os
import sys

print(sum(os.path.getsize(path) for path in sys.argv[1:]))
PY
)"

python3 - "$TMP_DIR/strategy-multi-project-metrics.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

assert payload["status"] == "success"
assert payload["message"] == "No new strategy updates for codex-agent-system; waiting on 1 pending approval task(s)."
assert payload["data"]["board_updates"] == []
assert payload["data"]["board_tasks"] == [
    {
        "id": "task-root-pending",
        "action": "existing",
        "status": "pending_approval",
        "title": "Review the next bounded experiment",
        "category": "stability",
        "source_task_id": "task-root-pending",
        "updated_at": "2026-03-24T08:00:00Z",
    }
]
PY

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

echo "strategy multi-project metrics sync test passed"
