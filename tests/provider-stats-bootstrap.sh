#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
TEST_ROOT="$TMP_DIR/repo"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

mkdir -p "$TEST_ROOT" "$TEST_ROOT/codex-memory" "$TEST_ROOT/codex-learning" "$TEST_ROOT/codex-logs" "$TEST_ROOT/projects" "$TEST_ROOT/queues" "$TEST_ROOT/codex-dashboard"
cp -R "$ROOT_DIR/scripts" "$TEST_ROOT/scripts"

cat >"$TEST_ROOT/codex-memory/tasks.log" <<'EOF'
{"timestamp":"2026-03-22T18:00:00Z","project":"codex-agent-system","task":"Refine dashboard board spacing on mobile","result":"SUCCESS","attempts":1,"score":8,"branch":"","pr_url":"","run_id":"run-missing-provider","duration_seconds":12}
EOF

cat >"$TEST_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-bootstrap-provider",
      "title": "Refine dashboard board spacing on mobile",
      "project": "codex-agent-system",
      "status": "completed",
      "execution_provider": "claude",
      "updated_at": "2026-03-22T18:01:00Z",
      "execution": {
        "state": "completed",
        "attempt": 1,
        "result": "SUCCESS",
        "provider": "claude"
      },
      "execution_context": {
        "run_id": "run-missing-provider",
        "result": "SUCCESS",
        "attempts": 1,
        "score": 8,
        "duration_seconds": 12,
        "provider": "claude",
        "updated_at": "2026-03-22T18:01:00Z"
      }
    },
    {
      "id": "task-bootstrap-registry-only",
      "title": "Improve mobile dashboard navigation",
      "project": "codex-agent-system",
      "status": "failed",
      "execution_provider": "claude",
      "updated_at": "2026-03-22T18:02:00Z",
      "execution": {
        "state": "failed",
        "attempt": 2,
        "result": "FAILURE",
        "provider": "claude"
      },
      "execution_context": {
        "run_id": "run-registry-only",
        "result": "FAILURE",
        "attempts": 2,
        "score": 0,
        "duration_seconds": 20,
        "provider": "claude",
        "updated_at": "2026-03-22T18:02:00Z"
      },
      "failure_context": {
        "run_id": "run-registry-only",
        "result": "FAILURE",
        "attempts": 2,
        "provider": "claude",
        "updated_at": "2026-03-22T18:02:00Z"
      }
    }
  ]
}
EOF

export TASK_REGISTRY_FILE="$TEST_ROOT/codex-memory/tasks.json"
export TASK_LOG="$TEST_ROOT/codex-memory/tasks.log"

source "$TEST_ROOT/scripts/lib.sh"

compute_provider_stats

[ -f "$TEST_ROOT/codex-learning/provider-stats.json" ]
jq -e '
  .claude.ui.task_count == 2 and
  .claude.ui.success_rate == 0.5 and
  (.codex? | not)
' "$TEST_ROOT/codex-learning/provider-stats.json" >/dev/null

echo "provider stats bootstrap test passed"
