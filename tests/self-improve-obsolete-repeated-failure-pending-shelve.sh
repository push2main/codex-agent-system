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
      "id": "task-001-placeholder",
      "title": "[self-improve:medium] Fix repeated failure: Queue execution failed after exhausting retries. -- Error occurred 2 times across tasks task-101",
      "execution_task": "[self-improve:medium] Fix repeated failure: Queue execution failed after exhausting retries. -- Error occurred 2 times across tasks task-101",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T19:28:56Z",
      "reason": "Error occurred 2 times across tasks task-101, task-102. This is a systematic issue that should be fixed at the root cause.",
      "task_intent": {
        "source": "self-improve",
        "objective": "[self-improve:medium] Fix repeated failure: Queue execution failed after exhausting retries. -- Error occurred 2 times across tasks task-101",
        "context_hint": "Error occurred 2 times across tasks task-101, task-102. This is a systematic issue that should be fixed at the root cause."
      },
      "history": []
    },
    {
      "id": "task-002-actionable",
      "title": "[self-improve:medium] Fix repeated failure: Resolve queue worker lease reconciliation before retry handoff.",
      "execution_task": "[self-improve:medium] Fix repeated failure: Resolve queue worker lease reconciliation before retry handoff.",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T19:29:56Z",
      "reason": "Error occurred 2 times across tasks task-201, task-202. This is a systematic issue that should be fixed at the root cause.",
      "task_intent": {
        "source": "self-improve",
        "objective": "[self-improve:medium] Fix repeated failure: Resolve queue worker lease reconciliation before retry handoff.",
        "context_hint": "Error occurred 2 times across tasks task-201, task-202. This is a systematic issue that should be fixed at the root cause."
      },
      "history": []
    },
    {
      "id": "task-003-non-retriable-placeholder",
      "title": "[self-improve:medium] Fix repeated failure: Non-retriable failure detected",
      "execution_task": "[self-improve:medium] Fix repeated failure: Non-retriable failure detected",
      "project": "codex-agent-system",
      "status": "pending_approval",
      "updated_at": "2026-03-25T19:30:56Z",
      "reason": "Non-retriable failure detected — task requires manual intervention.",
      "task_intent": {
        "source": "self-improve",
        "objective": "[self-improve:medium] Fix repeated failure: Non-retriable failure detected",
        "context_hint": "Non-retriable failure detected — task requires manual intervention."
      },
      "history": []
    }
  ]
}
EOF

cat >"$REPO_ROOT/codex-learning/metrics.json" <<'EOF'
{
  "success_rate": 0.8,
  "recent_success_rate": 0.8,
  "first_pass_success_rate": 0.8,
  "timeout_failure_rate": 0.01,
  "retry_classification_coverage": 0.8,
  "retry_classified_count": 8,
  "retry_total_count": 10,
  "approved_tasks": 0,
  "approved_backlog": 0,
  "pending_approval_tasks": 2,
  "pending_approval_blocked_detected": true,
  "queued_tasks": 0,
  "running_tasks": 0,
  "task_registry_total": 2,
  "task_registry_payload_bytes": 128000,
  "task_registry_pressure_bytes": 128000,
  "task_registry_pressure_detected": false,
  "retry_churn_detected": false,
  "strategy_saturation_detected": false,
  "strategy_saturation": false,
  "external_signal_status": "fresh",
  "total_tasks": 20
}
EOF

(
  cd "$REPO_ROOT"
  IMPROVEMENT_COOLDOWN_SECONDS=0 \
  bash scripts/self-improve.sh codex-agent-system >/dev/null
)

placeholder_summary="$(
  jq -r '
    .tasks
    | map(select(.id == "task-001-placeholder"))
    | first
    | [.status, .shelved_reason, (.history[-1].action // ""), (.history[-1].note // "")]
    | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
case "$placeholder_summary" in
  $'shelved\tauto-shelved: repeated-failure placeholder is a known non-actionable wrapper failure\tauto_shelve\tTask was automatically retired because it matches a generic repeated-failure placeholder with no actionable root cause: repeated-failure placeholder is a known non-actionable wrapper failure.')
    ;;
  *)
    echo "expected placeholder repeated-failure task to be auto-shelved, got: $placeholder_summary" >&2
    exit 1
    ;;
esac

non_retriable_summary="$(
  jq -r '
    .tasks
    | map(select(.id == "task-003-non-retriable-placeholder"))
    | first
    | [.status, .shelved_reason, (.history[-1].action // ""), (.history[-1].note // "")]
    | @tsv
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
case "$non_retriable_summary" in
  $'shelved\tauto-shelved: repeated-failure placeholder is a known non-actionable wrapper failure\tauto_shelve\tTask was automatically retired because it matches a generic repeated-failure placeholder with no actionable root cause: repeated-failure placeholder is a known non-actionable wrapper failure.')
    ;;
  *)
    echo "expected non-retriable repeated-failure task to be auto-shelved, got: $non_retriable_summary" >&2
    exit 1
    ;;
esac

actionable_status="$(
  jq -r '
    .tasks
    | map(select(.id == "task-002-actionable"))
    | first
    | .status // ""
  ' "$REPO_ROOT/codex-memory/tasks.json"
)"
if [ "$actionable_status" != "pending_approval" ]; then
  echo "expected actionable repeated-failure task to remain pending approval" >&2
  exit 1
fi

artifact_summary="$(
  jq -r '
    [
      .gating.retired_obsolete_pending_tasks,
      .gating.active_self_improve_count
    ] | @tsv
  ' "$REPO_ROOT/codex-learning/self-improve-run.json"
)"
if [ "$artifact_summary" != $'2\t1' ]; then
  echo "unexpected obsolete-pending retirement artifact summary: $artifact_summary" >&2
  exit 1
fi

echo "self improve obsolete repeated failure pending shelve test passed"
