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
  mkdir -p "$repo_root"
  cp -R "$ROOT_DIR/scripts" "$repo_root/scripts"
  mkdir -p "$repo_root/codex-memory" "$repo_root/codex-learning" "$repo_root/codex-logs" "$repo_root/queues" "$repo_root/projects"
}

REPO_ROOT="$TMP_DIR/repo"
make_repo "$REPO_ROOT"

cat >"$REPO_ROOT/codex-memory/tasks.json" <<'EOF'
{
  "tasks": [
    {
      "id": "task-retry-persist",
      "title": "Persist retry failure context",
      "project": "codex-agent-system",
      "status": "failed",
      "task_intent": {
        "objective": "Persist retry failure context",
        "context_hint": "Keep retry diagnostics scoped to the existing orchestrator failure path.",
        "affected_files": [
          "agents/orchestrator.sh",
          "scripts/lib.sh"
        ],
        "constraints": [
          "Do not change retry limits."
        ]
      },
      "task_shape": {
        "verification_command": "bash tests/retry-failure-event-persistence.sh"
      }
    }
  ]
}
EOF

(
  cd "$REPO_ROOT"
  source "$REPO_ROOT/scripts/lib.sh"
  RETRY_ANALYSIS_LOG="$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"
  export RETRY_ANALYSIS_LOG
  record_retry_failure_event \
    "task-retry-persist" \
    "codex-agent-system" \
    "2" \
    "4" \
    "timeout" \
    "2026-03-25T07:30:00Z" \
    "Execution timed out after 420 seconds while running verification."
)

summary="$(
  jq -r '
    [
      .task_id,
      .project,
      .attempt,
      .failed_step_index,
      .classification,
      .timestamp,
      .error_text,
      (.task_context.objective // ""),
      (.task_context.context_hint // ""),
      ((.task_context.affected_files // []) | join(",")),
      (.task_context.verification_command // "")
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/retry-failure-analysis.jsonl"
)"

if [ "$summary" != $'task-retry-persist\tcodex-agent-system\t2\t4\ttimeout\t2026-03-25T07:30:00Z\tExecution timed out after 420 seconds while running verification.\tPersist retry failure context\tKeep retry diagnostics scoped to the existing orchestrator failure path.\tagents/orchestrator.sh,scripts/lib.sh\tbash tests/retry-failure-event-persistence.sh' ]; then
  echo "unexpected retry event payload: $summary" >&2
  exit 1
fi

echo "retry failure event persistence test passed"
